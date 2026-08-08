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

    enum Event: String {
        case printStarted = "print_started"
        case printPaused = "print_paused"
        case printResumed = "print_resumed"
        case printFinished = "print_finished"
        case printFailed = "print_failed"
        case klipperError = "klipper_error"
        case disconnected = "disconnected"
        case connected = "connected"
        case targetReached = "target_reached"
        case autoPowerOff = "auto_power_off"
        case visionAlert = "vision_alert"
        case queueReady = "queue_ready"
        case maintenanceDue = "maintenance_due"
        case filamentLow = "filament_low"

        var titleKey: String { "notification.\(rawValue).title" }

        var soundIsCritical: Bool {
            self == .klipperError || self == .printFailed || self == .visionAlert
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
        case .autoPowerOff:
            return true
        case .visionAlert:
            return settings.notifyVisionAlerts
        case .queueReady:
            return settings.notifyQueueReady
        case .maintenanceDue:
            return settings.notifyMaintenanceDue
        case .filamentLow:
            return settings.notifyFilamentLow
        }
    }

    func clearDelivered() {
        center.removeAllDeliveredNotifications()
        deliveredEventIDs.removeAll()
    }
}
