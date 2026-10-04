import BackgroundTasks
import Foundation
import UserNotifications

/// Notifications when the app is not on screen.
///
/// Everything the app knew about the printer arrived over a WebSocket that only
/// lives while the app is running. Close the app and the socket closes with it,
/// so a print that finished - or failed - twenty minutes later told nobody. The
/// notification code was there and correct; there was simply nothing awake to
/// call it. `UIBackgroundModes: fetch` was even declared, and nothing had ever
/// registered a task to use it.
///
/// Real push (a notification with the app fully terminated, delivered by Apple)
/// needs an APNs key, a push server and a paid developer account. This is the
/// other half of what iOS offers: the system wakes the app now and then, it
/// asks the Pi one question, and anything that changed since last time becomes
/// a local notification.
///
/// **iOS decides when.** Typically every 15-60 minutes, sooner for an app that
/// is opened often, later - or never - for one that is not, and never at all in
/// Low Power Mode. So this is a safety net, not a live feed: a print that ends
/// while the phone is in a pocket is reported within the hour rather than the
/// second. Anything better needs the push server, and pretending otherwise
/// would be the kind of promise that gets found out at 3am.
enum BackgroundWatch {

    /// Must match `BGTaskSchedulerPermittedIdentifiers` in Info.plist. A task
    /// submitted under an identifier that is not listed there throws, and the
    /// throw is the only sign anything is wrong.
    static let refreshIdentifier = "com.neptune.remote.refresh"

    /// The soonest iOS is asked to wake us. It is a request, not a schedule.
    static let interval: TimeInterval = 15 * 60

    // MARK: - Scheduling

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        do {
            // Submitting again replaces the pending request rather than adding
            // a second one, so calling this on every background is harmless.
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Simulator has no scheduler, and a user who has disabled
            // Background App Refresh is a refusal rather than a bug. Recorded
            // where the alert screen can show it instead of thrown away.
            lastSchedulingError = error.localizedDescription
        }
    }

    private(set) static var lastSchedulingError: String?

    // MARK: - The check itself

    /// Ask the Pi what is happening and notify about anything new.
    ///
    /// Deliberately independent of every store in the app: iOS may have
    /// relaunched the process for this alone, with no screen, no environment
    /// and nothing loaded. Connection details come from the App Group, the
    /// token from the Keychain, and the previous state from disk.
    static func run() async {
        defer { schedule() }

        guard flag(.notifications) else { return }
        // Demo mode must never reach out to a real machine, least of all from
        // a process the user cannot see.
        guard !flag(.demoMode, or: false) else { return }

        let config = SharedStore.loadConnection()
        guard config.isValid, let base = config.backendBaseURL else { return }

        let previous = loadState()
        let current: Reading?
        do {
            current = try await read(base: base)
        } catch {
            // Unreachable. Announced once, and only when the printer was doing
            // something worth losing sight of - "your idle printer is still
            // idle and also unreachable" is not news.
            if previous.state == "printing", !previous.unreachable, flag(.notifyDisconnected) {
                await notify(
                    titleKey: "notification.disconnected.title",
                    body: L.t("notification.background.unreachable"),
                    identifier: "bg-unreachable-\(previous.filename)",
                    urgent: true
                )
            }
            var carried = previous
            carried.unreachable = true
            save(carried)
            return
        }

        guard let current else { return }
        await announce(previous: previous, current: current)
        save(current)
    }

    /// A settings toggle, read straight from where `AppSettings` writes it.
    ///
    /// The stores are not available here - this can run in a process iOS
    /// relaunched with nothing on screen - so the defaults are read directly,
    /// through `AppSettings.Key` rather than a copy of the string.
    static func flag(_ key: AppSettings.Key, or fallback: Bool = true) -> Bool {
        UserDefaults.standard.object(forKey: key.rawValue) as? Bool ?? fallback
    }

    // MARK: - What changed

    /// One thing worth waking somebody for.
    struct Alert: Equatable {
        let titleKey: String
        let body: String
        let identifier: String
        let urgent: Bool
    }

    /// What to say about the difference between two readings.
    ///
    /// Pure, and separate from delivering: this is the part that decides
    /// whether a phone lights up at 3am, and it should be provable without a
    /// notification centre anywhere near it.
    static func decide(
        previous: Reading,
        current: Reading,
        allow: (AppSettings.Key) -> Bool = { flag($0) }
    ) -> [Alert] {
        // Nothing to compare against on the very first run: announcing the
        // state the printer was already in would be a notification for having
        // installed the app.
        guard previous.hasReading else { return [] }

        var alerts: [Alert] = []
        let stamp = Int(current.at)

        if previous.unreachable, !current.unreachable, current.state == "printing" {
            alerts.append(
                Alert(
                    titleKey: "notification.connected.title",
                    body: L.t("notification.background.back", current.filename),
                    identifier: "bg-back-\(current.filename)-\(stamp)",
                    urgent: false
                )
            )
        }

        if previous.state != current.state || previous.filename != current.filename {
            switch current.state {
            case "complete" where allow(.notifyFinished):
                alerts.append(
                    Alert(
                        titleKey: "notification.print_finished.title",
                        body: current.filename,
                        identifier: "bg-done-\(current.filename)-\(stamp)",
                        urgent: false
                    )
                )
            case "error" where allow(.notifyFailed), "cancelled" where allow(.notifyFailed):
                alerts.append(
                    Alert(
                        titleKey: "notification.print_failed.title",
                        body: current.message.isEmpty ? current.filename : current.message,
                        identifier: "bg-failed-\(current.filename)-\(stamp)",
                        urgent: true
                    )
                )
            case "paused" where allow(.notifyStateChanges):
                // A pause nobody asked for is a runout or a sensor, and the
                // printer sits at temperature until somebody comes.
                alerts.append(
                    Alert(
                        titleKey: "notification.print_paused.title",
                        body: current.message.isEmpty ? current.filename : current.message,
                        identifier: "bg-paused-\(current.filename)-\(stamp)",
                        urgent: true
                    )
                )
            default:
                break
            }
        }

        if ["shutdown", "error"].contains(current.klippy),
           previous.klippy != current.klippy,
           allow(.notifyKlipper) {
            alerts.append(
                Alert(
                    titleKey: "notification.klipper_error.title",
                    body: current.message,
                    identifier: "bg-klippy-\(stamp)",
                    urgent: true
                )
            )
        }

        return alerts
    }

    private static func announce(previous: Reading, current: Reading) async {
        for alert in decide(previous: previous, current: current) {
            await notify(
                titleKey: alert.titleKey,
                body: alert.body,
                identifier: alert.identifier,
                urgent: alert.urgent
            )
        }
    }

    // MARK: - Reading the printer

    struct Reading: Codable, Equatable {
        var state = ""
        var klippy = ""
        var filename = ""
        var message = ""
        var progress: Double = 0
        var unreachable = false
        var at: TimeInterval = 0

        /// False for the state saved before the first successful read.
        var hasReading: Bool { !state.isEmpty }
    }

    private static func read(base: URL) async throws -> Reading? {
        var request = URLRequest(
            url: base.appendingPathComponent("api").appendingPathComponent("printer/status")
        )
        // Short: iOS gives a background task seconds, not minutes, and a hung
        // request spends the whole budget and gets the app's future wake-ups
        // taken away.
        request.timeoutInterval = 12
        let token = Keychain.get(.backendToken) ?? ""
        if !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: BackendClient.apiKeyHeader)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let status = try JSONDecoder().decode(BackendPrinterStatus.self, from: data)
        return Reading(
            state: status.state,
            klippy: status.klippyState,
            filename: status.filename,
            message: status.stateMessage.isEmpty ? status.klippyMessage : status.stateMessage,
            progress: status.progress,
            unreachable: !status.online,
            at: Date().timeIntervalSince1970
        )
    }

    // MARK: - Remembering

    private static let stateKey = "background.lastReading"

    static func loadState() -> Reading {
        guard let data = SharedStore.defaults.data(forKey: stateKey),
              let reading = try? JSONDecoder().decode(Reading.self, from: data)
        else { return Reading() }
        return reading
    }

    static func save(_ reading: Reading) {
        guard let data = try? JSONEncoder().encode(reading) else { return }
        SharedStore.defaults.set(data, forKey: stateKey)
    }

    /// Record what the app itself is seeing, so a wake-up an hour later
    /// compares against the truth rather than against whatever was on screen
    /// the last time a background check happened to run.
    static func record(state: String, klippy: String, filename: String, progress: Double) {
        save(
            Reading(
                state: state,
                klippy: klippy,
                filename: filename,
                message: "",
                progress: progress,
                unreachable: false,
                at: Date().timeIntervalSince1970
            )
        )
    }

    // MARK: - Delivering

    private static func notify(
        titleKey: String, body: String, identifier: String, urgent: Bool
    ) async {
        let content = UNMutableNotificationContent()
        content.title = L.t(titleKey)
        content.body = body
        content.sound = urgent ? .defaultCritical : .default
        content.threadIdentifier = "neptune.printer"
        content.interruptionLevel = urgent ? .timeSensitive : .active

        let request = UNNotificationRequest(
            identifier: identifier, content: content, trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}
