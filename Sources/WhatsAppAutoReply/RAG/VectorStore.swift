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

/// In-memory vector store for semantic search
class VectorStore {
    private var embeddings: [EmbeddedMessage] = []
    private let storageURL: URL

    init() {
        // Store embeddings in app support directory
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("WhatsAppAutoReply")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        self.storageURL = appDir.appendingPathComponent("embeddings.json")

        loadFromDisk()
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

    /// Find similar conversation pairs (contact message + user response)
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

    // MARK: - Stats

    var count: Int {
        embeddings.count
    }

    func countForContact(_ contactId: Int64) -> Int {
        embeddings.filter { $0.contactId == contactId }.count
    }

    func hasEmbeddings(for contactId: Int64) -> Bool {
        embeddings.contains { $0.contactId == contactId }
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
