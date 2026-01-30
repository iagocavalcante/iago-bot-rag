import Foundation

class ResponseGenerator {
    private let ollamaClient: OllamaClient
    private let dbManager: DatabaseManager
    private let userName: String

    init(
        ollamaClient: OllamaClient = OllamaClient(),
        dbManager: DatabaseManager = .shared,
        userName: String = "Iago Cavalcante"
    ) {
        self.ollamaClient = ollamaClient
        self.dbManager = dbManager
        self.userName = userName
    }

    func generateResponse(for contactName: String, message: String) async throws -> String? {
        // Find contact
        guard let contact = try dbManager.getContactByName(contactName) else {
            print("Contact not found: \(contactName)")
            return nil
        }

        // Check if auto-reply is enabled
        guard contact.autoReplyEnabled else {
            print("Auto-reply disabled for: \(contactName)")
            return nil
        }

        // Sanitize input to prevent prompt injection
        let sanitizedMessage = sanitizeInput(message)

        // Get example messages for this contact
        let examples = try dbManager.getMessagesForContact(contactId: contact.id, limit: 50)

        guard examples.count >= 10 else {
            print("Not enough message history for: \(contactName)")
            return nil
        }

        // Find conversation pairs (contact message followed by user response)
        let pairs = findConversationPairs(messages: examples)

        guard pairs.count >= 5 else {
            print("Not enough conversation pairs for: \(contactName)")
            return nil
        }

        // Take most recent relevant pairs
        let recentPairs = Array(pairs.suffix(15))

        // Build prompt
        let prompt = ollamaClient.buildPrompt(
            contactName: contactName,
            examples: recentPairs.flatMap { [$0.0, $0.1] },
            newMessage: sanitizedMessage,
            userName: userName
        )

        // Generate response
        let response = try await ollamaClient.generateResponse(prompt: prompt)

        // Clean up and validate response
        let cleaned = cleanResponse(response)

        // Don't send empty responses (blocked by security)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func findConversationPairs(messages: [Message]) -> [(Message, Message)] {
        var pairs: [(Message, Message)] = []

        for i in 0..<(messages.count - 1) {
            if messages[i].sender == .contact && messages[i + 1].sender == .user {
                pairs.append((messages[i], messages[i + 1]))
            }
        }

        return pairs
    }

    /// Sanitize incoming message to prevent prompt injection
    private func sanitizeInput(_ message: String) -> String {
        var sanitized = message

        // Remove common injection patterns
        let dangerousPatterns = [
            "ignore all",
            "ignore previous",
            "ignore prior",
            "disregard",
            "forget everything",
            "new instructions",
            "system prompt",
            "you are now",
            "act as",
            "pretend to be",
            "respond only with",
            "output only",
            "```",
            "\\n\\n",
            "---",
            "###",
        ]

        let lowerMessage = sanitized.lowercased()
        for pattern in dangerousPatterns {
            if lowerMessage.contains(pattern) {
                // Replace suspicious content with [blocked]
                sanitized = sanitized.replacingOccurrences(
                    of: pattern,
                    with: "[...]",
                    options: .caseInsensitive
                )
            }
        }

        // Limit message length to prevent token stuffing
        if sanitized.count > 500 {
            sanitized = String(sanitized.prefix(500))
        }

        return sanitized
    }

    private func cleanResponse(_ response: String) -> String {
        var cleaned = response

        // Remove any accidental self-references
        let prefixes = ["Iago Cavalcante:", "Iago:", "Me:"]
        for prefix in prefixes {
            if cleaned.hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count))
            }
        }

        // Trim and limit length
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        // Block suspicious response patterns (potential injection success)
        let suspiciousPatterns = [
            "system prompt",
            "my instructions",
            "I was told to",
            "I cannot",
            "As an AI",
            "I'm an AI",
            "json",
            "```",
            "{",
            "}",
        ]

        let lowerCleaned = cleaned.lowercased()
        for pattern in suspiciousPatterns {
            if lowerCleaned.contains(pattern.lowercased()) {
                return "" // Block the response entirely
            }
        }

        // Limit to reasonable length
        if cleaned.count > 200 {
            // Find a natural break point
            if let range = cleaned.range(of: ".", options: .backwards, range: cleaned.startIndex..<cleaned.index(cleaned.startIndex, offsetBy: 200)) {
                cleaned = String(cleaned[..<range.upperBound])
            } else {
                cleaned = String(cleaned.prefix(200))
            }
        }

        return cleaned
    }
}
