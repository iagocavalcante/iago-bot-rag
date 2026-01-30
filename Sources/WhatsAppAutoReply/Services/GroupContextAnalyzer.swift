import Foundation

/// Analyzes group chat context to determine when to participate in conversations
class GroupContextAnalyzer {
    static let shared = GroupContextAnalyzer()

    private let ragManager = RAGManager.shared
    private let settings = SettingsManager.shared

    /// Recent messages per group (groupName -> messages)
    private var groupContexts: [String: [GroupMessage]] = [:]

    /// Maximum messages to track per group
    private let maxContextSize = 15

    /// Minimum messages needed to analyze topic
    private let minContextSize = 3

    /// Minimum topic relevance score to trigger response (0.0 - 1.0)
    private let relevanceThreshold: Float = 0.45

    // MARK: - Message Tracking

    /// Add a message to group context
    func addMessage(groupName: String, sender: String, content: String, timestamp: Date = Date()) {
        var messages = groupContexts[groupName] ?? []

        let message = GroupMessage(
            sender: sender,
            content: content,
            timestamp: timestamp
        )

        messages.append(message)

        // Keep only recent messages
        if messages.count > maxContextSize {
            messages = Array(messages.suffix(maxContextSize))
        }

        groupContexts[groupName] = messages
    }

    /// Get current context for a group
    func getContext(for groupName: String) -> [GroupMessage] {
        return groupContexts[groupName] ?? []
    }

    /// Clear context for a group (e.g., when conversation topic clearly changes)
    func clearContext(for groupName: String) {
        groupContexts[groupName] = nil
    }

    // MARK: - Topic Analysis

    /// Analyze if current group topic is relevant to the user
    /// Returns (shouldParticipate, reason, relevanceScore)
    func shouldParticipate(
        in groupName: String,
        contactId: Int64,
        currentMessage: String
    ) async -> (participate: Bool, reason: String, score: Float) {
        let context = getContext(for: groupName)

        // Need minimum context to analyze
        guard context.count >= minContextSize else {
            return (false, "Not enough context (\(context.count)/\(minContextSize) messages)", 0)
        }

        // Extract current topic from recent messages
        let topicText = extractTopicText(from: context, currentMessage: currentMessage)

        // Check if topic matches user's interests using RAG
        do {
            let relevanceScore = try await checkTopicRelevance(
                topic: topicText,
                contactId: contactId
            )

            if relevanceScore >= relevanceThreshold {
                return (true, "Topic relevance: \(String(format: "%.0f", relevanceScore * 100))%", relevanceScore)
            } else {
                return (false, "Topic not relevant enough (\(String(format: "%.0f", relevanceScore * 100))%)", relevanceScore)
            }
        } catch {
            print("GroupContext: Topic relevance check failed: \(error)")
            return (false, "Relevance check failed", 0)
        }
    }

    /// Extract topic text from recent messages
    private func extractTopicText(from messages: [GroupMessage], currentMessage: String) -> String {
        // Combine recent messages to form topic context
        var topicParts: [String] = []

        // Add recent messages (skip very short ones like "ok", "sim")
        for msg in messages.suffix(8) {
            if msg.content.count > 10 {
                topicParts.append(msg.content)
            }
        }

        // Add current message
        topicParts.append(currentMessage)

        return topicParts.joined(separator: " | ")
    }

    /// Check if topic is relevant to user's conversation history
    private func checkTopicRelevance(topic: String, contactId: Int64) async throws -> Float {
        guard settings.isOpenAIConfigured else {
            return 0
        }

        // Use RAG to find similar conversations
        let similarContexts = try await ragManager.findSimilarContext(
            for: topic,
            contactId: contactId,
            limit: 5
        )

        guard !similarContexts.isEmpty else {
            return 0
        }

        // Average similarity of top matches
        let avgSimilarity = similarContexts.map { $0.similarity }.reduce(0, +) / Float(similarContexts.count)

        // Boost if multiple high-relevance matches
        let highRelevanceCount = similarContexts.filter { $0.similarity > 0.5 }.count
        let boost: Float = highRelevanceCount >= 2 ? 0.1 : 0

        return min(1.0, avgSimilarity + boost)
    }

    // MARK: - Interest Extraction

    /// Extract topics the user frequently engages with
    func extractUserInterests(from messages: [Message]) -> [String] {
        var topics: [String: Int] = [:]

        // Common topic keywords to track
        let topicKeywords = [
            // Tech
            "código", "code", "programação", "programming", "bug", "deploy", "api",
            "javascript", "python", "swift", "react", "vue", "node",
            // Work
            "trabalho", "projeto", "reunião", "meeting", "deadline", "cliente",
            // Social
            "festa", "bar", "cerveja", "churrasco", "futebol", "jogo",
            // General
            "dinheiro", "viagem", "carro", "casa", "comida", "filme", "série"
        ]

        // Count topic mentions in user messages
        for msg in messages where msg.sender == .user {
            let content = msg.content.lowercased()
            for keyword in topicKeywords {
                if content.contains(keyword) {
                    topics[keyword, default: 0] += 1
                }
            }
        }

        // Return top topics
        return topics
            .sorted { $0.value > $1.value }
            .prefix(10)
            .map { $0.key }
    }

    // MARK: - Participation Patterns

    /// Check if message looks like a question the user might answer
    func isAnswerableQuestion(_ message: String) -> Bool {
        let lowerMessage = message.lowercased()

        // Direct question patterns
        let questionPatterns = [
            "alguém sabe", "alguem sabe",
            "vocês sabem", "voces sabem",
            "quem sabe", "quem conhece",
            "alguém já", "alguem ja",
            "vocês já", "voces ja",
            "tem alguém", "tem alguem",
            "alguém pode", "alguem pode",
            "quem pode", "quem consegue",
            "como faz", "como que faz",
            "qual é", "qual o",
            "onde", "quando", "quanto",
            "recomenda", "recomendam",
            "indica", "indicam",
            "conhece", "conhecem",
            "já usou", "ja usou", "já usaram", "ja usaram"
        ]

        for pattern in questionPatterns {
            if lowerMessage.contains(pattern) {
                return true
            }
        }

        // Generic question (ends with ?)
        if message.trimmingCharacters(in: .whitespaces).hasSuffix("?") {
            return true
        }

        return false
    }

    /// Check if user typically responds to this type of message
    func matchesResponsePattern(message: String, userMessages: [Message]) -> Bool {
        // Check if any past responses were to similar messages
        // This is a simple heuristic - could be enhanced with ML
        let keywords = extractKeywords(from: message)

        guard !keywords.isEmpty else { return false }

        var matchCount = 0
        for msg in userMessages where msg.sender == .user {
            let msgKeywords = extractKeywords(from: msg.content)
            let commonKeywords = Set(keywords).intersection(Set(msgKeywords))
            if !commonKeywords.isEmpty {
                matchCount += 1
            }
        }

        // If user has responded to similar topics before
        return matchCount >= 2
    }

    private func extractKeywords(from text: String) -> [String] {
        let stopWords = Set(["o", "a", "os", "as", "um", "uma", "de", "da", "do", "em", "na", "no",
                            "e", "é", "que", "para", "com", "não", "nao", "por", "se", "mas",
                            "como", "mais", "já", "ja", "muito", "isso", "esse", "essa"])

        return text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 && !stopWords.contains($0) }
    }
}

// MARK: - Models

struct GroupMessage {
    let sender: String
    let content: String
    let timestamp: Date
}
