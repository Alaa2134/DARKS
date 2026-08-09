import Foundation
import UserNotifications

/// Local notifications for printer events.
///
/// True remote push (a notification while the app is fully terminated) requires
/// an APNs key, a push server and a paid Apple Developer account - see
/// docs/NOTIFICATIONS.md. This app deliberately implements only what works
/// without that infrastructure:
///
///  * local notifications fired from the live WebSocket while the app runs
///    (foreground or in the background for as long as iOS keeps the socket),
///  * a background-refresh task that polls the printer and notifies on change.
///
/// Nothing here pretends to be APNs.
@MainActor
final class NotificationManager: ObservableObject {

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var lastError: String?

    private let center = UNUserNotificationCenter.current()
    private var deliveredEventIDs = Set<String>()

    enum Event: String, CaseIterable {
        case printStarted = "print_started"
        case printPaused = "print_paused"
        case printResumed = "print_resumed"
        case printFinished = "print_finished"
        case printFailed = "print_failed"
        case firstLayerComplete = "first_layer_complete"
        case printHalfway = "print_halfway"
        case klipperError = "klipper_error"
        case disconnected = "disconnected"
        case connected = "connected"
        case targetReached = "target_reached"
        case autoPowerOff = "auto_power_off"
        case autoPowerOffFailed = "auto_power_off_failed"
        case visionAlert = "vision_alert"
        case aiPauseFailed = "ai_pause_failed"
        case queueReady = "queue_ready"
        case maintenanceDue = "maintenance_due"
        case filamentLow = "filament_low"
        case filamentRunout = "filament_runout"
        case powerLost = "power_lost"
        case powerRestored = "power_restored"
        case printInterrupted = "print_interrupted"
        case safetyBlocked = "safety_blocked"
        case anomaly = "anomaly"

        var titleKey: String { "notification.\(rawValue).title" }

        /// Events that mean a human has to do something.
        ///
        /// These get `.timeSensitive`, which is what lets them through a
        /// Focus/Do Not Disturb schedule. Handing that out for "print reached
        /// 50%" is how people end up disabling the category entirely - and
        /// then the one alert that mattered arrives silently too.
        var soundIsCritical: Bool {
            switch self {
            case .klipperError, .printFailed, .visionAlert, .aiPauseFailed,
                 .filamentRunout, .powerLost, .printInterrupted, .anomaly:
                return true
            default:
                return false
            }
        }
    }

    func refreshAuthorizationStatus() async {
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorizationStatus()
            return granted
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Post a notification, ignoring duplicates of the same backend event.
    func post(event: Event, body: String, identifier: String? = nil, settings: AppSettings) {
        guard settings.notificationsEnabled else { return }
        guard shouldDeliver(event, settings: settings) else { return }

        if let identifier {
            guard !deliveredEventIDs.contains(identifier) else { return }
            deliveredEventIDs.insert(identifier)
            if deliveredEventIDs.count > 300 { deliveredEventIDs.removeAll() }
        }

        let content = UNMutableNotificationContent()
        content.title = L.t(event.titleKey)
        content.body = body
        content.sound = event.soundIsCritical ? .defaultCritical : .default
        content.threadIdentifier = "neptune.printer"
        content.interruptionLevel = event.soundIsCritical ? .timeSensitive : .active

        let request = UNNotificationRequest(
            identifier: identifier ?? UUID().uuidString,
            content: content,
            trigger: nil // deliver immediately
        )
        center.add(request) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.lastError = error.localizedDescription }
        }
    }

    private func shouldDeliver(_ event: Event, settings: AppSettings) -> Bool {
        switch event {
        case .printFinished:
            return settings.notifyPrintFinished
        case .printFailed:
            return settings.notifyPrintFailed
        case .klipperError:
            return settings.notifyKlipperError
        case .disconnected, .connected:
            return settings.notifyDisconnected
        case .targetReached:
            return settings.notifyTargetReached
        case .printStarted, .printPaused, .printResumed:
            return settings.notifyPrintStateChanges
        case .firstLayerComplete, .printHalfway:
            return settings.notifyProgressMilestones
        case .visionAlert:
            return settings.notifyVisionAlerts
        case .queueReady:
            return settings.notifyQueueReady
        case .maintenanceDue:
            return settings.notifyMaintenanceDue
        case .filamentLow:
            return settings.notifyFilamentLow
        case .powerLost, .powerRestored, .printInterrupted, .filamentRunout:
            return settings.notifyPowerAndRunout
        case .anomaly:
            return settings.notifyVisionAlerts
        // Not switchable. Each one means the machine tried to protect itself
        // and either did or could not, and a silent version of that is worse
        // than no version.
        case .autoPowerOff, .autoPowerOffFailed, .aiPauseFailed, .safetyBlocked:
            return true
        }
    }

    func clearDelivered() {
        center.removeAllDeliveredNotifications()
        deliveredEventIDs.removeAll()
    }
}
