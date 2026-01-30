import Foundation

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

        // Build conversation pairs (contact message + user response)
        var conversationPairs: [(contactMsg: Message, userResponse: Message)] = []
        for i in 0..<(messages.count - 1) {
            if messages[i].sender == .contact && messages[i + 1].sender == .user {
                conversationPairs.append((messages[i], messages[i + 1]))
            }
        }

        print("RAG: Found \(conversationPairs.count) conversation pairs to embed")

        // Process in batches to avoid API limits
        let batchSize = 20
        var processed = 0

        for batchStart in stride(from: 0, to: conversationPairs.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, conversationPairs.count)
            let batch = Array(conversationPairs[batchStart..<batchEnd])

            // Get texts to embed (contact messages)
            let texts = batch.map { $0.contactMsg.content }

            do {
                // Generate embeddings
                let embeddings = try await embeddingService.embedBatch(texts)

                // Store with responses
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
                progress?(processed, conversationPairs.count)

                print("RAG: Embedded \(processed)/\(conversationPairs.count) pairs")

                // Rate limiting - small delay between batches
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms

            } catch {
                print("RAG: Batch embedding failed: \(error)")
                // Continue with next batch
            }
        }

        // Save to disk
        vectorStore.saveToDisk()

        print("RAG: Completed embedding generation. Total: \(vectorStore.count) embeddings")
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

    // MARK: - Stats

    var embeddingCount: Int {
        vectorStore.count
    }

    func hasEmbeddings(for contactId: Int64) -> Bool {
        vectorStore.hasEmbeddings(for: contactId)
    }
}
