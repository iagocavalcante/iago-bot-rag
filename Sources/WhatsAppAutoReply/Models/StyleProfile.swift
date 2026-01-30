import Foundation

/// Style profile extracted from user's message history with a contact
struct StyleProfile: Codable, Equatable {
    /// Average response length in characters
    var avgResponseLength: Int

    /// Emoji usage frequency (0.0 = never, 1.0 = every message)
    var emojiFrequency: Double

    /// Preferred laugh style (e.g., "kkkk", "haha", "rs", "kkk")
    var laughStyle: String?

    /// Formality level (0.0 = very casual, 1.0 = formal)
    var formalityLevel: Double

    /// Common greeting phrases
    var greetings: [String]

    /// Common closing phrases
    var closings: [String]

    /// Frequently used expressions/phrases
    var commonPhrases: [String]

    /// Whether user typically uses abbreviations (vc, tb, pq, etc.)
    var usesAbbreviations: Bool

    /// Whether user typically uses punctuation
    var usesPunctuation: Bool

    /// Sample responses for few-shot learning
    var sampleResponses: [String]

    init() {
        self.avgResponseLength = 50
        self.emojiFrequency = 0.3
        self.laughStyle = "kkkk"
        self.formalityLevel = 0.3
        self.greetings = []
        self.closings = []
        self.commonPhrases = []
        self.usesAbbreviations = true
        self.usesPunctuation = false
        self.sampleResponses = []
    }

    /// Generate a style description for the LLM prompt
    func toPromptDescription() -> String {
        var desc = "Response style guidelines:\n"

        // Length
        if avgResponseLength < 30 {
            desc += "- Keep responses VERY short (1-2 words or a single phrase)\n"
        } else if avgResponseLength < 60 {
            desc += "- Keep responses short (1 sentence max)\n"
        } else if avgResponseLength < 120 {
            desc += "- Medium length responses (1-2 sentences)\n"
        } else {
            desc += "- Can use longer responses when needed\n"
        }

        // Emojis
        if emojiFrequency > 0.5 {
            desc += "- Use emojis frequently\n"
        } else if emojiFrequency > 0.2 {
            desc += "- Use emojis occasionally\n"
        } else {
            desc += "- Rarely use emojis\n"
        }

        // Laugh style
        if let laugh = laughStyle, !laugh.isEmpty {
            desc += "- For laughing, use \"\(laugh)\"\n"
        }

        // Formality
        if formalityLevel < 0.3 {
            desc += "- Very casual/informal tone\n"
        } else if formalityLevel < 0.6 {
            desc += "- Casual but friendly tone\n"
        } else {
            desc += "- More formal/polite tone\n"
        }

        // Abbreviations
        if usesAbbreviations {
            desc += "- Use common abbreviations (vc, tb, pq, q, oq, etc.)\n"
        }

        // Punctuation
        if !usesPunctuation {
            desc += "- Don't use much punctuation (no periods at end)\n"
        }

        // Common phrases
        if !commonPhrases.isEmpty {
            let phrases = commonPhrases.prefix(5).joined(separator: "\", \"")
            desc += "- Often uses phrases like: \"\(phrases)\"\n"
        }

        return desc
    }

    /// Encode to JSON string for database storage
    func toJSON() -> String? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decode from JSON string
    static func fromJSON(_ json: String) -> StyleProfile? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StyleProfile.self, from: data)
    }
}
