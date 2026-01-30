import Foundation

/// Analyzes message history to extract user's writing style with deep linguistic patterns
class StyleAnalyzer {

    /// Analyze user's messages to build a comprehensive style profile
    func analyzeMessages(_ messages: [Message]) -> StyleProfile {
        // Filter only user's messages
        let userMessages = messages.filter { $0.sender == .user }

        guard !userMessages.isEmpty else {
            return StyleProfile()
        }

        var profile = StyleProfile()

        // Basic metrics
        profile.avgResponseLength = analyzeLength(userMessages)
        profile.avgWordsPerMessage = analyzeWordCount(userMessages)
        profile.emojiFrequency = analyzeEmojiUsage(userMessages)
        profile.laughStyle = detectLaughStyle(userMessages)
        profile.formalityLevel = analyzeFormality(userMessages)
        profile.usesAbbreviations = detectAbbreviations(userMessages)
        profile.usesPunctuation = detectPunctuation(userMessages)

        // Writing patterns
        profile.capitalizationStyle = analyzeCapitalization(userMessages)
        profile.usesLetterRepetition = detectLetterRepetition(userMessages)
        profile.usesMultiplePunctuation = detectMultiplePunctuation(userMessages)

        // Vocabulary analysis
        profile.fillerWords = extractFillerWords(userMessages)
        profile.interjections = extractInterjections(userMessages)
        profile.affirmations = extractAffirmations(userMessages)
        profile.negations = extractNegations(userMessages)
        profile.topWords = extractTopWords(userMessages)
        profile.commonPhrases = extractCommonPhrases(userMessages)

        // Sentence patterns
        profile.sentenceStarters = extractSentenceStarters(userMessages)
        profile.sentenceEndings = extractSentenceEndings(userMessages)
        profile.greetings = extractGreetings(userMessages)
        profile.closings = extractClosings(userMessages)

        // Response patterns (using conversation pairs)
        let allMessages = messages
        profile.questionResponses = extractQuestionResponses(allMessages)
        profile.greetingResponses = extractGreetingResponses(allMessages)

        // Anti-patterns (words user never uses)
        profile.neverUses = detectNeverUses(userMessages)

        // Sample responses
        profile.sampleResponses = selectSampleResponses(userMessages, count: 15)

        return profile
    }

    // MARK: - Basic Metrics

    private func analyzeLength(_ messages: [Message]) -> Int {
        let lengths = messages.map { $0.content.count }
        return lengths.isEmpty ? 50 : lengths.reduce(0, +) / lengths.count
    }

    private func analyzeWordCount(_ messages: [Message]) -> Double {
        let wordCounts = messages.map {
            Double($0.content.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.count)
        }
        return wordCounts.isEmpty ? 5.0 : wordCounts.reduce(0, +) / Double(wordCounts.count)
    }

    private func analyzeEmojiUsage(_ messages: [Message]) -> Double {
        let withEmoji = messages.filter { containsEmoji($0.content) }.count
        return Double(withEmoji) / Double(messages.count)
    }

    private func containsEmoji(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if scalar.properties.isEmoji && scalar.properties.isEmojiPresentation {
                return true
            }
        }
        return false
    }

    // MARK: - Laugh Style Detection

    private func detectLaughStyle(_ messages: [Message]) -> String? {
        let laughPatterns: [(pattern: String, style: String)] = [
            ("k{4,}", "kkkk"),
            ("k{3}", "kkk"),
            ("ha{2,}", "haha"),
            ("he{2,}", "hehe"),
            ("hi{2,}", "hihi"),
            ("rs+", "rs"),
            ("ks{2,}", "ksks"),
            ("😂+", "😂"),
            ("🤣+", "🤣"),
            ("ksk+", "ksk"),
        ]

        var laughCounts: [String: Int] = [:]

        for message in messages {
            let lower = message.content.lowercased()

            for (pattern, style) in laughPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                    let range = NSRange(lower.startIndex..., in: lower)
                    let matches = regex.numberOfMatches(in: lower, options: [], range: range)
                    if matches > 0 {
                        laughCounts[style, default: 0] += matches
                    }
                }
            }
        }

        return laughCounts.max(by: { $0.value < $1.value })?.key
    }

    // MARK: - Formality Analysis

    private func analyzeFormality(_ messages: [Message]) -> Double {
        var formalScore = 0.0
        var totalChecks = 0

        let formalIndicators = [
            "você", "senhor", "senhora", "por favor", "obrigado", "obrigada",
            "bom dia", "boa tarde", "boa noite", "prezado", "atenciosamente",
            "cordialmente", "agradeço", "gostaria", "poderia"
        ]

        let casualIndicators = [
            "vc", "tb", "pq", "oq", "blz", "vlw", "flw", "tmj", "mano", "cara",
            "kkkk", "haha", "opa", "eai", "e ai", "fala", "ae", "po", "pô",
            "tá", "né", "tipo", "mó", "véi", "vei", "mlk", "mn", "tlgd"
        ]

        for message in messages {
            let lower = message.content.lowercased()

            for indicator in formalIndicators {
                if lower.contains(indicator) {
                    formalScore += 1
                    totalChecks += 1
                }
            }

            for indicator in casualIndicators {
                if lower.contains(indicator) {
                    totalChecks += 1
                }
            }
        }

        if totalChecks == 0 { return 0.5 }
        return formalScore / Double(totalChecks)
    }

    // MARK: - Abbreviations & Punctuation

    private func detectAbbreviations(_ messages: [Message]) -> Bool {
        let abbreviations = ["vc", "tb", "pq", "oq", "q ", "n ", "hj", "td", "mt", "mto",
                           "cmg", "ctg", "pra", "pro", "tá", "tô", "vcs", "qnd", "qdo"]

        var abbrevCount = 0
        for message in messages {
            let lower = message.content.lowercased()
            for abbrev in abbreviations {
                if lower.contains(abbrev) {
                    abbrevCount += 1
                    break
                }
            }
        }

        return Double(abbrevCount) / Double(messages.count) > 0.15
    }

    private func detectPunctuation(_ messages: [Message]) -> Bool {
        var withPunctuation = 0

        for message in messages {
            let content = message.content.trimmingCharacters(in: .whitespaces)
            if content.hasSuffix(".") || content.hasSuffix("!") || content.hasSuffix("?") {
                withPunctuation += 1
            }
        }

        return Double(withPunctuation) / Double(messages.count) > 0.4
    }

    // MARK: - Writing Patterns

    private func analyzeCapitalization(_ messages: [Message]) -> String {
        var lowercaseCount = 0
        var uppercaseCount = 0
        var normalCount = 0

        for message in messages {
            let content = message.content
            let firstChar = content.first

            if let char = firstChar {
                if char.isLowercase {
                    lowercaseCount += 1
                } else if char.isUppercase {
                    // Check if whole message is uppercase
                    if content.uppercased() == content && content.count > 3 {
                        uppercaseCount += 1
                    } else {
                        normalCount += 1
                    }
                }
            }
        }

        let total = lowercaseCount + uppercaseCount + normalCount
        if total == 0 { return "normal" }

        if Double(lowercaseCount) / Double(total) > 0.6 {
            return "lowercase"
        } else if Double(uppercaseCount) / Double(total) > 0.2 {
            return "uppercase"
        }
        return "normal"
    }

    private func detectLetterRepetition(_ messages: [Message]) -> Bool {
        // Look for repeated letters (3+ of the same letter)
        let pattern = #"(.)\1{2,}"#

        var count = 0
        for message in messages {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(message.content.startIndex..., in: message.content)
                if regex.firstMatch(in: message.content, options: [], range: range) != nil {
                    count += 1
                }
            }
        }

        return Double(count) / Double(messages.count) > 0.1
    }

    private func detectMultiplePunctuation(_ messages: [Message]) -> Bool {
        let patterns = ["\\?{2,}", "!{2,}", "\\.{3,}"]

        var count = 0
        for message in messages {
            for pattern in patterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                    let range = NSRange(message.content.startIndex..., in: message.content)
                    if regex.firstMatch(in: message.content, options: [], range: range) != nil {
                        count += 1
                        break
                    }
                }
            }
        }

        return Double(count) / Double(messages.count) > 0.1
    }

    // MARK: - Vocabulary Extraction

    private func extractFillerWords(_ messages: [Message]) -> [String] {
        let fillers = ["tipo", "né", "sabe", "assim", "então", "entao", "aí", "ai",
                      "enfim", "bom", "bem", "olha", "veja", "meio", "tal"]

        return extractUsedWords(from: messages, candidates: fillers)
    }

    private func extractInterjections(_ messages: [Message]) -> [String] {
        let interjections = ["uai", "ué", "ue", "hmm", "hm", "ahh", "ah", "oh", "eita",
                            "nossa", "caramba", "putz", "puts", "ixi", "opa", "ops",
                            "ufa", "uhu", "eba", "afe", "aff"]

        return extractUsedWords(from: messages, candidates: interjections)
    }

    private func extractAffirmations(_ messages: [Message]) -> [String] {
        let affirmations = ["sim", "ss", "sss", "siiim", "aham", "uhum", "isso",
                           "exato", "certo", "ok", "blz", "beleza", "pode", "bora",
                           "vamo", "vamos", "dale", "fechou", "sip", "yep", "yes"]

        return extractUsedWords(from: messages, candidates: affirmations)
    }

    private func extractNegations(_ messages: [Message]) -> [String] {
        let negations = ["não", "nao", "n", "nn", "nope", "nop", "nunca", "jamais",
                        "nem", "nada", "nenhum", "ninguem", "de jeito nenhum"]

        return extractUsedWords(from: messages, candidates: negations)
    }

    private func extractUsedWords(from messages: [Message], candidates: [String]) -> [String] {
        var found: [String: Int] = [:]

        for message in messages {
            let lower = message.content.lowercased()
            let words = Set(lower.components(separatedBy: .whitespaces))

            for candidate in candidates {
                if words.contains(candidate) || lower.contains(" \(candidate) ") ||
                   lower.hasPrefix("\(candidate) ") || lower.hasSuffix(" \(candidate)") ||
                   lower == candidate {
                    found[candidate, default: 0] += 1
                }
            }
        }

        return found.sorted { $0.value > $1.value }.map { $0.key }
    }

    private func extractTopWords(_ messages: [Message]) -> [String] {
        var wordCounts: [String: Int] = [:]

        // Common stop words to exclude
        let stopWords: Set<String> = ["a", "o", "e", "de", "da", "do", "que", "em", "um", "uma",
                                      "para", "com", "no", "na", "os", "as", "por", "se", "mais",
                                      "foi", "são", "está", "esse", "essa", "isso", "ele", "ela",
                                      "eu", "me", "meu", "minha", "você", "vc", "te", "tu", "the",
                                      "is", "to", "i", "it", "and", "of"]

        for message in messages {
            let words = message.content.lowercased()
                .components(separatedBy: .whitespaces)
                .filter { $0.count > 2 && !stopWords.contains($0) }

            for word in words {
                // Clean punctuation
                let cleaned = word.trimmingCharacters(in: .punctuationCharacters)
                if !cleaned.isEmpty && cleaned.count > 2 {
                    wordCounts[cleaned, default: 0] += 1
                }
            }
        }

        return wordCounts
            .filter { $0.value >= 3 }
            .sorted { $0.value > $1.value }
            .prefix(20)
            .map { $0.key }
    }

    // MARK: - Phrase Extraction

    private func extractCommonPhrases(_ messages: [Message]) -> [String] {
        var phraseCounts: [String: Int] = [:]

        for message in messages {
            let words = message.content.lowercased()
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }

            guard words.count >= 2 else { continue }

            // Extract bigrams and trigrams
            for n in 2...min(4, words.count) {
                for i in 0...(words.count - n) {
                    let phrase = words[i..<(i+n)].joined(separator: " ")
                    if phrase.count > 4 && phrase.count < 40 {
                        phraseCounts[phrase, default: 0] += 1
                    }
                }
            }
        }

        return phraseCounts
            .filter { $0.value >= 3 }
            .sorted { $0.value > $1.value }
            .prefix(15)
            .map { $0.key }
    }

    private func extractSentenceStarters(_ messages: [Message]) -> [String] {
        var starters: [String: Int] = [:]

        for message in messages {
            let words = message.content.lowercased()
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }

            if let firstWord = words.first, firstWord.count > 1 {
                starters[firstWord, default: 0] += 1
            }

            // Also look at first two words
            if words.count >= 2 {
                let twoWords = "\(words[0]) \(words[1])"
                starters[twoWords, default: 0] += 1
            }
        }

        return starters
            .filter { $0.value >= 3 }
            .sorted { $0.value > $1.value }
            .prefix(10)
            .map { $0.key }
    }

    private func extractSentenceEndings(_ messages: [Message]) -> [String] {
        var endings: [String: Int] = [:]

        for message in messages {
            let content = message.content.lowercased()
            let words = content.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

            if let lastWord = words.last, lastWord.count > 1 {
                let cleaned = lastWord.trimmingCharacters(in: .punctuationCharacters)
                if !cleaned.isEmpty {
                    endings[cleaned, default: 0] += 1
                }
            }
        }

        return endings
            .filter { $0.value >= 3 }
            .sorted { $0.value > $1.value }
            .prefix(10)
            .map { $0.key }
    }

    // MARK: - Greetings & Closings

    private func extractGreetings(_ messages: [Message]) -> [String] {
        let greetingPatterns = ["oi", "olá", "ola", "eai", "e ai", "e aí", "fala", "opa", "salve",
                               "bom dia", "boa tarde", "boa noite", "hey", "hi", "hello", "yo"]

        var found: Set<String> = []

        for message in messages {
            let lower = message.content.lowercased()
            let firstWord = lower.components(separatedBy: .whitespaces).first ?? ""

            for greeting in greetingPatterns {
                if firstWord == greeting || lower.hasPrefix(greeting + " ") ||
                   lower.hasPrefix(greeting + ",") || lower.hasPrefix(greeting + "!") {
                    found.insert(greeting)
                }
            }
        }

        return Array(found)
    }

    private func extractClosings(_ messages: [Message]) -> [String] {
        let closingPatterns = ["vlw", "valeu", "flw", "falou", "tmj", "abraço", "abs", "bjs",
                              "beijo", "até", "ate", "tchau", "bye", "xau", "fui"]

        var found: Set<String> = []

        for message in messages {
            let lower = message.content.lowercased()
            let words = lower.components(separatedBy: .whitespaces)
            let lastWord = words.last ?? ""

            for closing in closingPatterns {
                if lastWord == closing || lower.hasSuffix(" " + closing) ||
                   lower.hasSuffix(closing + "!") {
                    found.insert(closing)
                }
            }
        }

        return Array(found)
    }

    // MARK: - Response Pattern Extraction

    private func extractQuestionResponses(_ messages: [Message]) -> [String] {
        var responses: [String] = []

        for i in 0..<(messages.count - 1) {
            let current = messages[i]
            let next = messages[i + 1]

            // If contact asks a question and user responds
            if current.sender == .contact && next.sender == .user {
                if current.content.contains("?") {
                    responses.append(next.content)
                }
            }
        }

        // Return diverse samples
        return Array(Set(responses)).shuffled().prefix(10).map { $0 }
    }

    private func extractGreetingResponses(_ messages: [Message]) -> [String] {
        let greetings = ["oi", "olá", "ola", "eai", "e ai", "fala", "opa", "bom dia", "boa tarde", "boa noite"]
        var responses: [String] = []

        for i in 0..<(messages.count - 1) {
            let current = messages[i]
            let next = messages[i + 1]

            if current.sender == .contact && next.sender == .user {
                let lower = current.content.lowercased()
                for greeting in greetings {
                    if lower.hasPrefix(greeting) {
                        responses.append(next.content)
                        break
                    }
                }
            }
        }

        return Array(Set(responses)).shuffled().prefix(5).map { $0 }
    }

    // MARK: - Anti-patterns

    private func detectNeverUses(_ messages: [Message]) -> [String] {
        // Words that are common but this user specifically avoids
        let commonWords = ["legal", "top", "dahora", "show", "massa", "irado", "maneiro",
                          "bro", "brother", "sister", "crush", "ranço", "lacrar", "mitar",
                          "biscoitar", "textão", "exposed", "cancelar", "shippar"]

        var neverUsed: [String] = []

        for word in commonWords {
            var found = false
            for message in messages {
                if message.content.lowercased().contains(word) {
                    found = true
                    break
                }
            }
            if !found {
                neverUsed.append(word)
            }
        }

        return neverUsed
    }

    // MARK: - Sample Selection

    private func selectSampleResponses(_ messages: [Message], count: Int) -> [String] {
        guard !messages.isEmpty else { return [] }
        guard messages.count >= 3 else {
            return messages.map { $0.content }
        }

        let sorted = messages.sorted { $0.content.count < $1.content.count }

        var samples: [String] = []

        // Get varied samples: short, medium, and long
        let third = max(1, sorted.count / 3)
        let buckets = [
            Array(sorted.prefix(third)),
            Array(sorted.dropFirst(third).prefix(third)),
            Array(sorted.suffix(third))
        ]

        for bucket in buckets {
            let bucketSamples = bucket
                .shuffled()
                .prefix(count / 3 + 1)
                .map { $0.content }
            samples.append(contentsOf: bucketSamples)
        }

        // Remove duplicates and limit
        return Array(Set(samples)).prefix(count).map { $0 }
    }
}
