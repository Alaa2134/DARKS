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
///  * `BackgroundWatch`, which iOS wakes every so often to ask the Pi what
///    happened and notify about anything that changed.
///
/// Nothing here pretends to be APNs.
@MainActor
final class NotificationManager: NSObject, ObservableObject {

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var lastError: String?

    private let center = UNUserNotificationCenter.current()
    private var deliveredEventIDs = Set<String>()

    override init() {
        super.init()
        // Without a delegate iOS shows nothing at all while the app is on
        // screen - it hands the notification to the app and assumes the app
        // will present it in its own UI. So every alert raised while the user
        // was looking at the app was silently swallowed, which is a large part
        // of "the notifications never arrive".
        center.delegate = self
    }

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

    /// A notification with nothing behind it, on purpose.
    ///
    /// Every other line on the alerts screen is a claim about what *would*
    /// happen. This one either appears on the lock screen or it does not, which
    /// separates "the printer never told us" from "iOS is not letting anything
    /// through" - a distinction nobody should have to make by waiting nine
    /// hours for a print to end.
    func postTest() {
        let content = UNMutableNotificationContent()
        content.title = L.t("alerts.test.local.title")
        content.body = L.t("alerts.test.local.body")
        content.sound = .default
        content.threadIdentifier = "neptune.printer"

        // Three seconds out rather than immediate, so there is time to lock
        // the phone and see it arrive the way a real one would.
        let request = UNNotificationRequest(
            identifier: "neptune-test-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
        )
        center.add(request) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.lastError = error.localizedDescription }
        }
    }

    func clearDelivered() {
        center.removeAllDeliveredNotifications()
        deliveredEventIDs.removeAll()
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    /// Show it even when the app is in the foreground.
    ///
    /// A banner while the app is open is not noise here: the screen the user is
    /// on is usually not the printer screen, and an alert that only appears
    /// when the app is closed is an alert you cannot test.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}

