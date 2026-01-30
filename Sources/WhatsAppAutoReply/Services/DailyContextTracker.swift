import Foundation

/// Tracks today's conversation context per contact for natural conversation flow
class DailyContextTracker {
    static let shared = DailyContextTracker()

    private let dbManager: DatabaseManager

    /// Cache of today's context per contact (contactId -> DailyContext)
    private var contextCache: [Int64: DailyContext] = [:]

    /// Last refresh date (to invalidate cache at midnight)
    private var lastRefreshDate: Date?

    init(dbManager: DatabaseManager = .shared) {
        self.dbManager = dbManager
    }

    // MARK: - Public API

    /// Get today's context for a contact
    func getTodayContext(for contactId: Int64) -> DailyContext {
        // Check if cache needs refresh (new day)
        refreshCacheIfNeeded()

        // Return cached context or build new one
        if let cached = contextCache[contactId] {
            return cached
        }

        let context = buildTodayContext(for: contactId)
        contextCache[contactId] = context
        return context
    }

    /// Add a new message to today's context (call when message is detected)
    func trackMessage(contactId: Int64, content: String, isFromUser: Bool, timestamp: Date = Date()) {
        refreshCacheIfNeeded()

        var context = contextCache[contactId] ?? DailyContext()

        let message = DailyMessage(
            content: content,
            isFromUser: isFromUser,
            timestamp: timestamp
        )

        context.messages.append(message)

        // Extract key information from message
        extractContextFromMessage(content, isFromUser: isFromUser, into: &context)

        contextCache[contactId] = context
    }

    /// Generate context summary for prompt
    func getContextSummary(for contactId: Int64) -> String? {
        let context = getTodayContext(for: contactId)

        guard !context.isEmpty else {
            return nil
        }

        var summary = "=== TODAY'S CONTEXT ===\n"

        // Pending items (things you said you'd do)
        if !context.pendingItems.isEmpty {
            summary += "\nThings you mentioned doing today:\n"
            for item in context.pendingItems.prefix(5) {
                summary += "- \(item)\n"
            }
        }

        // Plans/Events mentioned
        if !context.plans.isEmpty {
            summary += "\nPlans/events mentioned:\n"
            for plan in context.plans.prefix(5) {
                summary += "- \(plan)\n"
            }
        }

        // Topics discussed
        if !context.topics.isEmpty {
            summary += "\nTopics discussed earlier:\n"
            for topic in context.topics.prefix(5) {
                summary += "- \(topic)\n"
            }
        }

        // Recent conversation snippet (last few exchanges)
        let recentExchanges = context.messages.suffix(6)
        if !recentExchanges.isEmpty {
            summary += "\nRecent conversation:\n"
            for msg in recentExchanges {
                let speaker = msg.isFromUser ? "You" : "Them"
                let shortContent = String(msg.content.prefix(80))
                summary += "\(speaker): \(shortContent)\(msg.content.count > 80 ? "..." : "")\n"
            }
        }

        // Emotional context
        if let mood = context.detectedMood {
            summary += "\nConversation mood: \(mood)\n"
        }

        summary += "=== END TODAY'S CONTEXT ===\n"

        return summary
    }

    // MARK: - Context Building

    private func buildTodayContext(for contactId: Int64) -> DailyContext {
        var context = DailyContext()

        // Get today's messages from database
        do {
            let allMessages = try dbManager.getMessagesForContact(contactId: contactId, limit: 200)

            // Filter to today only
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())

            let todayMessages = allMessages.filter {
                calendar.isDate($0.timestamp, inSameDayAs: today)
            }

            // Process each message
            for msg in todayMessages {
                let dailyMsg = DailyMessage(
                    content: msg.content,
                    isFromUser: msg.sender == .user,
                    timestamp: msg.timestamp
                )
                context.messages.append(dailyMsg)

                extractContextFromMessage(msg.content, isFromUser: msg.sender == .user, into: &context)
            }

        } catch {
            print("DailyContext: Failed to load messages: \(error)")
        }

        return context
    }

    private func extractContextFromMessage(_ content: String, isFromUser: Bool, into context: inout DailyContext) {
        let lower = content.lowercased()

        // Extract pending items (things user said they'd do)
        if isFromUser {
            extractPendingItems(from: lower, into: &context)
        }

        // Extract plans and events
        extractPlans(from: lower, into: &context)

        // Extract topics
        extractTopics(from: content, into: &context)

        // Detect mood
        detectMood(from: lower, into: &context)
    }

    // MARK: - Extraction Helpers

    private func extractPendingItems(from text: String, into context: inout DailyContext) {
        // Patterns indicating user will do something
        let pendingPatterns = [
            ("vou fazer", "fazer algo"),
            ("vou terminar", "terminar algo"),
            ("vou enviar", "enviar algo"),
            ("vou mandar", "mandar algo"),
            ("depois eu", "fazer algo depois"),
            ("mais tarde", "fazer algo mais tarde"),
            ("já já", "fazer algo em breve"),
            ("daqui a pouco", "fazer algo em breve"),
            ("tô indo", "saindo/indo"),
            ("to indo", "saindo/indo"),
            ("vou lá", "ir a algum lugar"),
            ("preciso", "fazer algo necessário"),
        ]

        for (pattern, _) in pendingPatterns {
            if text.contains(pattern) {
                // Extract the surrounding context
                if let range = text.range(of: pattern) {
                    let start = text.index(range.lowerBound, offsetBy: -20, limitedBy: text.startIndex) ?? text.startIndex
                    let end = text.index(range.upperBound, offsetBy: 30, limitedBy: text.endIndex) ?? text.endIndex
                    let snippet = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !context.pendingItems.contains(snippet) && snippet.count > 10 {
                        context.pendingItems.append(snippet)
                    }
                }
                break
            }
        }
    }

    private func extractPlans(from text: String, into context: inout DailyContext) {
        // Time-related patterns
        let timePatterns = [
            "hoje", "agora", "daqui a pouco", "mais tarde",
            "de manhã", "de tarde", "de noite", "à noite",
            "almoço", "jantar", "reunião", "meeting",
            "às \\d+", "\\d+h", "\\d+:\\d+"
        ]

        // Event keywords
        let eventKeywords = [
            "reunião", "meeting", "call", "ligação",
            "almoço", "jantar", "café",
            "médico", "dentista", "consulta",
            "academia", "treino", "aula",
            "entrega", "deadline", "prazo",
            "viagem", "voo", "aeroporto",
            "aniversário", "festa", "evento"
        ]

        for keyword in eventKeywords {
            if text.contains(keyword) {
                // Extract context around the keyword
                if let range = text.range(of: keyword) {
                    let start = text.index(range.lowerBound, offsetBy: -15, limitedBy: text.startIndex) ?? text.startIndex
                    let end = text.index(range.upperBound, offsetBy: 25, limitedBy: text.endIndex) ?? text.endIndex
                    let snippet = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !context.plans.contains(snippet) && snippet.count > 5 {
                        context.plans.append(snippet)
                    }
                }
            }
        }
    }

    private func extractTopics(from text: String, into context: inout DailyContext) {
        // Extract significant topics (nouns/subjects)
        let topicIndicators = [
            // Work
            "projeto", "trabalho", "cliente", "código", "bug", "deploy", "release",
            // Personal
            "família", "namorada", "namorado", "amigo", "amiga",
            // Activities
            "filme", "série", "jogo", "show", "viagem",
            // Problems/situations
            "problema", "situação", "dificuldade", "dúvida"
        ]

        let lower = text.lowercased()
        for topic in topicIndicators {
            if lower.contains(topic) {
                // Get sentence containing the topic
                let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
                for sentence in sentences {
                    if sentence.lowercased().contains(topic) {
                        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.count > 10 && trimmed.count < 100 && !context.topics.contains(trimmed) {
                            context.topics.append(trimmed)
                            break
                        }
                    }
                }
            }
        }
    }

    private func detectMood(from text: String, into context: inout DailyContext) {
        // Positive indicators
        let positivePatterns = ["feliz", "animado", "ótimo", "massa", "top", "show", "dahora", "legal", "bom"]
        // Negative indicators
        let negativePatterns = ["triste", "cansado", "estressado", "mal", "péssimo", "ruim", "chateado", "irritado"]
        // Busy indicators
        let busyPatterns = ["correria", "ocupado", "sem tempo", "cheio de coisa", "muito trabalho"]

        for pattern in positivePatterns {
            if text.contains(pattern) {
                context.detectedMood = "positive/upbeat"
                return
            }
        }

        for pattern in negativePatterns {
            if text.contains(pattern) {
                context.detectedMood = "negative/down"
                return
            }
        }

        for pattern in busyPatterns {
            if text.contains(pattern) {
                context.detectedMood = "busy/rushed"
                return
            }
        }
    }

    // MARK: - Cache Management

    private func refreshCacheIfNeeded() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        if let lastRefresh = lastRefreshDate {
            if !calendar.isDate(lastRefresh, inSameDayAs: today) {
                // New day - clear cache
                contextCache.removeAll()
                print("DailyContext: Cache cleared for new day")
            }
        }

        lastRefreshDate = Date()
    }

    /// Force refresh context for a contact
    func refreshContext(for contactId: Int64) {
        contextCache[contactId] = nil
        _ = getTodayContext(for: contactId)
    }

    /// Clear all cached contexts
    func clearAllContexts() {
        contextCache.removeAll()
    }
}

// MARK: - Models

struct DailyContext {
    var messages: [DailyMessage] = []
    var pendingItems: [String] = []  // Things user said they'd do
    var plans: [String] = []          // Events/plans mentioned
    var topics: [String] = []         // Main topics discussed
    var detectedMood: String?         // Conversation mood

    var isEmpty: Bool {
        messages.isEmpty && pendingItems.isEmpty && plans.isEmpty && topics.isEmpty
    }

    var messageCount: Int {
        messages.count
    }
}

struct DailyMessage {
    let content: String
    let isFromUser: Bool
    let timestamp: Date
}
