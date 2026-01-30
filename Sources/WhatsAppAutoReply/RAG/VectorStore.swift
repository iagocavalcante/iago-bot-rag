import Foundation

/// Represents a message with its embedding
struct EmbeddedMessage: Codable {
    let messageId: Int64
    let contactId: Int64
    let content: String
    let embedding: [Float]
    let isUserMessage: Bool
    let timestamp: Date

    /// The response that followed this message (if this is a contact message)
    var responseContent: String?
}

/// Represents a conversation thread with its embedding
/// A thread is a sequence of 3-6 message exchanges that form a coherent conversation
struct EmbeddedConversation: Codable {
    let id: String // Unique ID based on first message ID
    let contactId: Int64
    let messages: [ConversationMessage] // Full conversation thread
    let embedding: [Float] // Embedding of the entire conversation context
    let timestamp: Date // Timestamp of first message
    let topic: String? // Optional inferred topic

    /// Full conversation text for embedding
    var contextText: String {
        messages.map { "\($0.isUser ? "user" : "contact"): \($0.content)" }.joined(separator: "\n")
    }

    /// Just the contact messages for similarity matching
    var contactContext: String {
        messages.filter { !$0.isUser }.map { $0.content }.joined(separator: " ")
    }
}

/// Simplified message for storage in conversation threads
struct ConversationMessage: Codable {
    let content: String
    let isUser: Bool
    let timestamp: Date
}

/// In-memory vector store for semantic search
class VectorStore {
    private var embeddings: [EmbeddedMessage] = []
    private var conversations: [EmbeddedConversation] = []
    private let storageURL: URL
    private let conversationsURL: URL

    init() {
        // Store embeddings in app support directory
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("WhatsAppAutoReply")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        self.storageURL = appDir.appendingPathComponent("embeddings.json")
        self.conversationsURL = appDir.appendingPathComponent("conversations.json")

        loadFromDisk()
        loadConversationsFromDisk()
    }

    // MARK: - Storage

    func add(_ embeddedMessage: EmbeddedMessage) {
        // Remove existing entry for same message ID if present
        embeddings.removeAll { $0.messageId == embeddedMessage.messageId }
        embeddings.append(embeddedMessage)
    }

    func addBatch(_ messages: [EmbeddedMessage]) {
        let existingIds = Set(embeddings.map { $0.messageId })
        let newMessages = messages.filter { !existingIds.contains($0.messageId) }
        embeddings.append(contentsOf: newMessages)
    }

    func saveToDisk() {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(embeddings)
            try data.write(to: storageURL)
            print("Saved \(embeddings.count) embeddings to disk")
        } catch {
            print("Failed to save embeddings: \(error)")
        }
    }

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }

        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            embeddings = try decoder.decode([EmbeddedMessage].self, from: data)
            print("Loaded \(embeddings.count) embeddings from disk")
        } catch {
            print("Failed to load embeddings: \(error)")
            embeddings = []
        }
    }

    // MARK: - Conversation Storage

    func addConversation(_ conversation: EmbeddedConversation) {
        // Remove existing entry for same ID if present
        conversations.removeAll { $0.id == conversation.id }
        conversations.append(conversation)
    }

    func addConversationBatch(_ convos: [EmbeddedConversation]) {
        let existingIds = Set(conversations.map { $0.id })
        let newConvos = convos.filter { !existingIds.contains($0.id) }
        conversations.append(contentsOf: newConvos)
    }

    func saveConversationsToDisk() {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(conversations)
            try data.write(to: conversationsURL)
            print("Saved \(conversations.count) conversations to disk")
        } catch {
            print("Failed to save conversations: \(error)")
        }
    }

    private func loadConversationsFromDisk() {
        guard FileManager.default.fileExists(atPath: conversationsURL.path) else { return }

        do {
            let data = try Data(contentsOf: conversationsURL)
            let decoder = JSONDecoder()
            conversations = try decoder.decode([EmbeddedConversation].self, from: data)
            print("Loaded \(conversations.count) conversations from disk")
        } catch {
            print("Failed to load conversations: \(error)")
            conversations = []
        }
    }

    // MARK: - Search

    /// Find most similar messages to the query embedding
    func search(
        queryEmbedding: [Float],
        contactId: Int64? = nil,
        limit: Int = 10,
        minSimilarity: Float = 0.5
    ) -> [SearchResult] {
        var results: [SearchResult] = []

        for embedded in embeddings {
            // Filter by contact if specified
            if let cId = contactId, embedded.contactId != cId {
                continue
            }

            let similarity = cosineSimilarity(queryEmbedding, embedded.embedding)

            if similarity >= minSimilarity {
                results.append(SearchResult(
                    message: embedded,
                    similarity: similarity
                ))
            }
        }

        // Sort by similarity (highest first) and limit
        return results
            .sorted { $0.similarity > $1.similarity }
            .prefix(limit)
            .map { $0 }
    }

    /// Find similar conversation pairs (contact message + user response) - legacy method
    func findSimilarConversations(
        queryEmbedding: [Float],
        contactId: Int64,
        limit: Int = 5
    ) -> [(contactMessage: String, userResponse: String, similarity: Float)] {
        // Find contact messages with responses
        let contactMessages = embeddings.filter {
            $0.contactId == contactId &&
            !$0.isUserMessage &&
            $0.responseContent != nil
        }

        var results: [(String, String, Float)] = []

        for msg in contactMessages {
            let similarity = cosineSimilarity(queryEmbedding, msg.embedding)

            if similarity > 0.3, let response = msg.responseContent {
                results.append((msg.content, response, similarity))
            }
        }

        return results
            .sorted { $0.2 > $1.2 }
            .prefix(limit)
            .map { $0 }
    }

    /// Find similar conversation threads (full multi-turn context)
    func findSimilarConversationThreads(
        queryEmbedding: [Float],
        contactId: Int64,
        limit: Int = 3
    ) -> [(conversation: EmbeddedConversation, similarity: Float)] {
        let contactConversations = conversations.filter { $0.contactId == contactId }

        var results: [(EmbeddedConversation, Float)] = []

        for convo in contactConversations {
            let similarity = cosineSimilarity(queryEmbedding, convo.embedding)

            if similarity > 0.25 { // Lower threshold for conversation context
                results.append((convo, similarity))
            }
        }

        return results
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Stats

    var count: Int {
        embeddings.count
    }

    var conversationCount: Int {
        conversations.count
    }

    func countForContact(_ contactId: Int64) -> Int {
        embeddings.filter { $0.contactId == contactId }.count
    }

    func conversationCountForContact(_ contactId: Int64) -> Int {
        conversations.filter { $0.contactId == contactId }.count
    }

    func hasEmbeddings(for contactId: Int64) -> Bool {
        embeddings.contains { $0.contactId == contactId }
    }

    func hasConversations(for contactId: Int64) -> Bool {
        conversations.contains { $0.contactId == contactId }
    }

    // MARK: - Math

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0

        for i in 0..<a.count {
            dotProduct += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }

        let denominator = sqrt(normA) * sqrt(normB)
        guard denominator > 0 else { return 0 }

        return dotProduct / denominator
    }
}

// MARK: - Search Result

struct SearchResult {
    let message: EmbeddedMessage
    let similarity: Float
}
