import Foundation

/// Analyzes message history to extract user's writing style
class StyleAnalyzer {

    /// Analyze user's messages to build a style profile
    func analyzeMessages(_ messages: [Message]) -> StyleProfile {
        // Filter only user's messages
        let userMessages = messages.filter { $0.sender == .user }

        guard !userMessages.isEmpty else {
            return StyleProfile()
        }

        var profile = StyleProfile()

        // Analyze response lengths
        let lengths = userMessages.map { $0.content.count }
        profile.avgResponseLength = lengths.reduce(0, +) / lengths.count

        // Analyze emoji usage
        let messagesWithEmoji = userMessages.filter { containsEmoji($0.content) }
        profile.emojiFrequency = Double(messagesWithEmoji.count) / Double(userMessages.count)

        // Detect laugh style
        profile.laughStyle = detectLaughStyle(userMessages)

        // Analyze formality
        profile.formalityLevel = analyzeFormality(userMessages)

        // Detect abbreviation usage
        profile.usesAbbreviations = detectAbbreviations(userMessages)

        // Detect punctuation usage
        profile.usesPunctuation = detectPunctuation(userMessages)

        // Extract common phrases
        profile.commonPhrases = extractCommonPhrases(userMessages)

        // Extract greetings
        profile.greetings = extractGreetings(userMessages)

        // Extract closings
        profile.closings = extractClosings(userMessages)

        // Get sample responses (most recent, varied lengths)
        profile.sampleResponses = selectSampleResponses(userMessages, count: 10)

        return profile
    }

    // MARK: - Analysis Helpers

    private func containsEmoji(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if scalar.properties.isEmoji && scalar.properties.isEmojiPresentation {
                return true
            }
        }
        return false
    }

    private func detectLaughStyle(_ messages: [Message]) -> String? {
        let laughPatterns: [(pattern: String, style: String)] = [
            ("k{3,}", "kkkk"),
            ("ha{2,}", "haha"),
            ("he{2,}", "hehe"),
            ("rs{1,}", "rs"),
            ("ks{2,}", "ksks"),
            ("😂", "😂"),
            ("🤣", "🤣"),
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

        // Return most common laugh style
        return laughCounts.max(by: { $0.value < $1.value })?.key
    }

    private func analyzeFormality(_ messages: [Message]) -> Double {
        var formalScore = 0.0
        var totalChecks = 0

        let formalIndicators = [
            "você", "senhor", "senhora", "por favor", "obrigado", "obrigada",
            "bom dia", "boa tarde", "boa noite", "prezado", "atenciosamente"
        ]

        let casualIndicators = [
            "vc", "tb", "pq", "oq", "blz", "vlw", "flw", "tmj", "mano", "cara",
            "kkkk", "haha", "opa", "eai", "e ai", "fala", "ae", "po", "pô"
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
                    // Don't add to formalScore (casual)
                }
            }
        }

        if totalChecks == 0 { return 0.5 }
        return formalScore / Double(totalChecks)
    }

    private func detectAbbreviations(_ messages: [Message]) -> Bool {
        let abbreviations = ["vc", "tb", "pq", "oq", "q ", "n ", "hj", "td", "mt", "mto", "cmg", "ctg"]

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

        return Double(abbrevCount) / Double(messages.count) > 0.2
    }

    private func detectPunctuation(_ messages: [Message]) -> Bool {
        var withPunctuation = 0

        for message in messages {
            let content = message.content.trimmingCharacters(in: .whitespaces)
            if content.hasSuffix(".") || content.hasSuffix("!") || content.hasSuffix("?") {
                withPunctuation += 1
            }
        }

        return Double(withPunctuation) / Double(messages.count) > 0.5
    }

    private func extractCommonPhrases(_ messages: [Message]) -> [String] {
        var phraseCounts: [String: Int] = [:]

        // Look for repeated 2-4 word phrases
        for message in messages {
            let words = message.content.lowercased()
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }

            // Skip if not enough words for n-grams
            guard words.count >= 2 else { continue }

            // Extract bigrams and trigrams
            for n in 2...min(4, words.count) {
                for i in 0...(words.count - n) {
                    let phrase = words[i..<(i+n)].joined(separator: " ")
                    if phrase.count > 4 && phrase.count < 30 {
                        phraseCounts[phrase, default: 0] += 1
                    }
                }
            }
        }

        // Return phrases that appear multiple times
        return phraseCounts
            .filter { $0.value >= 3 }
            .sorted { $0.value > $1.value }
            .prefix(10)
            .map { $0.key }
    }

    private func extractGreetings(_ messages: [Message]) -> [String] {
        let greetingPatterns = [
            "oi", "olá", "ola", "eai", "e ai", "e aí", "fala", "opa", "salve",
            "bom dia", "boa tarde", "boa noite", "hey", "hi"
        ]

        var found: Set<String> = []

        for message in messages {
            let lower = message.content.lowercased()
            let firstWord = lower.components(separatedBy: .whitespaces).first ?? ""

            for greeting in greetingPatterns {
                if firstWord == greeting || lower.hasPrefix(greeting + " ") || lower.hasPrefix(greeting + ",") {
                    found.insert(greeting)
                }
            }
        }

        return Array(found)
    }

    private func extractClosings(_ messages: [Message]) -> [String] {
        let closingPatterns = [
            "vlw", "valeu", "flw", "falou", "tmj", "abraço", "abs", "bjs", "beijo",
            "até", "ate", "tchau", "bye"
        ]

        var found: Set<String> = []

        for message in messages {
            let lower = message.content.lowercased()
            let lastWord = lower.components(separatedBy: .whitespaces).last ?? ""

            for closing in closingPatterns {
                if lastWord == closing || lower.hasSuffix(" " + closing) {
                    found.insert(closing)
                }
            }
        }

        return Array(found)
    }

    private func selectSampleResponses(_ messages: [Message], count: Int) -> [String] {
        guard !messages.isEmpty else { return [] }

        // Get varied samples: short, medium, and long responses
        let sorted = messages.sorted { $0.content.count < $1.content.count }

        var samples: [String] = []

        // Handle small message counts
        guard sorted.count >= 3 else {
            return sorted.map { $0.content }
        }

        // Get some short, some medium, some long
        let third = max(1, sorted.count / 3)
        let buckets = [
            sorted.prefix(third),
            sorted.dropFirst(third).prefix(third),
            sorted.suffix(third)
        ]

        for bucket in buckets {
            let bucketSamples = bucket
                .shuffled()
                .prefix(count / 3)
                .map { $0.content }
            samples.append(contentsOf: bucketSamples)
        }

        return Array(samples.prefix(count))
    }
}
