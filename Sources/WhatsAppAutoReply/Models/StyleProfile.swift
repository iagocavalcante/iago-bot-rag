import Foundation

/// Style profile extracted from user's message history with a contact
struct StyleProfile: Codable, Equatable {
    // MARK: - Basic Metrics

    /// Average response length in characters
    var avgResponseLength: Int

    /// Emoji usage frequency (0.0 = never, 1.0 = every message)
    var emojiFrequency: Double

    /// Preferred laugh style (e.g., "kkkk", "haha", "rs", "kkk")
    var laughStyle: String?

    /// Formality level (0.0 = very casual, 1.0 = formal)
    var formalityLevel: Double

    /// Whether user typically uses abbreviations (vc, tb, pq, etc.)
    var usesAbbreviations: Bool

    /// Whether user typically uses punctuation
    var usesPunctuation: Bool

    // MARK: - Phrases & Vocabulary

    /// Common greeting phrases
    var greetings: [String]

    /// Common closing phrases
    var closings: [String]

    /// Frequently used expressions/phrases
    var commonPhrases: [String]

    /// Filler words the user uses ("tipo", "né", "sabe")
    var fillerWords: [String]

    /// Interjections ("uai", "ué", "hmm", "ahh")
    var interjections: [String]

    /// How user says yes ("sim", "ss", "sss", "aham", "uhum", "sip")
    var affirmations: [String]

    /// How user says no ("não", "n", "nn", "nop", "nope")
    var negations: [String]

    /// Most frequently used words (top 20)
    var topWords: [String]

    // MARK: - Writing Patterns

    /// Capitalization style: "lowercase", "normal", "uppercase"
    var capitalizationStyle: String

    /// Whether user repeats letters for emphasis ("siiim", "muuuito")
    var usesLetterRepetition: Bool

    /// Whether user uses multiple punctuation ("???", "!!!", "...")
    var usesMultiplePunctuation: Bool

    /// Common sentence starters
    var sentenceStarters: [String]

    /// Common sentence endings
    var sentenceEndings: [String]

    /// Average words per message
    var avgWordsPerMessage: Double

    // MARK: - Response Patterns

    /// How user responds to questions (sample responses)
    var questionResponses: [String]

    /// How user responds to greetings (sample responses)
    var greetingResponses: [String]

    /// Sample responses for few-shot learning
    var sampleResponses: [String]

    // MARK: - Anti-patterns (things NOT to say)

    /// Words/phrases the user never uses
    var neverUses: [String]

    init() {
        self.avgResponseLength = 50
        self.emojiFrequency = 0.3
        self.laughStyle = "kkkk"
        self.formalityLevel = 0.3
        self.usesAbbreviations = true
        self.usesPunctuation = false
        self.greetings = []
        self.closings = []
        self.commonPhrases = []
        self.fillerWords = []
        self.interjections = []
        self.affirmations = []
        self.negations = []
        self.topWords = []
        self.capitalizationStyle = "lowercase"
        self.usesLetterRepetition = false
        self.usesMultiplePunctuation = false
        self.sentenceStarters = []
        self.sentenceEndings = []
        self.avgWordsPerMessage = 5.0
        self.questionResponses = []
        self.greetingResponses = []
        self.sampleResponses = []
        self.neverUses = []
    }

    /// Generate a detailed style description for the LLM prompt
    func toPromptDescription() -> String {
        var desc = "=== YOUR WRITING STYLE ===\n\n"

        // Length
        desc += "LENGTH:\n"
        if avgResponseLength < 30 {
            desc += "- VERY short responses (1-5 words typically)\n"
        } else if avgResponseLength < 60 {
            desc += "- Short responses (1 sentence max)\n"
        } else if avgResponseLength < 120 {
            desc += "- Medium responses (1-2 sentences)\n"
        } else {
            desc += "- Can write longer when needed\n"
        }
        desc += "- Average ~\(Int(avgWordsPerMessage)) words per message\n\n"

        // Tone & Formality
        desc += "TONE:\n"
        if formalityLevel < 0.3 {
            desc += "- Very casual/informal\n"
        } else if formalityLevel < 0.6 {
            desc += "- Casual but friendly\n"
        } else {
            desc += "- More formal/polite\n"
        }

        // Capitalization
        if capitalizationStyle == "lowercase" {
            desc += "- Write in lowercase (don't capitalize)\n"
        } else if capitalizationStyle == "uppercase" {
            desc += "- Often use CAPS for emphasis\n"
        }
        desc += "\n"

        // Emojis & Expression
        desc += "EXPRESSION:\n"
        if emojiFrequency > 0.5 {
            desc += "- Use emojis frequently\n"
        } else if emojiFrequency > 0.2 {
            desc += "- Use emojis occasionally\n"
        } else {
            desc += "- Rarely use emojis\n"
        }

        if let laugh = laughStyle, !laugh.isEmpty {
            desc += "- For laughing: \"\(laugh)\"\n"
        }

        if usesLetterRepetition {
            desc += "- Repeat letters for emphasis (siiim, muuuito)\n"
        }

        if usesMultiplePunctuation {
            desc += "- Use multiple punctuation (???, !!!, ...)\n"
        }
        desc += "\n"

        // Vocabulary
        desc += "VOCABULARY:\n"
        if usesAbbreviations {
            desc += "- Use abbreviations: vc, tb, pq, q, oq, hj, td, mt\n"
        }

        if !fillerWords.isEmpty {
            desc += "- Filler words: \(fillerWords.prefix(5).joined(separator: ", "))\n"
        }

        if !interjections.isEmpty {
            desc += "- Interjections: \(interjections.prefix(5).joined(separator: ", "))\n"
        }

        if !affirmations.isEmpty {
            desc += "- Say yes as: \(affirmations.prefix(3).joined(separator: ", "))\n"
        }

        if !negations.isEmpty {
            desc += "- Say no as: \(negations.prefix(3).joined(separator: ", "))\n"
        }
        desc += "\n"

        // Common phrases
        if !commonPhrases.isEmpty {
            desc += "PHRASES YOU USE:\n"
            for phrase in commonPhrases.prefix(8) {
                desc += "- \"\(phrase)\"\n"
            }
            desc += "\n"
        }

        // Sentence patterns
        if !sentenceStarters.isEmpty {
            desc += "Often start with: \(sentenceStarters.prefix(5).joined(separator: ", "))\n"
        }

        // Punctuation
        if !usesPunctuation {
            desc += "Don't use periods at the end of messages\n"
        }
        desc += "\n"

        // Anti-patterns
        if !neverUses.isEmpty {
            desc += "=== NEVER SAY ===\n"
            for word in neverUses.prefix(10) {
                desc += "- \"\(word)\"\n"
            }
            desc += "\n"
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
