import Foundation

enum MonitoringStateChange {
    case none
    case started(method: MonitoringMethod)
    case stopped
}

enum MonitoringMessageEligibility {
    case eligible
    case inGracePeriod
    case tooOld(age: TimeInterval)
}

@MainActor
final class MonitoringCoordinator: MonitoringCoordinating {
    private let accessibilityMonitor: any AccessibilityMonitoring
    private let databaseMonitor: any DatabaseMonitoring
    private let settings: any SettingsProviding

    private var activeMonitoringMethod: MonitoringMethod
    private var monitoringStartTime: Date = Date()
    private var timer: Timer?

    init(
        accessibilityMonitor: any AccessibilityMonitoring,
        databaseMonitor: any DatabaseMonitoring,
        settings: any SettingsProviding
    ) {
        self.accessibilityMonitor = accessibilityMonitor
        self.databaseMonitor = databaseMonitor
        self.settings = settings
        self.activeMonitoringMethod = settings.monitoringMethod
    }

    deinit {
        timer?.invalidate()
    }

    var hasAccessibilityPermission: Bool {
        accessibilityMonitor.hasAccessibilityPermission
    }

    var isWhatsAppRunning: Bool {
        accessibilityMonitor.whatsAppRunning
    }

    var isDatabaseAccessible: Bool {
        databaseMonitor.isDatabaseAccessible()
    }

    var isMonitoring: Bool {
        activeMonitor.isMonitoring
    }

    var debugInfo: String {
        activeMonitor.debugInfo
    }

    func setup(
        onDetectedMessage: @escaping @Sendable (DetectedMessage) -> Void,
        onDebugLog: @escaping @Sendable (String) -> Void,
        onPeriodicCheck: @escaping @Sendable () -> Void
    ) {
        bindCallbacks(for: accessibilityMonitor, logPrefix: "AccMonitor", onDetectedMessage: onDetectedMessage, onDebugLog: onDebugLog)
        bindCallbacks(for: databaseMonitor, logPrefix: "DBMonitor", onDetectedMessage: onDetectedMessage, onDebugLog: onDebugLog)

        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.accessibilityMonitor.checkPermissions()
                onPeriodicCheck()
            }
        }
    }

    func updateMonitoringState(hasActiveContacts: Bool) -> MonitoringStateChange {
        let selectedMethod = settings.monitoringMethod

        if selectedMethod != activeMonitoringMethod {
            activeMonitor.stopMonitoring()
            activeMonitoringMethod = selectedMethod
        }

        if hasActiveContacts && !isMonitoring {
            monitoringStartTime = Date()
            activeMonitor.startMonitoring()
            return .started(method: selectedMethod)
        }

        if !hasActiveContacts && isMonitoring {
            activeMonitor.stopMonitoring()
            return .stopped
        }

        return .none
    }

    func messageEligibility(
        timestamp: Date,
        maxAge: TimeInterval,
        gracePeriod: TimeInterval
    ) -> MonitoringMessageEligibility {
        let timeSinceMonitoringStarted = Date().timeIntervalSince(monitoringStartTime)
        if timeSinceMonitoringStarted < gracePeriod {
            return .inGracePeriod
        }

        let messageAge = Date().timeIntervalSince(timestamp)
        if messageAge > maxAge {
            return .tooOld(age: messageAge)
        }

        return .eligible
    }

    private var activeMonitor: any MessageMonitoring {
        switch activeMonitoringMethod {
        case .accessibility:
            return accessibilityMonitor
        case .database:
            return databaseMonitor
        }
    }

    private func bindCallbacks(
        for monitor: any MessageMonitoring,
        logPrefix: String,
        onDetectedMessage: @escaping @Sendable (DetectedMessage) -> Void,
        onDebugLog: @escaping @Sendable (String) -> Void
    ) {
        monitor.onNewMessage = { detected in
            onDetectedMessage(detected)
        }
        monitor.onDebugLog = { message in
            onDebugLog("[\(logPrefix)] \(message)")
        }
    }
}
