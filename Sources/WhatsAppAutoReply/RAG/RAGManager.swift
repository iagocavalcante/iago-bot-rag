import Foundation

/// Represents a conversation thread with similarity score
struct ConversationThread {
    let messages: [ConversationMessage]
    let similarity: Float

    /// Format thread as conversation for prompt
    func formatted(contactName: String, userName: String) -> String {
        messages.map { msg in
            let speaker = msg.isUser ? userName : contactName
            return "\(speaker): \(msg.content)"
        }.joined(separator: "\n")
    }
}

/// Manages RAG (Retrieval Augmented Generation) for semantic context
class RAGManager {
    static let shared = RAGManager()

    private let embeddingService: EmbeddingService
    private let vectorStore: VectorStore
    private let dbManager: DatabaseManager
    private let settings: SettingsManager

    private var isProcessing = false

    init(
        embeddingService: EmbeddingService = EmbeddingService(),
        vectorStore: VectorStore = VectorStore(),
        dbManager: DatabaseManager = .shared,
        settings: SettingsManager = .shared
    ) {
        self.embeddingService = embeddingService
        self.vectorStore = vectorStore
        self.dbManager = dbManager
        self.settings = settings
    }

    // MARK: - Embedding Generation

    /// Generate embeddings for a contact's messages (call after import)
    func generateEmbeddings(for contactId: Int64, progress: ((Int, Int) -> Void)? = nil) async throws {
        guard settings.isOpenAIConfigured else {
            print("RAG: OpenAI not configured, skipping embedding generation")
            return
        }

        guard !isProcessing else {
            print("RAG: Already processing embeddings")
            return
        }

        isProcessing = true
        defer { isProcessing = false }

        print("RAG: Starting embedding generation for contact \(contactId)")

        // Get all messages for this contact
        let messages = try dbManager.getMessagesForContact(contactId: contactId, limit: 1000)

        guard !messages.isEmpty else {
            print("RAG: No messages to embed")
            return
        }

        // Build conversation threads (3-6 message exchanges)
        let conversationThreads = buildConversationThreads(from: messages)
        print("RAG: Found \(conversationThreads.count) conversation threads to embed")

        // Also build legacy pairs for backward compatibility
        var conversationPairs: [(contactMsg: Message, userResponse: Message)] = []
        for i in 0..<(messages.count - 1) {
            if messages[i].sender == .contact && messages[i + 1].sender == .user {
                conversationPairs.append((messages[i], messages[i + 1]))
            }
        }

        let totalItems = conversationThreads.count + conversationPairs.count
        var processed = 0

        // Process conversation threads
        let threadBatchSize = 10
        for batchStart in stride(from: 0, to: conversationThreads.count, by: threadBatchSize) {
            let batchEnd = min(batchStart + threadBatchSize, conversationThreads.count)
            let batch = Array(conversationThreads[batchStart..<batchEnd])

            // Embed the full conversation context for better semantic matching
            let texts = batch.map { thread -> String in
                thread.map { msg in
                    "\(msg.sender == .contact ? "them" : "me"): \(msg.content)"
                }.joined(separator: " | ")
            }

            do {
                let embeddings = try await embeddingService.embedBatch(texts)

                for (i, thread) in batch.enumerated() {
                    let convoMessages = thread.map { msg in
                        ConversationMessage(
                            content: msg.content,
                            isUser: msg.sender == .user,
                            timestamp: msg.timestamp
                        )
                    }

                    let embedded = EmbeddedConversation(
                        id: "conv_\(contactId)_\(thread.first?.id ?? 0)",
                        contactId: contactId,
                        messages: convoMessages,
                        embedding: embeddings[i],
                        timestamp: thread.first?.timestamp ?? Date(),
                        topic: nil
                    )

                    vectorStore.addConversation(embedded)
                }

                processed += batch.count
                progress?(processed, totalItems)

                print("RAG: Embedded \(processed)/\(totalItems) items (threads)")
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms

            } catch {
                print("RAG: Thread batch embedding failed: \(error)")
            }
        }

        // Process legacy pairs for backward compatibility
        let pairBatchSize = 20
        for batchStart in stride(from: 0, to: conversationPairs.count, by: pairBatchSize) {
            let batchEnd = min(batchStart + pairBatchSize, conversationPairs.count)
            let batch = Array(conversationPairs[batchStart..<batchEnd])

            let texts = batch.map { $0.contactMsg.content }

            do {
                let embeddings = try await embeddingService.embedBatch(texts)

                for (i, pair) in batch.enumerated() {
                    var embedded = EmbeddedMessage(
                        messageId: pair.contactMsg.id,
                        contactId: contactId,
                        content: pair.contactMsg.content,
                        embedding: embeddings[i],
                        isUserMessage: false,
                        timestamp: pair.contactMsg.timestamp
                    )
                    embedded.responseContent = pair.userResponse.content

                    vectorStore.add(embedded)
                }

                processed += batch.count
                progress?(processed, totalItems)

                print("RAG: Embedded \(processed)/\(totalItems) items (pairs)")
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms

            } catch {
                print("RAG: Pair batch embedding failed: \(error)")
            }
        }

        // Save to disk
        vectorStore.saveToDisk()
        vectorStore.saveConversationsToDisk()

        print("RAG: Completed embedding generation. Total: \(vectorStore.count) embeddings, \(vectorStore.conversationCount) conversations")
    }

    /// Build conversation threads from messages
    /// A thread is a sequence of exchanges where messages are close in time (within 30 min)
    private func buildConversationThreads(from messages: [Message]) -> [[Message]] {
        var threads: [[Message]] = []
        var currentThread: [Message] = []

        for (index, message) in messages.enumerated() {
            if currentThread.isEmpty {
                currentThread.append(message)
            } else {
                // Check time gap - if more than 30 minutes, start new thread
                let lastMessage = currentThread.last!
                let timeDiff = message.timestamp.timeIntervalSince(lastMessage.timestamp)

                if timeDiff > 1800 { // 30 minutes in seconds
                    // Save current thread if it has at least 4 messages (2 exchanges)
                    if currentThread.count >= 4 {
                        threads.append(currentThread)
                    }
                    currentThread = [message]
                } else {
                    currentThread.append(message)

                    // Cap thread at 8 messages to keep context focused
                    if currentThread.count >= 8 {
                        threads.append(currentThread)
                        currentThread = []
                    }
                }
            }
        }

        // Don't forget last thread
        if currentThread.count >= 4 {
            threads.append(currentThread)
        }

        return threads
    }

    // MARK: - Semantic Search

    /// Find semantically similar conversations for context
    func findSimilarContext(
        for message: String,
        contactId: Int64,
        limit: Int = 5
    ) async throws -> [(contactMessage: String, userResponse: String, similarity: Float)] {
        guard settings.isOpenAIConfigured else {
            return []
        }

        guard vectorStore.hasEmbeddings(for: contactId) else {
            print("RAG: No embeddings for contact \(contactId)")
            return []
        }

        // Embed the query
        let queryEmbedding = try await embeddingService.embed(message)

        // Find similar conversations
        let results = vectorStore.findSimilarConversations(
            queryEmbedding: queryEmbedding,
            contactId: contactId,
            limit: limit
        )

        print("RAG: Found \(results.count) similar conversations (top similarity: \(results.first?.similarity ?? 0))")

        return results
    }

    /// Find semantically similar conversation threads for richer context
    func findSimilarThreads(
        for message: String,
        contactId: Int64,
        limit: Int = 3
    ) async throws -> [ConversationThread] {
        guard settings.isOpenAIConfigured else {
            return []
        }

        guard vectorStore.hasConversations(for: contactId) else {
            print("RAG: No conversation threads for contact \(contactId)")
            return []
        }

        // Embed the query
        let queryEmbedding = try await embeddingService.embed(message)

        // Find similar conversation threads
        let results = vectorStore.findSimilarConversationThreads(
            queryEmbedding: queryEmbedding,
            contactId: contactId,
            limit: limit
        )

        print("RAG: Found \(results.count) similar conversation threads (top similarity: \(results.first?.similarity ?? 0))")

        // Convert to ConversationThread format
        return results.map { (convo, similarity) in
            ConversationThread(
                messages: convo.messages,
                similarity: similarity
            )
        }
    }

    // MARK: - Stats

    var embeddingCount: Int {
        vectorStore.count
    }

    var conversationCount: Int {
        vectorStore.conversationCount
    }

    func hasEmbeddings(for contactId: Int64) -> Bool {
        vectorStore.hasEmbeddings(for: contactId)
    }

    func hasConversations(for contactId: Int64) -> Bool {
        vectorStore.hasConversations(for: contactId)
    }
}
