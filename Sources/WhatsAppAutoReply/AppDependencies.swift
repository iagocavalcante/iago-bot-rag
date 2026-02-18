import Foundation

@MainActor
final class AppDependencies {
    let settings: SettingsManager
    let ragManager: RAGManager
    let appViewModel: AppViewModel

    init() {
        let settings = SettingsManager.shared
        let dbManager = DatabaseManager.shared
        let ragManager = RAGManager.shared
        let accessibilityMonitor = WhatsAppMonitor()
        let databaseMonitor = WhatsAppDatabaseMonitor()
        let ollamaClient = OllamaClient()

        let groupContextAnalyzer = GroupContextAnalyzer(
            ragManager: ragManager,
            settings: settings
        )
        let responseDecider = ResponseDecider(
            settings: settings,
            groupContextAnalyzer: groupContextAnalyzer
        )
        let dailyContextTracker = DailyContextTracker(dbManager: dbManager)
        let responseGenerator = ResponseGenerator(
            ollamaClient: ollamaClient,
            dbManager: dbManager,
            settings: settings,
            styleAnalyzer: StyleAnalyzer(),
            responseDecider: responseDecider,
            ragManager: ragManager,
            dailyContextTracker: dailyContextTracker
        )
        let chatImportUseCase = ChatImportUseCase(
            dbManager: dbManager,
            ragManager: ragManager,
            settings: settings,
            parserFactory: { ChatParser(userName: settings.userName) }
        )
        let monitoringCoordinator = MonitoringCoordinator(
            accessibilityMonitor: accessibilityMonitor,
            databaseMonitor: databaseMonitor,
            settings: settings
        )

        self.settings = settings
        self.ragManager = ragManager
        self.appViewModel = AppViewModel(
            dbManager: dbManager,
            accessibilityMonitor: accessibilityMonitor,
            databaseMonitor: databaseMonitor,
            responseGenerator: responseGenerator,
            ollamaClient: ollamaClient,
            groupNameSecurity: .shared,
            settings: settings,
            audioTranscriptionService: AudioTranscriptionService.shared,
            imageAnalysisService: ImageAnalysisService.shared,
            ragManager: ragManager,
            chatImportUseCase: chatImportUseCase,
            monitoringCoordinator: monitoringCoordinator
        )
    }
}
