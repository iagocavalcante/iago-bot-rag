import Foundation

/// Length patterns for different contexts
struct LengthPatterns: Codable, Equatable {
    var shortContexts: [String]   // When user writes short (greetings, confirmations)
    var longContexts: [String]    // When user writes long (explanations, stories)

    init() {
        shortContexts = ["greeting", "confirmation", "acknowledgment"]
        longContexts = ["explanation", "story", "question"]
    }
}

/// Emotional response patterns
struct EmotionalPatterns: Codable, Equatable {
    var happyPhrases: [String]    // How user expresses happiness
    var sadPhrases: [String]      // How user expresses sadness/empathy
    var excitedPhrases: [String]  // How user shows excitement
    var frustratedPhrases: [String] // How user shows frustration

    init() {
        happyPhrases = []
        sadPhrases = []
        excitedPhrases = []
        frustratedPhrases = []
    }
}

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

    // MARK: - Enhanced Patterns (v2)

    /// Favorite emojis with usage count
    var favoriteEmojis: [String]

    /// Signature phrases unique to this user
    var signaturePhrases: [String]

    /// How user asks questions ("cadê", "onde", "como assim", etc.)
    var questionPatterns: [String]

    /// Response starters for different contexts
    var contextualStarters: [String: [String]]

    /// English words mixed into Portuguese
    var englishMixins: [String]

    /// Best quality sample responses (curated)
    var bestResponses: [String]

    /// Response length by context (short/medium/long typical situations)
    var lengthPatterns: LengthPatterns

    /// Emotional response patterns
    var emotionalPatterns: EmotionalPatterns

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
        // Enhanced patterns v2
        self.favoriteEmojis = []
        self.signaturePhrases = []
        self.questionPatterns = []
        self.contextualStarters = [:]
        self.englishMixins = []
        self.bestResponses = []
        self.lengthPatterns = LengthPatterns()
        self.emotionalPatterns = EmotionalPatterns()
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

        // Enhanced patterns v2
        if !favoriteEmojis.isEmpty {
            desc += "FAVORITE EMOJIS: \(favoriteEmojis.prefix(8).joined(separator: " "))\n\n"
        }

        if !signaturePhrases.isEmpty {
            desc += "=== YOUR SIGNATURE PHRASES ===\n"
            desc += "(Use these naturally - they're uniquely YOU)\n"
            for phrase in signaturePhrases.prefix(10) {
                desc += "- \"\(phrase)\"\n"
            }
            desc += "\n"
        }

        if !questionPatterns.isEmpty {
            desc += "HOW YOU ASK QUESTIONS:\n"
            for pattern in questionPatterns.prefix(5) {
                desc += "- \"\(pattern)...\"\n"
            }
            desc += "\n"
        }

        if !englishMixins.isEmpty {
            desc += "ENGLISH WORDS YOU MIX IN: \(englishMixins.prefix(8).joined(separator: ", "))\n\n"
        }

        // Emotional patterns
        if !emotionalPatterns.happyPhrases.isEmpty || !emotionalPatterns.excitedPhrases.isEmpty {
            desc += "WHEN HAPPY/EXCITED:\n"
            for phrase in (emotionalPatterns.happyPhrases + emotionalPatterns.excitedPhrases).prefix(5) {
                desc += "- \"\(phrase)\"\n"
            }
            desc += "\n"
        }

        if !emotionalPatterns.sadPhrases.isEmpty {
            desc += "WHEN SHOWING EMPATHY:\n"
            for phrase in emotionalPatterns.sadPhrases.prefix(3) {
                desc += "- \"\(phrase)\"\n"
            }
            desc += "\n"
        }

        // Best quality examples
        if !bestResponses.isEmpty {
            desc += "=== YOUR BEST RESPONSES (emulate these) ===\n"
            for response in bestResponses.prefix(5) {
                desc += "• \"\(response)\"\n"
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
