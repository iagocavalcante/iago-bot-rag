import Foundation

/// Decides whether a message warrants an auto-reply
class ResponseDecider {
    private let settings: SettingsManager
    private let groupContextAnalyzer = GroupContextAnalyzer.shared

    init(settings: SettingsManager = .shared) {
        self.settings = settings
    }

    // MARK: - Group Topic-Based Participation

    /// Check if we should participate in a group conversation based on topic relevance
    /// This is separate from mention detection - it analyzes the conversation topic
    func shouldParticipateInGroup(
        groupName: String,
        message: String,
        sender: String,
        contactId: Int64,
        recentMessages: [Message] = []
    ) async -> GroupParticipationDecision {
        // Add message to group context tracker
        groupContextAnalyzer.addMessage(
            groupName: groupName,
            sender: sender,
            content: message
        )

        // Check if it's a general question that user might answer
        if groupContextAnalyzer.isAnswerableQuestion(message) {
            // Check if topic is relevant to user
            let (participate, reason, score) = await groupContextAnalyzer.shouldParticipate(
                in: groupName,
                contactId: contactId,
                currentMessage: message
            )

            if participate {
                return .participate(
                    reason: "Answerable question on relevant topic: \(reason)",
                    confidence: score > 0.6 ? .high : .medium
                )
            }
        }

        // Check topic relevance for general participation
        let (participate, reason, score) = await groupContextAnalyzer.shouldParticipate(
            in: groupName,
            contactId: contactId,
            currentMessage: message
        )

        if participate && score > 0.55 {
            // Higher threshold for non-question messages
            return .participate(
                reason: "Topic highly relevant: \(reason)",
                confidence: score > 0.7 ? .high : .medium
            )
        }

        // Check if user typically responds to this pattern
        if groupContextAnalyzer.matchesResponsePattern(message: message, userMessages: recentMessages) {
            return .participate(
                reason: "Matches historical response pattern",
                confidence: .low
            )
        }

        return .skip(reason: reason.isEmpty ? "Topic not relevant to user" : reason)
    }

    /// Track a message in group context (call for all group messages, not just triggers)
    func trackGroupMessage(groupName: String, sender: String, content: String) {
        groupContextAnalyzer.addMessage(
            groupName: groupName,
            sender: sender,
            content: content
        )
    }

    /// Analyze a message and decide if we should respond
    func shouldRespond(
        to message: String,
        from contactName: String,
        contact: Contact,
        recentMessages: [Message] = []
    ) -> ResponseDecision {
        // Check if it's an appropriate time to respond
        if !isAppropriateTime() {
            return .skip(reason: "Outside normal response hours")
        }

        // Check if message is just a reaction/acknowledgment (shouldn't reply)
        if isJustAcknowledgment(message) {
            return .skip(reason: "Message is just an acknowledgment")
        }

        // Check if it's a direct question - always respond
        if isQuestion(message) {
            return .respond(confidence: .high, reason: "Direct question detected")
        }

        // Check if user is mentioned/addressed - respond
        if isDirectlyAddressed(message) {
            return .respond(confidence: .high, reason: "Directly addressed")
        }

        // Check if it's a greeting - respond
        if isGreeting(message) {
            return .respond(confidence: .high, reason: "Greeting detected")
        }

        // Check if it's a request/call to action
        if isRequest(message) {
            return .respond(confidence: .medium, reason: "Request/call to action")
        }

        // Check conversation context - are we mid-conversation?
        if isContinuingConversation(recentMessages) {
            // In an active conversation, more likely to respond
            if messageExpectsReply(message) {
                return .respond(confidence: .medium, reason: "Active conversation, message expects reply")
            }
        }

        // Default: statements/comments don't always need a reply
        if isJustStatement(message) {
            return .skip(reason: "Just a statement, no response needed")
        }

        // When in doubt, respond with medium confidence
        return .respond(confidence: .low, reason: "Default: might need response")
    }

    // MARK: - Time Analysis

    private func isAppropriateTime() -> Bool {
        let hour = Calendar.current.component(.hour, from: Date())

        // Don't auto-reply between midnight and 7am
        if hour >= 0 && hour < 7 {
            return false
        }

        return true
    }

    // MARK: - Message Type Detection

    private func isQuestion(_ message: String) -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)

        // Ends with question mark
        if trimmed.hasSuffix("?") {
            return true
        }

        let lower = message.lowercased()

        // Portuguese question words
        let questionWords = [
            "quem", "qual", "quando", "onde", "como", "porque", "por que",
            "porquê", "quanto", "quantos", "quantas", "cadê", "cade",
            "o que", "oq", "oque", "pq", "q q", "qq"
        ]

        for word in questionWords {
            if lower.hasPrefix(word + " ") || lower.contains(" " + word + " ") {
                return true
            }
        }

        // Question patterns
        let questionPatterns = [
            "pode me", "vc pode", "você pode", "tu pode",
            "sabe se", "sabe onde", "sabe como", "sabe quando",
            "tem como", "dá pra", "da pra", "é possível",
            "tá sabendo", "ta sabendo", "ficou sabendo",
            "viu isso", "viu que", "já viu",
        ]

        for pattern in questionPatterns {
            if lower.contains(pattern) {
                return true
            }
        }

        return false
    }

    private func isGreeting(_ message: String) -> Bool {
        let lower = message.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        let greetings = [
            "oi", "olá", "ola", "oie", "oii", "oiii",
            "eai", "e ai", "e aí", "eae", "eaí",
            "fala", "fala aí", "fala ai",
            "opa", "salve", "hey", "hi", "hello",
            "bom dia", "boa tarde", "boa noite",
            "tudo bem", "tudo bom", "td bem", "tdb",
            "como vai", "como vc ta", "como você está",
            "beleza", "blz", "suave", "tranquilo",
        ]

        // Check if message starts with or is a greeting
        for greeting in greetings {
            if lower == greeting || lower.hasPrefix(greeting + " ") ||
               lower.hasPrefix(greeting + ",") || lower.hasPrefix(greeting + "!") {
                return true
            }
        }

        return false
    }

    private func isDirectlyAddressed(_ message: String) -> Bool {
        let lower = message.lowercased()
        let userName = settings.userName.lowercased()
        let firstName = userName.split(separator: " ").first.map(String.init) ?? userName

        // Check for @mention or name at start
        let patterns = [
            "@\(userName)",
            "@\(firstName)",
            "\(firstName),",
            "\(firstName) ",
            "ei \(firstName)",
            "oi \(firstName)",
            "fala \(firstName)",
        ]

        for pattern in patterns {
            if lower.contains(pattern) {
                return true
            }
        }

        return false
    }

    private func isRequest(_ message: String) -> Bool {
        let lower = message.lowercased()

        let requestPatterns = [
            "me ajuda", "preciso de", "preciso q", "preciso que",
            "pode fazer", "pode me", "manda pra", "manda para",
            "me passa", "me manda", "me envia",
            "vem cá", "vem ca", "vem aqui",
            "liga pra", "liga para", "me liga",
            "responde", "responda", "fala cmg", "fala comigo",
        ]

        for pattern in requestPatterns {
            if lower.contains(pattern) {
                return true
            }
        }

        return false
    }

    private func isJustAcknowledgment(_ message: String) -> Bool {
        let lower = message.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Very short acknowledgments
        let acknowledgments = [
            "ok", "okay", "k", "kk", "kkk", "kkkk",
            "sim", "não", "nao", "ss", "nn",
            "ah", "ahh", "aham", "uhum", "hm", "hmm",
            "ta", "tá", "blz", "beleza",
            "entendi", "entendo", "certo", "show",
            "massa", "top", "nice", "legal", "dahora",
            "haha", "hehe", "rs", "rsrs",
            "👍", "👌", "✅", "😊", "😂", "🤣", "❤️",
        ]

        // Exact match for short acknowledgments
        if acknowledgments.contains(lower) {
            return true
        }

        // Single emoji
        if message.count <= 4 && containsOnlyEmoji(message) {
            return true
        }

        return false
    }

    private func isJustStatement(_ message: String) -> Bool {
        let lower = message.lowercased()

        // Statements that don't need a response
        let statementPatterns = [
            "tô indo", "to indo", "já vou", "ja vou",
            "cheguei", "saí", "sai",
            "tô aqui", "to aqui", "estou aqui",
            "vou dormir", "boa noite", "até amanhã",
            "depois te falo", "já te aviso", "te aviso",
        ]

        for pattern in statementPatterns {
            if lower.contains(pattern) {
                return true
            }
        }

        return false
    }

    private func messageExpectsReply(_ message: String) -> Bool {
        // Messages that typically expect a response
        let lower = message.lowercased()

        // Trailing indicators
        if lower.hasSuffix("?") || lower.hasSuffix("né") ||
           lower.hasSuffix("ne") || lower.hasSuffix("sabe") {
            return true
        }

        // "And you?" type endings
        let expectsReplyPatterns = [
            "e vc", "e você", "e tu",
            "tb né", "também né", "concorda",
            "o que acha", "oq acha", "q acha",
        ]

        for pattern in expectsReplyPatterns {
            if lower.contains(pattern) {
                return true
            }
        }

        return false
    }

    // MARK: - Conversation Context

    private func isContinuingConversation(_ recentMessages: [Message]) -> Bool {
        guard !recentMessages.isEmpty else { return false }

        // Check if there was recent activity (last 30 minutes)
        if let lastMessage = recentMessages.last {
            let timeSince = Date().timeIntervalSince(lastMessage.timestamp)
            return timeSince < 30 * 60 // 30 minutes
        }

        return false
    }

    // MARK: - Helpers

    private func containsOnlyEmoji(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if !scalar.properties.isEmoji && !scalar.isASCII {
                return false
            }
        }
        return text.unicodeScalars.contains { $0.properties.isEmoji }
    }
}

// MARK: - Decision Types

enum ResponseDecision {
    case respond(confidence: Confidence, reason: String)
    case skip(reason: String)

    var shouldRespond: Bool {
        switch self {
        case .respond: return true
        case .skip: return false
        }
    }

    var reason: String {
        switch self {
        case .respond(_, let reason): return reason
        case .skip(let reason): return reason
        }
    }
}

enum Confidence {
    case high    // Definitely should respond
    case medium  // Probably should respond
    case low     // Maybe should respond
}

// MARK: - Group Participation

enum GroupParticipationDecision {
    case participate(reason: String, confidence: Confidence)
    case skip(reason: String)

    var shouldParticipate: Bool {
        switch self {
        case .participate: return true
        case .skip: return false
        }
    }

    var reason: String {
        switch self {
        case .participate(let reason, _): return reason
        case .skip(let reason): return reason
        }
    }

    var confidence: Confidence? {
        switch self {
        case .participate(_, let confidence): return confidence
        case .skip: return nil
        }
    }
}
