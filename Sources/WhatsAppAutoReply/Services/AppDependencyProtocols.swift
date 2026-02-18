import Foundation

// MARK: - Settings

protocol SettingsProviding: AnyObject {
    var monitoringMethod: MonitoringMethod { get }
    var ignoreGroupNameTricks: Bool { get }
    var useReplyMode: Bool { get }
    var isOpenAIConfigured: Bool { get }
    var useRAG: Bool { get }
}

extension SettingsManager: SettingsProviding {}

protocol ResponseGeneratorSettingsProviding: SettingsProviding {
    var aiProvider: AIProvider { get }
    var openAIKey: String { get }
    var openAIModel: String { get }
    var maritacaKey: String { get }
    var maritacaModel: String { get }
    var userName: String { get }
    var smartResponse: Bool { get }
    var groupTopicParticipation: Bool { get }
    var isMaritacaConfigured: Bool { get }
}

extension SettingsManager: ResponseGeneratorSettingsProviding {}

protocol ResponseDeciderSettingsProviding {
    var userName: String { get }
}

extension SettingsManager: ResponseDeciderSettingsProviding {}

// MARK: - Data

protocol DatabaseManaging {
    func getAllContacts() throws -> [Contact]
    func updateContactAutoReply(id: Int64, enabled: Bool) throws
    func getContactByName(_ name: String) throws -> Contact?
    func updateContactIsGroup(id: Int64, isGroup: Bool) throws
    func insertContact(_ contact: Contact) throws -> Int64
    func insertMessages(_ messageList: [Message], batchSize: Int, progress: ((Int, Int) -> Void)?) throws
    func getMessagesForContact(contactId: Int64, limit: Int) throws -> [Message]
}

extension DatabaseManager: DatabaseManaging {}

protocol ChatParsing {
    func parseTempZipFileWithLog(at tempZip: URL) -> ([ParsedMessage], [String])
    func isGroupChat(messages: [ParsedMessage]) -> Bool
    func getUniqueSenders(messages: [ParsedMessage]) -> [String]
    func convertToMessages(parsed: [ParsedMessage], contactId: Int64, contactName: String) -> [Message]
}

extension ChatParser: ChatParsing {}

// MARK: - Monitoring

protocol MessageMonitoring: AnyObject {
    var isMonitoring: Bool { get }
    var debugInfo: String { get }
    var onNewMessage: ((DetectedMessage) -> Void)? { get set }
    var onDebugLog: ((String) -> Void)? { get set }
    func startMonitoring()
    func stopMonitoring()
}

protocol AccessibilityMonitoring: MessageMonitoring {
    var hasAccessibilityPermission: Bool { get }
    var whatsAppRunning: Bool { get }
    func checkPermissions()
    func isAudioMessage(_ text: String) -> Bool
    func isStickerMessage(_ text: String) -> Bool
    func isImageMessage(_ text: String) -> Bool
    func sendMessage(_ text: String, to contactName: String?)
    func sendReplyMessage(_ text: String, to contactName: String?)
    func dumpAccessibilityTree() -> String
}

protocol DatabaseMonitoring: MessageMonitoring {
    func isDatabaseAccessible() -> Bool
    func getChatJID(forName name: String, isGroup: Bool) -> String?
}

extension WhatsAppMonitor: AccessibilityMonitoring {}
extension WhatsAppDatabaseMonitor: DatabaseMonitoring {}

@MainActor
protocol MonitoringCoordinating: AnyObject {
    var hasAccessibilityPermission: Bool { get }
    var isWhatsAppRunning: Bool { get }
    var isDatabaseAccessible: Bool { get }
    var isMonitoring: Bool { get }
    var debugInfo: String { get }

    func setup(
        onDetectedMessage: @escaping @Sendable (DetectedMessage) -> Void,
        onDebugLog: @escaping @Sendable (String) -> Void,
        onPeriodicCheck: @escaping @Sendable () -> Void
    )
    func updateMonitoringState(hasActiveContacts: Bool) -> MonitoringStateChange
    func messageEligibility(
        timestamp: Date,
        maxAge: TimeInterval,
        gracePeriod: TimeInterval
    ) -> MonitoringMessageEligibility
}

// MARK: - Core Services

protocol ResponseGenerating {
    func generateResponse(for contactName: String, message: String) async throws -> String?
}

extension ResponseGenerator: ResponseGenerating {}

protocol ResponseDeciding {
    func shouldParticipateInGroup(
        groupName: String,
        message: String,
        sender: String,
        contactId: Int64,
        recentMessages: [Message]
    ) async -> GroupParticipationDecision
    func shouldRespond(
        to message: String,
        from contactName: String,
        contact: Contact,
        recentMessages: [Message]
    ) -> ResponseDecision
}

extension ResponseDecider: ResponseDeciding {}

protocol GroupContextAnalyzing {
    func addMessage(groupName: String, sender: String, content: String, timestamp: Date)
    func shouldParticipate(
        in groupName: String,
        contactId: Int64,
        currentMessage: String
    ) async -> (participate: Bool, reason: String, score: Float)
    func isAnswerableQuestion(_ message: String) -> Bool
    func matchesResponsePattern(message: String, userMessages: [Message]) -> Bool
}

extension GroupContextAnalyzer: GroupContextAnalyzing {}

extension GroupContextAnalyzing {
    func addMessage(groupName: String, sender: String, content: String) {
        addMessage(groupName: groupName, sender: sender, content: content, timestamp: Date())
    }
}

protocol StyleAnalyzing {
    func analyzeMessages(_ messages: [Message]) -> StyleProfile
}

extension StyleAnalyzer: StyleAnalyzing {}

protocol DailyContextTracking {
    func trackMessage(contactId: Int64, content: String, isFromUser: Bool, timestamp: Date)
    func getContextSummary(for contactId: Int64) -> String?
}

extension DailyContextTracker: DailyContextTracking {}

protocol RAGContextSearching {
    func findSimilarContext(
        for message: String,
        contactId: Int64,
        limit: Int
    ) async throws -> [(contactMessage: String, userResponse: String, similarity: Float)]
    func findSimilarThreads(
        for message: String,
        contactId: Int64,
        limit: Int
    ) async throws -> [ConversationThread]
}

extension RAGManager: RAGContextSearching {}

protocol OllamaAvailabilityChecking {
    func isAvailable() async -> Bool
}

extension OllamaClient: OllamaAvailabilityChecking {}

protocol OllamaGenerating {
    func generateResponse(prompt: String) async throws -> String
}

extension OllamaClient: OllamaGenerating {}

protocol OpenAIChatGenerating {
    func generateResponse(prompt: String, systemPrompt: String?) async throws -> String
}

extension OpenAIClient: OpenAIChatGenerating {}

protocol MaritacaChatGenerating {
    func generateResponse(prompt: String, systemPrompt: String?) async throws -> String
}

extension MaritacaClient: MaritacaChatGenerating {}

protocol AudioTranscriptionServicing {
    func transcribeRecentAudio() async throws -> String?
}

extension AudioTranscriptionService: AudioTranscriptionServicing {}

protocol ImageAnalysisServicing {
    func analyzeRecentImage() async throws -> String?
}

extension ImageAnalysisService: ImageAnalysisServicing {}

protocol RAGEmbeddingGenerating {
    func generateEmbeddings(for contactId: Int64, progress: ((Int, Int) -> Void)?) async throws
}

extension RAGManager: RAGEmbeddingGenerating {}

struct ChatImportResult {
    let contactName: String
    let messageCount: Int
}

protocol ChatImporting {
    func importChatExport(
        url: URL,
        log: @escaping @Sendable (String, Bool) -> Void,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> ChatImportResult
}

protocol RAGStatsProviding {
    var embeddingCount: Int { get }
}

extension RAGManager: RAGStatsProviding {}
