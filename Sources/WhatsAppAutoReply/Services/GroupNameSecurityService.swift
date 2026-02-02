import Foundation

/// Tracks group name changes and detects prompt injection attempts via group renaming
/// This prevents social engineering attacks where attackers rename groups to inject prompts
class GroupNameSecurityService {
    static let shared = GroupNameSecurityService()

    // MARK: - Types

    /// Represents the security assessment of a group name
    struct NameSecurityAssessment {
        let isSuspicious: Bool
        let threatLevel: ThreatLevel
        let matchedPatterns: [String]
        let recommendation: Recommendation

        enum ThreatLevel: Int, Comparable {
            case safe = 0
            case low = 1
            case medium = 2
            case high = 3
            case critical = 4

            static func < (lhs: ThreatLevel, rhs: ThreatLevel) -> Bool {
                lhs.rawValue < rhs.rawValue
            }
        }

        enum Recommendation {
            case allowNormally
            case respondWithCaution
            case respondWithHumor       // Acknowledge the trick attempt
            case blockTemporarily       // Skip responding for a while
            case blockPermanently       // Require manual re-enable
        }
    }

    /// Tracked group name history
    struct GroupNameHistory: Codable {
        let chatJID: String
        var originalName: String
        var currentName: String
        var nameHistory: [NameChange]
        var suspiciousRenameCount: Int
        var lastSuspiciousRename: Date?
        var isBlocked: Bool

        struct NameChange: Codable {
            let fromName: String
            let toName: String
            let timestamp: Date
            let wasSuspicious: Bool
        }
    }

    // MARK: - Properties

    private var groupHistories: [String: GroupNameHistory] = [:]  // keyed by chatJID
    private let storageURL: URL
    private let maxSuspiciousRenames = 3  // Block after this many suspicious renames

    // MARK: - Prompt Injection Patterns

    /// Patterns that indicate prompt injection attempts
    private let injectionPatterns: [String: NameSecurityAssessment.ThreatLevel] = [
        // Critical - direct prompt manipulation attempts
        "system prompt": .critical,
        "ignore previous": .critical,
        "ignore all instructions": .critical,
        "disregard your": .critical,
        "override your": .critical,
        "new instructions": .critical,
        "you are now": .critical,
        "from now on": .critical,
        "forget everything": .critical,
        "reset your": .critical,

        // High - credential/data exfiltration attempts
        "show your": .high,
        "reveal your": .high,
        "tell me your": .high,
        "give me your": .high,
        "your password": .high,
        "your api key": .high,
        "your token": .high,
        "your credentials": .high,
        "your secrets": .high,
        "environment variable": .high,
        "sua senha": .high,
        "seu pix": .high,
        "seu cpf": .high,
        "suas variáveis": .high,
        "suas variaveis": .high,
        "seu segredo": .high,
        "seus segredos": .high,
        "seu cartão": .high,
        "seu cartao": .high,
        "me passa": .high,
        "me manda": .high,

        // Medium - role manipulation attempts
        "act as": .medium,
        "pretend to be": .medium,
        "finja que": .medium,
        "aja como": .medium,
        "fale como": .medium,
        "responda como": .medium,
        "você é": .medium,
        "voce e": .medium,
        "ignore your rules": .medium,
        "ignore as regras": .medium,
        "esquece as regras": .medium,
        "sem regras": .medium,

        // Low - suspicious but could be innocent
        "respond only": .low,
        "output only": .low,
        "just say": .low,
        "only reply": .low,
        "mostre": .low,
        "mostra": .low,
        "revele": .low,
        "revela": .low,
        "me conta": .low,
        "me fala": .low,
    ]

    /// Additional structural patterns that are suspicious
    private let structuralPatterns: [(pattern: String, threatLevel: NameSecurityAssessment.ThreatLevel)] = [
        ("```", .high),           // Code blocks
        ("\\n", .medium),         // Newline attempts
        ("---", .medium),         // Separators
        ("###", .medium),         // Headers
        ("[INST]", .critical),    // Llama instruction format
        ("<<SYS>>", .critical),   // Llama system format
        ("<|", .critical),        // Various model tokens
        ("|>", .critical),
        ("Human:", .critical),
        ("Assistant:", .critical),
        ("System:", .critical),
    ]

    // MARK: - Initialization

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("WhatsAppAutoReply")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        storageURL = appDir.appendingPathComponent("group_name_security.json")

        loadHistories()
    }

    // MARK: - Public API

    /// Assess a group name for security threats
    func assessGroupName(_ name: String) -> NameSecurityAssessment {
        let lowerName = name.lowercased()
        var matchedPatterns: [String] = []
        var highestThreat: NameSecurityAssessment.ThreatLevel = .safe

        // Check injection patterns
        for (pattern, threatLevel) in injectionPatterns {
            if lowerName.contains(pattern) {
                matchedPatterns.append(pattern)
                if threatLevel > highestThreat {
                    highestThreat = threatLevel
                }
            }
        }

        // Check structural patterns
        for (pattern, threatLevel) in structuralPatterns {
            if name.contains(pattern) {
                matchedPatterns.append(pattern)
                if threatLevel > highestThreat {
                    highestThreat = threatLevel
                }
            }
        }

        // Check for excessive length (could be hiding injection in long name)
        if name.count > 100 {
            matchedPatterns.append("excessive_length")
            if highestThreat < .low {
                highestThreat = .low
            }
        }

        // Check for unicode tricks (zero-width chars, RTL override, etc.)
        if containsUnicodeTricks(name) {
            matchedPatterns.append("unicode_manipulation")
            if highestThreat < .medium {
                highestThreat = .medium
            }
        }

        let recommendation: NameSecurityAssessment.Recommendation
        switch highestThreat {
        case .safe:
            recommendation = .allowNormally
        case .low:
            recommendation = .respondWithCaution
        case .medium:
            recommendation = .respondWithHumor
        case .high, .critical:
            recommendation = .blockTemporarily
        }

        return NameSecurityAssessment(
            isSuspicious: highestThreat != .safe,
            threatLevel: highestThreat,
            matchedPatterns: matchedPatterns,
            recommendation: recommendation
        )
    }

    /// Track a group and detect name changes
    /// - Returns: SecurityAction to take based on current state
    func trackGroup(chatJID: String, currentName: String) -> SecurityAction {
        let assessment = assessGroupName(currentName)

        if var history = groupHistories[chatJID] {
            // Existing group - check for name change
            if history.currentName != currentName {
                // Name changed!
                let change = GroupNameHistory.NameChange(
                    fromName: history.currentName,
                    toName: currentName,
                    timestamp: Date(),
                    wasSuspicious: assessment.isSuspicious
                )
                history.nameHistory.append(change)
                history.currentName = currentName

                if assessment.isSuspicious {
                    history.suspiciousRenameCount += 1
                    history.lastSuspiciousRename = Date()
                    print("[GroupSecurity] Suspicious rename detected: '\(history.currentName)' -> '\(currentName)'")
                    print("[GroupSecurity] Matched patterns: \(assessment.matchedPatterns)")
                    print("[GroupSecurity] Suspicious rename count: \(history.suspiciousRenameCount)")

                    // Check if should block
                    if history.suspiciousRenameCount >= maxSuspiciousRenames {
                        history.isBlocked = true
                        groupHistories[chatJID] = history
                        saveHistories()
                        return .blockGroup(reason: "Too many suspicious renames (\(history.suspiciousRenameCount))")
                    }
                }

                groupHistories[chatJID] = history
                saveHistories()

                if assessment.isSuspicious {
                    return .respondWithHumor(
                        originalName: history.originalName,
                        suspiciousName: currentName,
                        renameCount: history.suspiciousRenameCount
                    )
                }
            }

            // Check if group is blocked
            if history.isBlocked {
                return .blockGroup(reason: "Group blocked due to repeated suspicious renames")
            }

            // Check cooldown after suspicious rename
            if let lastSuspicious = history.lastSuspiciousRename,
               Date().timeIntervalSince(lastSuspicious) < 3600 { // 1 hour cooldown
                return .cooldown(remainingSeconds: 3600 - Date().timeIntervalSince(lastSuspicious))
            }

        } else {
            // New group - create history
            let history = GroupNameHistory(
                chatJID: chatJID,
                originalName: currentName,
                currentName: currentName,
                nameHistory: [],
                suspiciousRenameCount: assessment.isSuspicious ? 1 : 0,
                lastSuspiciousRename: assessment.isSuspicious ? Date() : nil,
                isBlocked: false
            )
            groupHistories[chatJID] = history
            saveHistories()

            if assessment.isSuspicious {
                print("[GroupSecurity] New group with suspicious name: '\(currentName)'")
                return .respondWithHumor(
                    originalName: currentName,
                    suspiciousName: currentName,
                    renameCount: 1
                )
            }
        }

        // Safe to proceed
        if assessment.isSuspicious {
            return .respondWithCaution(warning: "Name contains potentially suspicious patterns")
        }
        return .allowNormally
    }

    /// Get the original (first seen) name for a group
    func getOriginalName(chatJID: String) -> String? {
        return groupHistories[chatJID]?.originalName
    }

    /// Check if a group is currently blocked
    func isGroupBlocked(chatJID: String) -> Bool {
        return groupHistories[chatJID]?.isBlocked ?? false
    }

    /// Manually unblock a group (for admin override)
    func unblockGroup(chatJID: String) {
        guard var history = groupHistories[chatJID] else { return }
        history.isBlocked = false
        history.suspiciousRenameCount = 0
        history.lastSuspiciousRename = nil
        groupHistories[chatJID] = history
        saveHistories()
        print("[GroupSecurity] Group unblocked: \(chatJID)")
    }

    /// Get security statistics for a group
    func getGroupStats(chatJID: String) -> (renameCount: Int, suspiciousCount: Int, isBlocked: Bool)? {
        guard let history = groupHistories[chatJID] else { return nil }
        return (
            renameCount: history.nameHistory.count,
            suspiciousCount: history.suspiciousRenameCount,
            isBlocked: history.isBlocked
        )
    }

    // MARK: - Security Actions

    enum SecurityAction {
        case allowNormally
        case respondWithCaution(warning: String)
        case respondWithHumor(originalName: String, suspiciousName: String, renameCount: Int)
        case cooldown(remainingSeconds: TimeInterval)
        case blockGroup(reason: String)

        /// Get a funny response for suspicious rename attempts
        func getFunnyResponse() -> String? {
            switch self {
            case .respondWithHumor(let originalName, let suspiciousName, let renameCount):
                let responses: [String]
                if renameCount == 1 {
                    responses = [
                        "Opa, notei que o grupo mudou de nome pra algo... criativo 😏 Mas relaxa, meu anti-hack tá ligado!",
                        "Hmm, esse nome de grupo novo tá com cara de tentativa de me hackear... Nice try! 🔐😂",
                        "Renomearam o grupo pra '\(suspiciousName.prefix(30))...'? Vocês são engraçados! 🕵️",
                        "Alerta de criatividade! Alguém tá tentando social engineering via nome de grupo 🚨😄",
                    ]
                } else {
                    responses = [
                        "Tá, essa é a \(renameCount)ª vez que mudam o nome do grupo pra algo suspeito... Desiste galera! 😂🛡️",
                        "Persistentes, hein? \(renameCount) tentativas de hackear pelo nome do grupo! Vocês ganham um troféu 🏆",
                        "Update: ainda não caí na armadilha do nome do grupo (tentativa #\(renameCount)) 😎",
                        "Grupo originalmente '\(originalName.prefix(20))...', agora com nome hacker. \(renameCount)x fail! 🤷‍♂️",
                    ]
                }
                return responses.randomElement()

            case .cooldown(let remaining):
                let minutes = Int(remaining / 60)
                return "Calma aí! Depois daquela tentativa de hack pelo nome do grupo, preciso de \(minutes) min de paz 😅"

            case .blockGroup:
                return "Esse grupo foi bloqueado temporariamente por excesso de criatividade hacker 🚫😂"

            default:
                return nil
            }
        }
    }

    // MARK: - Private Helpers

    private func containsUnicodeTricks(_ name: String) -> Bool {
        // Check for zero-width characters, RTL override, and other unicode tricks
        let suspiciousCodePoints: [Unicode.Scalar] = [
            "\u{200B}",  // Zero-width space
            "\u{200C}",  // Zero-width non-joiner
            "\u{200D}",  // Zero-width joiner
            "\u{FEFF}",  // BOM
            "\u{202A}",  // Left-to-right embedding
            "\u{202B}",  // Right-to-left embedding
            "\u{202C}",  // Pop directional formatting
            "\u{202D}",  // Left-to-right override
            "\u{202E}",  // Right-to-left override
            "\u{2066}",  // Left-to-right isolate
            "\u{2067}",  // Right-to-left isolate
            "\u{2068}",  // First strong isolate
            "\u{2069}",  // Pop directional isolate
        ]

        for scalar in name.unicodeScalars {
            if suspiciousCodePoints.contains(scalar) {
                return true
            }
        }
        return false
    }

    private func loadHistories() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }

        do {
            let data = try Data(contentsOf: storageURL)
            let histories = try JSONDecoder().decode([String: GroupNameHistory].self, from: data)
            groupHistories = histories
            print("[GroupSecurity] Loaded \(histories.count) group histories")
        } catch {
            print("[GroupSecurity] Failed to load histories: \(error)")
        }
    }

    private func saveHistories() {
        do {
            let data = try JSONEncoder().encode(groupHistories)
            try data.write(to: storageURL)
        } catch {
            print("[GroupSecurity] Failed to save histories: \(error)")
        }
    }
}

// MARK: - Database Integration

extension GroupNameSecurityService {
    /// Sync group names from WhatsApp database
    /// Call this periodically to detect name changes
    func syncFromDatabase(monitor: WhatsAppDatabaseMonitor) {
        guard monitor.isDatabaseAccessible() else { return }

        // Query all groups from database and track their names
        // This allows detecting changes even when not actively monitoring messages
        // Implementation would query ZWACHATSESSION where ZSESSIONTYPE = 1
    }
}
