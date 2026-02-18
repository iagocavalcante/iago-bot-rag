import XCTest
@testable import WhatsAppAutoReply

@MainActor
final class MonitoringCoordinatorTests: XCTestCase {
    func testUpdateMonitoringStateStartsAndStops() {
        let accessibility = MockAccessibilityMonitor()
        let database = MockDatabaseMonitor()
        let settings = MockMonitoringSettings()
        settings.monitoringMethod = .accessibility

        let coordinator = MonitoringCoordinator(
            accessibilityMonitor: accessibility,
            databaseMonitor: database,
            settings: settings
        )

        let started = coordinator.updateMonitoringState(hasActiveContacts: true)
        switch started {
        case .started(let method):
            XCTAssertEqual(method, .accessibility)
        default:
            XCTFail("Expected started state")
        }
        XCTAssertEqual(accessibility.startCalls, 1)

        let stopped = coordinator.updateMonitoringState(hasActiveContacts: false)
        switch stopped {
        case .stopped:
            XCTAssertTrue(true)
        default:
            XCTFail("Expected stopped state")
        }
        XCTAssertEqual(accessibility.stopCalls, 1)
    }

    func testUpdateMonitoringStateSwitchesMethod() {
        let accessibility = MockAccessibilityMonitor()
        let database = MockDatabaseMonitor()
        let settings = MockMonitoringSettings()
        settings.monitoringMethod = .accessibility

        let coordinator = MonitoringCoordinator(
            accessibilityMonitor: accessibility,
            databaseMonitor: database,
            settings: settings
        )

        _ = coordinator.updateMonitoringState(hasActiveContacts: true)
        settings.monitoringMethod = .database
        _ = coordinator.updateMonitoringState(hasActiveContacts: true)

        XCTAssertEqual(accessibility.stopCalls, 1)
        XCTAssertEqual(database.startCalls, 1)
    }

    func testMessageEligibility() {
        let coordinator = MonitoringCoordinator(
            accessibilityMonitor: MockAccessibilityMonitor(),
            databaseMonitor: MockDatabaseMonitor(),
            settings: MockMonitoringSettings()
        )

        let grace = coordinator.messageEligibility(timestamp: Date(), maxAge: 1200, gracePeriod: 5)
        if case .inGracePeriod = grace {} else { XCTFail("Expected grace period") }

        _ = coordinator.updateMonitoringState(hasActiveContacts: true)
        let oldDate = Date().addingTimeInterval(-2_000)
        let old = coordinator.messageEligibility(timestamp: oldDate, maxAge: 1200, gracePeriod: 0)
        if case .tooOld = old {} else { XCTFail("Expected old message") }
    }
}

private final class MockMonitoringSettings: SettingsProviding {
    var monitoringMethod: MonitoringMethod = .accessibility
    var ignoreGroupNameTricks: Bool = true
    var useReplyMode: Bool = false
    var isOpenAIConfigured: Bool = false
    var useRAG: Bool = false
}

private final class MockAccessibilityMonitor: AccessibilityMonitoring {
    var isMonitoring = false
    var debugInfo: String = ""
    var onNewMessage: ((DetectedMessage) -> Void)?
    var onDebugLog: ((String) -> Void)?
    var hasAccessibilityPermission: Bool = true
    var whatsAppRunning: Bool = true

    private(set) var startCalls = 0
    private(set) var stopCalls = 0

    func startMonitoring() {
        isMonitoring = true
        startCalls += 1
    }

    func stopMonitoring() {
        isMonitoring = false
        stopCalls += 1
    }

    func checkPermissions() {}
    func isAudioMessage(_ text: String) -> Bool { false }
    func isStickerMessage(_ text: String) -> Bool { false }
    func isImageMessage(_ text: String) -> Bool { false }
    func sendMessage(_ text: String, to contactName: String?) {}
    func sendReplyMessage(_ text: String, to contactName: String?) {}
    func dumpAccessibilityTree() -> String { "" }
}

private final class MockDatabaseMonitor: DatabaseMonitoring {
    var isMonitoring = false
    var debugInfo: String = ""
    var onNewMessage: ((DetectedMessage) -> Void)?
    var onDebugLog: ((String) -> Void)?

    private(set) var startCalls = 0
    private(set) var stopCalls = 0

    func startMonitoring() {
        isMonitoring = true
        startCalls += 1
    }

    func stopMonitoring() {
        isMonitoring = false
        stopCalls += 1
    }

    func isDatabaseAccessible() -> Bool { true }
    func getChatJID(forName name: String, isGroup: Bool) -> String? { nil }
}
