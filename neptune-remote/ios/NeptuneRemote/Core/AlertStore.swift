import Foundation

/// Out-of-house alerting: whether it works, and what it caught while you were out.
///
/// The distinction this store exists to keep visible: local notifications need
/// the app running, so they are worth nothing when the phone is in a pocket on
/// another network. Only the Pi pushing to ntfy or Telegram reaches you then.
/// `isReachableWhenClosed` is that fact, surfaced rather than assumed.
@MainActor
final class AlertStore: ObservableObject {

    @Published private(set) var status = AlertStatus()
    @Published private(set) var outage = OutageStatus()
    @Published var preferences = AlertPreferences()

    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var isTesting = false
    @Published private(set) var lastTest: AlertTestResult?
    @Published var lastError: APIError?

    private let settings: AppSettings
    private let printer: PrinterStore
    private var loadedOnce = false

    init(settings: AppSettings, printer: PrinterStore) {
        self.settings = settings
        self.printer = printer
    }

    /// Nothing on the phone can substitute for this being true.
    var isReachableWhenClosed: Bool { status.reachableWhenAppIsClosed }

    /// The most recent interruption that still deserves the user's attention.
    var unacknowledgedOutage: OutageRecord? {
        guard let last = outage.last, !last.acknowledged, last.wasPrinting else { return nil }
        return last
    }

    var criticalEvents: Set<String> { Set(status.notifications.criticalEvents) }

    func load(force: Bool = false) async {
        guard !isLoading, force || !loadedOnce else { return }
        isLoading = true
        defer { isLoading = false }

        if settings.demoMode {
            status = Self.demoStatus
            outage = Self.demoOutage
            preferences = status.notifications.preferences
            loadedOnce = true
            return
        }

        do {
            async let statusTask = printer.backend.alertStatus()
            async let outageTask = printer.backend.outageStatus()
            status = try await statusTask
            outage = try await outageTask
            preferences = status.notifications.preferences
            loadedOnce = true
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    func refreshOutage() async {
        guard !settings.demoMode else { return }
        if let fresh = try? await printer.backend.outageStatus() { outage = fresh }
    }

    // MARK: - Preferences

    func setEvent(_ kind: String, enabled: Bool) async {
        var events = Set(preferences.events)
        if enabled { events.insert(kind) } else { events.remove(kind) }
        var updated = preferences
        updated.events = events.sorted()
        await save(updated)
    }

    func save(_ updated: AlertPreferences) async {
        guard !isSaving else { return }
        // Optimistic: the toggle has to move under the finger, and a failure
        // rolls it back rather than leaving the switch lying about the state.
        let previous = preferences
        preferences = updated
        isSaving = true
        defer { isSaving = false }

        guard !settings.demoMode else { return }

        do {
            preferences = try await printer.backend.updateAlertPreferences(updated)
            lastError = nil
        } catch {
            preferences = previous
            lastError = APIError.from(error, host: settings.host)
        }
    }

    // MARK: - Testing

    func sendTest() async {
        guard !isTesting else { return }
        isTesting = true
        defer { isTesting = false }

        if settings.demoMode {
            lastTest = AlertTestResult(sent: true, reason: "", channels: [])
            return
        }

        do {
            lastTest = try await printer.backend.sendAlertTest()
            lastError = nil
        } catch {
            lastTest = nil
            lastError = APIError.from(error, host: settings.host)
        }
    }

    func testHeartbeat() async {
        guard !settings.demoMode else { return }
        do {
            var updated = status
            updated.heartbeat = try await printer.backend.testHeartbeat()
            status = updated
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    // MARK: - Outages

    func acknowledge(_ record: OutageRecord) async {
        if settings.demoMode {
            outage.last?.acknowledged = true
            return
        }
        do {
            outage = try await printer.backend.acknowledgeOutage(record.id)
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }
}

// MARK: - Demo data

extension AlertStore {
    static var demoStatus: AlertStatus {
        var status = AlertStatus()
        status.reachableWhenAppIsClosed = true
        status.advice = AlertAdvice(
            level: "ok",
            ar: "الإشعارات والـ heartbeat الاتنين شغالين.",
            en: "Notifications and the heartbeat are both active."
        )
        status.notifications.enabled = true
        status.notifications.configured = true
        status.notifications.channels = [
            AlertChannel(name: "ntfy", sent: 42, failed: 0, lastError: "", lastSuccessAt: 0)
        ]
        status.notifications.availableEvents = [
            "connected", "disconnected", "filament_runout", "first_layer_complete",
            "klipper_error", "power_lost", "power_restored", "print_failed",
            "print_finished", "print_interrupted", "print_paused", "print_resumed",
            "print_started", "vision_alert",
        ]
        status.notifications.criticalEvents = [
            "filament_runout", "klipper_error", "power_lost", "print_failed",
            "print_interrupted", "vision_alert",
        ]
        status.notifications.preferences = AlertPreferences(
            enabled: true,
            events: status.notifications.availableEvents,
            minPriority: "low"
        )
        status.heartbeat = HeartbeatStatus(
            enabled: true, intervalSeconds: 300, lastPingAt: Date().timeIntervalSince1970 - 90,
            secondsSinceLastPing: 90, successes: 288, failures: 1, lastError: ""
        )
        return status
    }

    static var demoOutage: OutageStatus {
        var outage = OutageStatus()
        outage.enabled = true
        outage.serialPath = "/dev/serial/by-id/usb-1a86_USB_Serial-if00-port0"
        outage.serialPresent = true
        return outage
    }
}
