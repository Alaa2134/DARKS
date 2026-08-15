import Combine
import Foundation
import SwiftUI

struct ConsoleLine: Identifiable, Equatable {
    enum Kind { case command, response, error, info }
    let id = UUID()
    let date: Date
    let text: String
    let kind: Kind
}

/// The heart of the app: live printer state, every printer command, and power.
@MainActor
final class PrinterStore: ObservableObject {

    // MARK: - Published state

    @Published private(set) var snapshot = PrinterSnapshot()
    @Published private(set) var temperatureHistory: [TemperatureSample] = []
    @Published private(set) var console: [ConsoleLine] = []

    /// Whether the numbers on screen are old enough to stop presenting as live.
    ///
    /// Republished from the poll tick rather than computed in the views:
    /// staleness is the one property that becomes true because *nothing*
    /// happened, and a SwiftUI view has no reason to redraw for that.
    @Published private(set) var isSnapshotStale = false

    @Published private(set) var moonrakerConnected = false
    @Published private(set) var backendConnected = false

    /// What this printer can actually do, read from its printer.cfg. Every
    /// screen that needs a limit, a fan name, a macro or a feature flag asks
    /// this rather than assuming a Neptune 3 Plus.
    @Published private(set) var capabilities = PrinterCapabilities()
    @Published private(set) var capabilityError: APIError?
    private var capabilityTask: Task<Void, Never>?

    /// Brightness per discovered light, 0...1, keyed by Klipper object name.
    /// A light missing from here has not answered yet - which the switch shows
    /// as unknown rather than claiming it is off.
    @Published private(set) var lightLevels: [String: Double] = [:]
    /// Set when Moonraker or the backend rejected our credentials. Tracked
    /// separately from "not connected" because the fix is different: the user
    /// has to correct an API key, not chase a network.
    @Published private(set) var authenticationFailed = false

    /// The four states the UI distinguishes.
    enum ConnectionPhase: Equatable {
        case connected
        case connecting
        case disconnected
        case authenticationFailed

        var localizationKey: String {
            switch self {
            case .connected: return "connection.connected"
            case .connecting: return "connection.connecting"
            case .disconnected: return "connection.disconnected"
            case .authenticationFailed: return "connection.auth_failed"
            }
        }
    }

    var connectionPhase: ConnectionPhase {
        if settings.demoMode { return .connected }
        if authenticationFailed { return .authenticationFailed }
        if moonrakerConnected || backendConnected { return .connected }
        switch moonrakerSocket.state {
        case .connecting, .idle: return .connecting
        case .connected: return .connected
        case .failed: return .disconnected
        }
    }
    /// What the app is waiting for right now, in the order it waits for it.
    ///
    /// Getting from "app opened" to "printer on screen" is four separate waits
    /// - reaching the Pi, reaching Moonraker, Klipper becoming ready, reading
    /// printer.cfg - and any one of them can be the slow or broken one. The app
    /// used to show the same nothing for all four, so a Pi that was off looked
    /// exactly like a Klipper that was still starting, and both looked like an
    /// app that had hung.
    enum StartupStage: Hashable {
        case reachingPi
        case reachingPrinter
        case waitingForKlipper
        case readingConfig
        case ready
        case authenticationFailed
        case offline

        var isSettled: Bool {
            self == .ready || self == .authenticationFailed || self == .offline
        }

        var localizationKey: String {
            switch self {
            case .reachingPi: return "startup.reaching_pi"
            case .reachingPrinter: return "startup.reaching_printer"
            case .waitingForKlipper: return "startup.waiting_klipper"
            case .readingConfig: return "startup.reading_config"
            case .ready: return "startup.ready"
            case .authenticationFailed: return "connection.auth_failed"
            case .offline: return "startup.offline"
            }
        }

        /// The step number, for a progress bar that tracks something real
        /// rather than an animation pretending to.
        var step: Int {
            switch self {
            case .reachingPi: return 1
            case .reachingPrinter: return 2
            case .waitingForKlipper: return 3
            case .readingConfig: return 4
            case .ready: return 4
            case .authenticationFailed, .offline: return 0
            }
        }

        static let totalSteps = 4
    }

    var startupStage: StartupStage {
        if settings.demoMode { return .ready }
        if authenticationFailed { return .authenticationFailed }

        // A failed socket that has stopped trying is offline, not connecting.
        if case .failed = moonrakerSocket.state, !backendConnected { return .offline }

        if !backendConnected && !moonrakerConnected { return .reachingPi }
        if !moonrakerConnected { return .reachingPrinter }
        if snapshot.klippy != .ready { return .waitingForKlipper }
        // Capabilities are what every screen keys off, so the app is not
        // actually usable until printer.cfg has been read.
        if capabilities.discoveredAt == nil { return .readingConfig }
        return .ready
    }

    @Published private(set) var backendHealth: BackendHealth?
    @Published private(set) var power = PowerReading.unavailable
    /// True while at least one command is in flight. Buttons disable on it.
    ///
    /// Derived from a depth counter rather than assigned directly. It used to be
    /// a plain boolean set to `true` on entry and `false` on exit, which is only
    /// correct for one command at a time: with two overlapping - a pause landing
    /// while a temperature set is still going - the first to finish cleared the
    /// flag and re-enabled every button while the second was still on its way.
    @Published private(set) var isBusy = false
    private var busyDepth = 0

    /// Commands currently on their way to the printer, by name.
    ///
    /// `isBusy` cannot prevent a double send on its own: SwiftUI applies
    /// `.disabled` on the next render, and two taps inside one frame both start
    /// their Task before that render happens. Cancelling a print twice is not
    /// harmless - the second CANCEL_PRINT lands on the next print.
    private var inFlight: Set<String> = []

    /// The one-shot Home payload pushed by the backend over `/ws`.
    /// Nil until the first frame arrives (or when the backend is unreachable).
    @Published private(set) var summary: BackendSummary?

    @Published var lastError: APIError?
    @Published var lastMessage: String?

    /// Routed to SliceStore / SystemStore / MediaStore / InventoryStore by AppEnvironment.
    var onSliceProgress: ((BackendSocket.SliceProgress) -> Void)?
    var onSystemUpdate: ((BackendSystem) -> Void)?
    var onSummary: ((BackendSummary) -> Void)?

    // MARK: - Dependencies

    private let settings: AppSettings
    private let notifications: NotificationManager
    let moonraker: MoonrakerClient
    let backend: BackendClient
    private let moonrakerSocket: MoonrakerSocket
    private let backendSocket: BackendSocket
    private let demo = DemoSimulator()
    private let http = HTTPClient()

    private var objects = PrinterObjects()
    private var serverInfo: MoonrakerServerInfo?
    private var pollTask: Task<Void, Never>?
    private var powerTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var previousState: PrinterState = .unknown
    private var previousOnline = true
    private var isRunning = false

    private let historyLimit = 900   // 15 minutes at 1 Hz
    private let consoleLimit = 500

    // MARK: - Init

    init(settings: AppSettings, notifications: NotificationManager) {
        self.settings = settings
        self.notifications = notifications

        let config = settings.connection
        moonraker = MoonrakerClient(config: config, apiKey: settings.moonrakerAPIKey)
        backend = BackendClient(config: config, token: settings.backendToken)
        moonrakerSocket = MoonrakerSocket(config: config, apiKey: settings.moonrakerAPIKey)
        backendSocket = BackendSocket(config: config, token: settings.backendToken)

        wireSockets()
        wireDemo()
        observeSettings()
    }

    // MARK: - Wiring

    private func wireSockets() {
        moonrakerSocket.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .connected:
                self.moonrakerConnected = true
                self.appendConsole(L.t("terminal.connected"), kind: .info)
                // A reconnect may be to a Pi that rebooted with an edited
                // printer.cfg, so re-read rather than trusting what we had.
                self.refreshCapabilities()
            case .disconnected(let message):
                self.moonrakerConnected = false
                if let message { self.appendConsole(message, kind: .error) }
            case .status(let update):
                self.objects.merge(update)
                self.applyObjects()
            case .gcodeResponse(let line):
                self.appendConsole(line, kind: line.hasPrefix("!!") ? .error : .response)
            case .klippyReady:
                self.appendConsole(L.t("klippy.state.ready"), kind: .info)
                // FIRMWARE_RESTART and RESTART both land here, and both are how
                // a printer.cfg edit takes effect.
                self.refreshCapabilities(force: true)
            case .klippyShutdown, .klippyDisconnected:
                self.snapshot.klippy = .shutdown
                self.appendConsole(L.t("error.klipper_not_ready"), kind: .error)
            case .printerError(let message):
                self.snapshot.errorMessage = message
                self.notifications.post(event: .klipperError, body: message, settings: self.settings)
            }
        }

        backendSocket.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .connected:
                self.backendConnected = true
            case .disconnected:
                self.backendConnected = false
            case .hello:
                break
            case .printer(let status):
                // Moonraker's own socket is authoritative when it is connected.
                if !self.moonrakerConnected, !self.settings.demoMode {
                    self.update(snapshot: status.snapshot)
                }
            case .power(let status):
                self.power = PowerReading(
                    state: PowerState(raw: status.state),
                    available: status.available,
                    provider: .backend,
                    device: status.device,
                    message: status.message
                )
            case .summary(let summary):
                self.summary = summary
                self.onSummary?(summary)
            case .slice(let progress):
                self.onSliceProgress?(progress)
            case .system(let system):
                self.onSystemUpdate?(system)
            case .printerEvent(let event):
                self.handleBackendEvent(event)
            }
        }
    }

    private func wireDemo() {
        demo.onUpdate = { [weak self] snapshot in
            guard let self, self.settings.demoMode else { return }
            self.update(snapshot: snapshot)
            self.power = PowerReading(
                state: self.demo.powerState, available: true, provider: .demo, device: "demo-switch"
            )
        }
        demo.onConsole = { [weak self] line in
            guard let self, self.settings.demoMode else { return }
            self.appendConsole(line, kind: line.hasPrefix(">") ? .command : .response)
        }
        demo.onEvent = { [weak self] kind, filename in
            guard let self, self.settings.demoMode else { return }
            guard let event = NotificationManager.Event(rawValue: kind) else { return }
            self.notifications.post(event: event, body: filename, settings: self.settings)
        }
    }

    private func observeSettings() {
        settings.objectWillChange
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.reconfigure() }
            }
            .store(in: &cancellables)
    }

    private func reconfigure() {
        let config = settings.connection
        let apiKey = settings.moonrakerAPIKey
        let token = settings.backendToken

        Task {
            await moonraker.update(config: config, apiKey: apiKey)
            await backend.update(config: config, token: token)
        }
        moonrakerSocket.update(config: config, apiKey: apiKey)
        backendSocket.update(config: config, token: token)

        if settings.demoMode {
            moonrakerSocket.disconnect()
            backendSocket.disconnect()
            demo.start()
        } else {
            demo.stop()
            if isRunning {
                moonrakerSocket.connect()
                backendSocket.connect()
            }
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        if settings.demoMode {
            demo.start()
            update(snapshot: demo.snapshot)
            power = PowerReading(state: demo.powerState, available: true, provider: .demo, device: "demo-switch")
            return
        }

        moonrakerSocket.connect()
        backendSocket.connect()
        startPolling()
        Task { await refreshBackendHealth() }
        Task { await refreshPower() }
    }

    func stop() {
        isRunning = false
        pollTask?.cancel()
        pollTask = nil
        powerTask?.cancel()
        powerTask = nil
        moonrakerSocket.disconnect()
        backendSocket.disconnect()
        demo.stop()
    }

    /// Called when the app returns to the foreground.
    func resume() {
        guard isRunning else { start(); return }
        if settings.demoMode {
            demo.start()
        } else {
            moonrakerSocket.restart()
            backendSocket.restart()
            Task { await refreshNow() }
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // The WebSocket carries live data; this poll is the safety net
                // for when it is down and it fills in server-level fields.
                if !self.moonrakerConnected {
                    await self.refreshNow()
                }
                // Checked on the tick, because a reading goes stale by nothing
                // arriving - there is no event to hang it off.
                let stale = self.snapshot.isStale
                if stale != self.isSnapshotStale { self.isSnapshotStale = stale }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }

        powerTask?.cancel()
        powerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.refreshPower()
            }
        }
    }

    // MARK: - Refresh

    func refreshNow() async {
        if settings.demoMode {
            update(snapshot: demo.snapshot)
            return
        }
        do {
            let info = try await moonraker.serverInfo()
            serverInfo = info
            guard info.klippyConnected else {
                var value = PrinterSnapshot()
                value.isOnline = true
                value.klippy = KlippyState(raw: info.klippyState)
                value.state = .error
                value.errorMessage = L.t("error.klipper_not_ready")
                update(snapshot: value)
                return
            }
            objects = try await moonraker.queryObjects()
            applyObjects()
            lastError = nil
            authenticationFailed = false
        } catch {
            let apiError = APIError.from(error, host: settings.host)
            update(snapshot: .offline(error: apiError.localizedDescription))
            lastError = apiError
            // A rejected API key is not the same as an unreachable printer, and
            // needs a different action from the user, so it is tracked apart.
            authenticationFailed = (apiError == .unauthorized)
        }
    }

    func refreshBackendHealth() async {
        do {
            backendHealth = try await backend.health()
        } catch {
            backendHealth = nil
        }
    }

    /// Nudge the backend for a fresh Home payload over the open socket, or pull
    /// it over REST when the socket is not up yet.
    func refreshSummary() async {
        guard !settings.demoMode else { return }
        if backendConnected {
            backendSocket.requestSummary()
            return
        }
        guard let fresh = try? await backend.summary() else { return }
        summary = fresh
        onSummary?(fresh)
    }

    private func applyObjects() {
        update(snapshot: PrinterSnapshot.make(objects: objects, serverInfo: serverInfo))
    }

    private func update(snapshot new: PrinterSnapshot) {
        let previous = snapshot
        snapshot = new
        recordTemperature(new)
        trackCooling(new)
        refreshEjectStateIfItShouldHaveFired(new)
        detectEvents(previous: previous, current: new)
        SharedStore.save(widgetSnapshot(from: new))
    }

    private func widgetSnapshot(from value: PrinterSnapshot) -> PrinterWidgetSnapshot {
        PrinterWidgetSnapshot(
            printerName: settings.printerName,
            isOnline: value.isOnline,
            state: value.state,
            klippy: value.klippy,
            power: power.state,
            filename: value.filename,
            progress: value.progress,
            nozzleActual: value.nozzleActual,
            nozzleTarget: value.nozzleTarget,
            bedActual: value.bedActual,
            bedTarget: value.bedTarget,
            estimatedRemaining: value.estimatedTimeLeft,
            updatedAt: Date()
        )
    }

    private func recordTemperature(_ value: PrinterSnapshot) {
        guard value.isOnline else { return }
        let sample = TemperatureSample(
            date: Date(),
            nozzle: value.nozzleActual,
            nozzleTarget: value.nozzleTarget,
            bed: value.bedActual,
            bedTarget: value.bedTarget
        )
        // One sample per second is plenty for the chart.
        if let last = temperatureHistory.last, Date().timeIntervalSince(last.date) < 0.9 { return }
        temperatureHistory.append(sample)
        if temperatureHistory.count > historyLimit {
            temperatureHistory.removeFirst(temperatureHistory.count - historyLimit)
        }
    }

    private func detectEvents(previous: PrinterSnapshot, current: PrinterSnapshot) {
        guard !settings.demoMode else { return }  // demo posts its own events

        if previousOnline != current.isOnline {
            previousOnline = current.isOnline
            if !current.isOnline {
                notifications.post(
                    event: .disconnected,
                    body: current.errorMessage ?? L.t("error.moonraker"),
                    settings: settings
                )
            }
        }

        guard current.state != previousState else { return }
        let from = previousState
        previousState = current.state

        switch current.state {
        case .printing:
            notifications.post(
                event: from == .paused ? .printResumed : .printStarted,
                body: current.filename,
                settings: settings
            )
        case .paused:
            notifications.post(event: .printPaused, body: current.filename, settings: settings)
        case .complete:
            notifications.post(event: .printFinished, body: current.filename, settings: settings)
        case .cancelled:
            notifications.post(event: .printFailed, body: current.filename, settings: settings)
        case .error:
            notifications.post(
                event: .printFailed,
                body: current.stateMessage.isEmpty ? L.t("error.klipper_not_ready") : current.stateMessage,
                settings: settings
            )
        default:
            break
        }
    }

    private func handleBackendEvent(_ event: BackendPrinterEvent) {
        guard !settings.demoMode else { return }
        guard let kind = NotificationManager.Event(rawValue: event.kind) else { return }
        notifications.post(
            event: kind,
            body: event.message.isEmpty ? event.title : event.message,
            identifier: event.id,
            settings: settings
        )
    }

    // MARK: - Console

    func appendConsole(_ text: String, kind: ConsoleLine.Kind) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        console.append(ConsoleLine(date: Date(), text: trimmed, kind: kind))
        if console.count > consoleLimit {
            console.removeFirst(console.count - consoleLimit)
        }
    }

    func clearConsole() { console.removeAll() }

    // MARK: - Commands

    @discardableResult
    func send(gcode: String, echo: Bool = true) async -> Bool {
        let script = gcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else { return false }

        if echo { appendConsole("> \(script)", kind: .command) }
        settings.recordCommand(script)

        if settings.demoMode {
            demo.handle(gcode: script)
            return true
        }

        do {
            _ = try await moonraker.runGCode(script)
            lastError = nil
            return true
        } catch {
            let apiError = APIError.from(error, host: settings.host)
            appendConsole(apiError.localizedDescription, kind: .error)
            lastError = apiError
            Haptics.error()
            return false
        }
    }

    // MARK: Homing / motion

    /// The raw G28. Private on purpose - see `home(axes:)`.
    private func sendHome(_ axes: String) async -> Bool {
        Haptics.impact(.medium)
        return await send(gcode: axes.isEmpty ? "G28" : "G28 \(axes.uppercased())")
    }

    /// Jogs an axis, never past the travel configured in printer.cfg.
    ///
    /// The move is clamped against `stepper_<axis>.position_min/max` using the
    /// live toolhead position, so a long step near the end of an axis becomes a
    /// short one instead of a command Klipper refuses - or worse, one it obeys
    /// into the frame. An axis whose limits were never discovered is refused
    /// outright rather than moved on a guess.
    @discardableResult
    func jog(axis: String, distance: Double, feedrate: Double) async -> Bool {
        let key = axis.lowercased()

        guard !capabilities.axisLimits.isEmpty else {
            // Before discovery has run there is nothing to check against.
            // Refusing here would make the app unusable on a machine whose
            // config could not be read, so the move goes through unclamped and
            // Klipper's own limits remain the backstop.
            return await sendJog(axis: axis, distance: distance, feedrate: feedrate)
        }
        guard let limit = capabilities.axisLimits[key] else {
            lastError = .unsafeOperation([L.t("control.axis_unknown", axis.uppercased())])
            Haptics.warning()
            return false
        }
        guard capabilities.isHomed(key) || snapshot.homedAxes.isEmpty else {
            // Unhomed position is meaningless, so there is nothing to clamp
            // against; Klipper refuses the move itself.
            lastError = .unsafeOperation([L.t("control.axis_not_homed", axis.uppercased())])
            Haptics.warning()
            return false
        }

        let current = livePosition(for: key) ?? limit.min
        let allowed = limit.clamp(current + distance) - current
        guard abs(allowed) > 0.0005 else {
            lastError = .unsafeOperation([
                L.t("control.axis_at_limit", axis.uppercased(), limit.min, limit.max)
            ])
            Haptics.warning()
            return false
        }
        if abs(allowed - distance) > 0.0005 {
            lastMessage = L.t("control.move_clamped", axis.uppercased(), allowed)
        }
        return await sendJog(axis: axis, distance: allowed, feedrate: feedrate)
    }

    private func sendJog(axis: String, distance: Double, feedrate: Double) async -> Bool {
        Haptics.impact(.light)
        // SAVE/RESTORE rather than G91-then-G90.
        //
        // Klipper keeps one G-code state for the whole machine, so the old
        // sequence did not restore what was there - it asserted absolute
        // positioning, whatever the previous mode had been. Restoring puts back
        // the mode, the feedrate and the offsets exactly as they were.
        // MOVE is not passed, so nothing moves on the way out.
        await send(gcode: "SAVE_GCODE_STATE NAME=neptune_jog", echo: false)
        await send(gcode: "G91", echo: false)
        let ok = await send(
            gcode: String(format: "G1 %@%.3f F%.0f", axis.uppercased(), distance, feedrate)
        )
        await send(gcode: "RESTORE_GCODE_STATE NAME=neptune_jog", echo: false)
        return ok
    }

    /// Toolhead position for one axis, from the live `toolhead`/`gcode_move`
    /// objects the socket streams.
    func livePosition(for axis: String) -> Double? {
        let index: Int
        switch axis.lowercased() {
        case "x": index = 0
        case "y": index = 1
        case "z": index = 2
        default: return nil
        }
        guard snapshot.position.count > index else { return nil }
        return snapshot.position[index]
    }

    func disableSteppers() async {
        await send(gcode: "M84")
    }

    /// Cold extrusion is refused unless the user explicitly overrides it.
    ///
    /// Both limits come from the extruder section of printer.cfg when it has
    /// been read: `min_extrude_temp` for the cold guard and
    /// `max_extrude_only_distance` for the length, since Klipper aborts a longer
    /// extrude-only move outright.
    func extrude(length: Double, speedMMPerSecond: Double) async -> Bool {
        let extruder = capabilities.primaryExtruder
        let minimum = extruder?.minExtrudeTemp ?? settings.minExtrusionTemp

        if !settings.allowColdExtrusion, !snapshot.canExtrude(minimumTemperature: minimum) {
            lastError = .unknown(L.t("control.cold_extrusion_blocked", minimum))
            Haptics.warning()
            return false
        }

        var requested = length
        if let maximum = extruder?.maxExtrudeOnlyDistance, maximum > 0, abs(length) > maximum {
            requested = length < 0 ? -maximum : maximum
            lastMessage = L.t("control.extrude_clamped", maximum)
        }

        Haptics.impact(.light)
        // M83 used to be left switched on afterwards: every later extrusion in
        // the session - a macro, a terminal command - then meant something
        // different from what its author wrote.
        await send(gcode: "SAVE_GCODE_STATE NAME=neptune_extrude", echo: false)
        await send(gcode: "M83", echo: false)
        let ok = await send(
            gcode: String(format: "G1 E%.2f F%.0f", requested, speedMMPerSecond * 60)
        )
        await send(gcode: "RESTORE_GCODE_STATE NAME=neptune_extrude", echo: false)
        return ok
    }

    // MARK: - Fans

    /// Sets one discovered fan by its exact Klipper object name.
    ///
    /// The command depends on the fan's kind: only the part-cooling `fan`
    /// answers M106/M107 and only `fan_generic` answers SET_FAN_SPEED. Fans
    /// Klipper drives itself (heater_fan, controller_fan, temperature_fan) are
    /// read-only here, because commanding them would mean guessing at a pin.
    @discardableResult
    func setFan(_ fan: PrinterCapabilities.FanSpec, percent: Double) async -> Bool {
        guard let command = fan.speedCommand(percent: percent) else {
            lastError = .unsafeOperation([L.t("fan.not_controllable", fan.displayName)])
            return false
        }
        Haptics.impact(.light)
        return await send(gcode: command)
    }

    // MARK: - Lights

    /// Turns a discovered light up or down, 0...1.
    ///
    /// The value is applied locally first so the switch answers immediately, and
    /// then confirmed from the printer: if Klipper rejected the command, the
    /// re-read puts the control back where the hardware actually is instead of
    /// leaving the UI showing a light that never came on.
    @discardableResult
    func setLight(_ light: PrinterCapabilities.LightSpec, brightness: Double) async -> Bool {
        let level = min(max(brightness, 0), 1)
        lightLevels[light.object] = light.isDimmable ? level : (level > 0 ? 1 : 0)
        Haptics.impact(.light)
        let ok = await send(gcode: light.command(brightness: level))
        await refreshLights()
        return ok
    }

    /// Sets a colour on a light that has colour channels. Refuses otherwise
    /// rather than sending RED/GREEN/BLUE to a single-channel pin.
    @discardableResult
    func setLight(
        _ light: PrinterCapabilities.LightSpec,
        red: Double,
        green: Double,
        blue: Double
    ) async -> Bool {
        guard let command = light.command(red: red, green: green, blue: blue) else {
            lastError = .unsafeOperation([L.t("light.no_colour", light.displayName)])
            return false
        }
        lightLevels[light.object] = max(max(red, green), blue)
        Haptics.impact(.light)
        let ok = await send(gcode: command)
        await refreshLights()
        return ok
    }

    /// Reads the current level of every discovered light.
    ///
    /// Lights are polled rather than streamed: they are subscribed to along with
    /// everything else, but the socket payload is decoded into a fixed set of
    /// dashboard objects, and a lamp does not need sub-second latency.
    func refreshLights() async {
        let lights = capabilities.lights
        guard !lights.isEmpty, !settings.demoMode else { return }
        guard let status = try? await moonraker.queryStatus(objects: lights.map(\.object)) else {
            return
        }
        for light in lights {
            guard let section = status.section(light.object),
                  let level = light.brightness(fromStatus: section)
            else { continue }
            lightLevels[light.object] = level
        }
    }

    // MARK: - Cool down, then eject

    /// The Pi's own answer about whether a sweep is armed and what is in the way.
    ///
    /// Deliberately not decided here. iOS suspends an app within seconds of it
    /// leaving the screen, so a wait implemented on the phone only completes
    /// while somebody is watching it - which is the one case where nobody
    /// needed the feature. The Pi is already awake and polling once a second,
    /// so it holds the arm and fires the macro; this is a view of that.
    @Published private(set) var ejectState: EjectState = .idle
    /// Bed degrees per minute, measured here from the temperatures already
    /// streaming in. Display only - nothing is decided from it.
    @Published private(set) var bedCoolingRate: Double?

    private var coolingSamples: [(at: Date, bed: Double)] = []

    /// How long until the bed is cold enough, from how fast it is actually
    /// cooling. nil when it is already cold, or not cooling in any useful way:
    /// an invented number would be worse than none, because the point of arming
    /// is that the person walks away and trusts the app to call them.
    var ejectWaitEstimate: TimeInterval? {
        let remaining = snapshot.bedActual - ejectState.maxBedC
        guard remaining > 0, let rate = bedCoolingRate, rate > 0.2 else { return nil }
        return remaining / rate * 60
    }

    func refreshEjectState() async {
        guard !settings.demoMode else { return }
        guard let fresh = try? await backend.ejectState() else { return }
        ejectState = fresh
    }

    /// Turns the heaters off on the printer and asks it to sweep once cold.
    @discardableResult
    func armEject() async -> Bool {
        guard !settings.demoMode else { return false }
        do {
            ejectState = try await backend.armEject()
            coolingSamples.removeAll()
            bedCoolingRate = nil
            Haptics.impact(.medium)
            return true
        } catch {
            lastError = APIError.from(error, host: settings.host)
            Haptics.error()
            return false
        }
    }

    func cancelEjectArm() async {
        guard !settings.demoMode else { return }
        try? await backend.cancelEjectArm()
        await refreshEjectState()
    }

    /// Ask the Pi again once this reading says the sweep should have run.
    ///
    /// The arm lives on the Pi, so the phone finds out it fired by asking. It
    /// asks when the temperatures say the moment has arrived rather than on a
    /// timer, and at most once every few seconds - a card that sat there saying
    /// "waiting" over a bed that swept its part off ten minutes ago is the
    /// failure this exists to avoid.
    private func refreshEjectStateIfItShouldHaveFired(_ value: PrinterSnapshot) {
        guard ejectState.armed, value.isOnline else { return }
        guard value.bedActual <= ejectState.maxBedC,
              value.nozzleActual <= ejectState.maxNozzleC else { return }
        let now = Date()
        guard now.timeIntervalSince(lastEjectPoll) > 4 else { return }
        lastEjectPoll = now
        Task { await refreshEjectState() }
    }

    private var lastEjectPoll = Date.distantPast

    private func trackCooling(_ value: PrinterSnapshot) {
        guard value.isOnline else { return }
        let now = Date()
        coolingSamples.append((at: now, bed: value.bedActual))
        // Two minutes of history: long enough for a rate that is not noise,
        // short enough to follow a curve that flattens as it nears the room.
        coolingSamples.removeAll { now.timeIntervalSince($0.at) > 120 }

        guard let first = coolingSamples.first, let last = coolingSamples.last else { return }
        let minutes = last.at.timeIntervalSince(first.at) / 60
        guard minutes > 0.4 else { return }
        bedCoolingRate = (first.bed - last.bed) / minutes
    }

    // MARK: - Macros

    /// Runs a macro Klipper reported. Nothing is invented: the name came from
    /// `[gcode_macro ...]` in the user's own config.
    @discardableResult
    func runMacro(_ macro: PrinterCapabilities.MacroSpec, arguments: String = "") async -> Bool {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = trimmed.isEmpty ? macro.name : "\(macro.name) \(trimmed)"
        Haptics.impact(.medium)
        return await send(gcode: command)
    }

    // MARK: Temperature

    /// Sets the nozzle target, never above the configured `max_temp`.
    ///
    /// Klipper rejects an over-limit target and shuts down, so clamping here
    /// turns a printer-halting mistake into a capped request. The ceiling comes
    /// from the extruder section of printer.cfg, not from a constant.
    func setNozzleTarget(_ temperature: Double) async {
        let target = clampHeaterTarget(temperature, heater: capabilities.primaryExtruder)
        await send(gcode: String(format: "M104 S%.0f", target))
    }

    func setBedTarget(_ temperature: Double) async {
        guard capabilities.hasHeatedBed || capabilities.isEmpty else {
            lastError = .unsafeOperation([L.t("temperature.no_heated_bed")])
            return
        }
        let target = clampHeaterTarget(temperature, heater: capabilities.bedHeater)
        await send(gcode: String(format: "M140 S%.0f", target))
    }

    /// Clamps to the heater's configured range. With no discovered heater the
    /// value only has its floor applied - Klipper still enforces its own limit.
    private func clampHeaterTarget(_ value: Double, heater: PrinterCapabilities.HeaterSpec?) -> Double {
        guard let heater, heater.maxTemp > 0 else { return max(0, value) }
        let clamped = heater.clampTarget(value)
        if clamped < value {
            lastMessage = L.t("temperature.clamped", heater.displayName, heater.maxTemp)
        }
        return clamped
    }

    /// The highest target a temperature control may offer for a heater, so the
    /// slider itself cannot be dragged into a shutdown.
    func maxTarget(for heater: PrinterCapabilities.HeaterSpec?) -> Double {
        guard let heater, heater.maxTemp > 0 else { return 300 }
        return heater.maxTemp
    }

    func preheat(_ preset: TemperaturePreset, nozzle: Bool = true, bed: Bool = true) async {
        Haptics.impact(.medium)
        if nozzle { await setNozzleTarget(preset.nozzle) }
        if bed { await setBedTarget(preset.bed) }
        lastMessage = L.t("temperature.preheating", preset.name)
    }

    func cooldown() async {
        Haptics.impact(.medium)
        await send(gcode: "TURN_OFF_HEATERS")
        lastMessage = L.t("temperature.cooling")
    }

    // MARK: Speed / flow / fan

    func setSpeedFactor(_ percent: Double) async {
        await send(gcode: String(format: "M220 S%.0f", clamp(percent, 10, 300)))
    }

    func setExtrusionFactor(_ percent: Double) async {
        await send(gcode: String(format: "M221 S%.0f", clamp(percent, 50, 200)))
    }

    func setFanSpeed(_ percent: Double) async {
        let value = clamp(percent, 0, 100) / 100 * 255
        await send(gcode: value <= 0 ? "M107" : String(format: "M106 S%.0f", value))
    }

    func setVelocityLimits(velocity: Double?, acceleration: Double?, squareCornerVelocity: Double?) async {
        var parts: [String] = ["SET_VELOCITY_LIMIT"]
        if let velocity { parts.append(String(format: "VELOCITY=%.0f", velocity)) }
        if let acceleration { parts.append(String(format: "ACCEL=%.0f", acceleration)) }
        if let squareCornerVelocity {
            parts.append(String(format: "SQUARE_CORNER_VELOCITY=%.1f", squareCornerVelocity))
        }
        guard parts.count > 1 else { return }
        await send(gcode: parts.joined(separator: " "))
    }

    private func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }

    // MARK: Print control

    /// Starts a print. Returns whether the printer accepted it.
    ///
    /// The result matters: the caller is a file screen that dismisses itself on
    /// success, and dismissing on a refusal is how a blocked print became
    /// invisible.
    @discardableResult
    func startPrint(filename: String) async -> Bool {
        // Keyed by file: two taps on Print are one print, but starting a
        // different file while the first request is still in flight is a
        // different intent and is left alone.
        let key = "print:\(filename)"
        guard !inFlight.contains(key) else { return false }
        inFlight.insert(key)
        defer { inFlight.remove(key) }

        beginBusy()
        defer { endBusy() }

        if settings.demoMode {
            demo.startPrint(filename: filename)
            Haptics.success()
            return true
        }

        // Unhomed axes used to *refuse* the print here. That was wrong, and
        // wrong in the direction that costs the user most: every sliced file
        // begins by homing - through the slicer's own G28 or through
        // PRINT_START - and Klipper clears `homed_axes` on M84, which every
        // print end and every idle timeout runs. So the guard fired on the
        // completely normal case of "the printer has been sitting idle", and
        // blocked a print that would have worked.
        //
        // Nothing is lost by proceeding. Klipper refuses to move an unhomed
        // axis itself, with "Must home axis first" - it aborts, it does not
        // crash the toolhead. Warning and continuing leaves that safety in the
        // one place that can actually enforce it, and stops this app from
        // vetoing prints on a guess about a file it has not read.
        let missing = PrinterConditionEvaluator.missingAxes(
            homed: snapshot.homedAxes,
            configured: capabilities.axisLimits.isEmpty
                ? ["x", "y", "z"]
                : capabilities.axisLimits.keys.sorted()
        )
        if !missing.isEmpty {
            lastMessage = L.t("print.unhomed_warning", missing.joined(separator: ", ").uppercased())
        }

        do {
            try await moonraker.startPrint(filename: filename)
            lastMessage = L.t("print.started", filename)
            Haptics.success()
            return true
        } catch {
            handle(error)
            return false
        }
    }

    /// The colour the printer is standing still waiting for, if that is why
    /// it is paused.
    ///
    /// Read out of the printer's own display message rather than from the slice
    /// job: the M117 sits next to every colour-change stop in the file, so this
    /// works for a file sliced last month, printed from the queue, or started
    /// from Mainsail - anywhere the app was not the one that pressed print.
    ///
    /// Only while actually paused. The message survives the resume, and a
    /// banner that stayed up while the printer went back to work would be worse
    /// than no banner.
    var waitingForColor: String? {
        guard snapshot.state == .paused else { return nil }
        return Self.colorFromDisplay(snapshot.displayMessage)
    }

    /// nonisolated: pure string parsing that touches nothing on the store, and
    /// a static func on a @MainActor class is otherwise MainActor-isolated,
    /// which would make it uncallable from a test.
    nonisolated static func colorFromDisplay(_ message: String) -> String? {
        // Matches DISPLAY_PREFIX in the backend's app/slicer/colors.py. Latin
        // on both sides deliberately: the colour name itself is in whatever
        // script the user thinks in, and the prefix is the part being matched.
        let prefix = "COLOR:"
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.uppercased().hasPrefix(prefix) else { return nil }
        let name = text.dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    // Print control prefers the printer's own PAUSE / RESUME / CANCEL_PRINT
    // macros when they are defined, because on most configs those do more than
    // the bare Moonraker call - park the head, retract, lift Z, restore state.
    // Calling the endpoint instead would skip all of it. Where the macros are
    // not defined, the Moonraker API is the correct fallback.

    func pausePrint() async {
        await once("pause") {
            if settings.demoMode { demo.pause(); Haptics.impact(.medium); return }
            if let macro = capabilities.macro(named: "PAUSE") {
                await runMacro(macro)
                return
            }
            await run { try await self.moonraker.pausePrint() }
        }
    }

    func resumePrint() async {
        await once("resume") {
            if settings.demoMode { demo.resume(); Haptics.impact(.medium); return }
            if let macro = capabilities.macro(named: "RESUME") {
                await runMacro(macro)
                return
            }
            await run { try await self.moonraker.resumePrint() }
        }
    }

    func cancelPrint() async {
        // Guarded because a second CANCEL_PRINT does not cancel the same print
        // twice - it lands on whatever is running by the time it arrives.
        await once("cancel") {
            if settings.demoMode { demo.cancel(); Haptics.warning(); return }
            if let macro = capabilities.macro(named: "CANCEL_PRINT") {
                await runMacro(macro)
                return
            }
            await run { try await self.moonraker.cancelPrint() }
        }
    }

    func emergencyStop() async {
        Haptics.error()
        if settings.demoMode { demo.emergencyStop(); return }
        await run { try await self.moonraker.emergencyStop() }
        appendConsole(L.t("action.emergency_stop_sent"), kind: .error)
    }

    func restartFirmware() async {
        await once("firmware_restart") {
            if settings.demoMode { demo.firmwareRestart(); return }
            await run { try await self.moonraker.restartFirmware() }
        }
    }

    func restartKlipper() async {
        await once("klipper_restart") {
            if settings.demoMode { demo.firmwareRestart(); return }
            await run { try await self.moonraker.restartKlipper() }
        }
    }

    func restartMoonraker() async {
        await once("moonraker_restart") {
            guard !settings.demoMode else { return }
            await run { try await self.moonraker.restartService("moonraker") }
        }
    }

    private func run(_ operation: @escaping () async throws -> Void) async {
        beginBusy()
        defer { endBusy() }
        do {
            try await operation()
            lastError = nil
        } catch {
            handle(error)
        }
    }

    // MARK: - Busy accounting

    private func beginBusy() {
        busyDepth += 1
        isBusy = true
    }

    private func endBusy() {
        busyDepth = max(0, busyDepth - 1)
        isBusy = busyDepth > 0
    }

    /// Runs `operation` unless a command with the same name is already on its
    /// way, in which case the second call is dropped.
    ///
    /// This is the guard `.disabled(printer.isBusy)` cannot be: the flag reaches
    /// the button one render later than the tap that should have been refused.
    ///
    /// Deliberately not applied to the emergency stop. An extra E-stop costs
    /// nothing and a refused one could cost a printer, so that path stays
    /// unguarded on purpose.
    @discardableResult
    private func once(_ key: String, _ operation: () async -> Void) async -> Bool {
        guard !inFlight.contains(key) else { return false }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        await operation()
        return true
    }

    private func handle(_ error: Error) {
        let apiError = APIError.from(error, host: settings.host)
        lastError = apiError
        appendConsole(apiError.localizedDescription, kind: .error)
        Haptics.error()
    }

    // MARK: - Power

    var powerProvider: PowerProviding {
        if settings.demoMode { return DemoPowerProvider() }
        switch settings.powerProvider {
        case .backend:
            return BackendPowerProvider(client: backend)
        case .moonraker:
            return MoonrakerPowerProvider(client: moonraker, device: settings.moonrakerPowerDevice)
        case .webhook:
            return WebhookPowerProvider(
                onURL: settings.webhookOnURL,
                offURL: settings.webhookOffURL,
                statusURL: settings.webhookStatusURL,
                http: http
            )
        case .demo:
            return DemoPowerProvider()
        case .none:
            return NoPowerProvider()
        }
    }

    var safetyThresholds: PowerSafety.Thresholds {
        PowerSafety.Thresholds(
            maxNozzleTemp: settings.safeNozzleTemp,
            maxBedTemp: settings.safeBedTemp,
            blockWhilePrinting: true
        )
    }

    var powerOffSafety: PowerSafetyReport {
        PowerSafety.evaluatePowerOff(snapshot: snapshot, thresholds: safetyThresholds)
    }

    func refreshPower() async {
        if settings.demoMode {
            power = PowerReading(state: demo.powerState, available: true, provider: .demo, device: "demo-switch")
            return
        }
        do {
            power = try await powerProvider.status()
        } catch {
            power = PowerReading(
                state: .error,
                available: false,
                provider: settings.powerProvider,
                message: APIError.from(error, host: settings.host).localizedDescription
            )
        }
    }

    func powerOn() async {
        beginBusy()
        defer { endBusy() }

        if settings.demoMode {
            demo.setPower(on: true)
            power = PowerReading(state: .on, available: true, provider: .demo, device: "demo-switch")
            Haptics.success()
            return
        }
        do {
            power = try await powerProvider.turnOn()
            lastMessage = L.t("power.turned_on")
            Haptics.success()
        } catch {
            handle(error)
        }
    }

    /// - Parameter force: bypass the hot/printing blockers. The UI only passes
    ///   `true` after the user confirms an explicit warning.
    @discardableResult
    func powerOff(force: Bool) async -> Bool {
        let report = powerOffSafety
        guard report.isSafe || force else {
            lastError = .unsafeOperation(report.blockers)
            Haptics.warning()
            return false
        }

        beginBusy()
        defer { endBusy() }

        if settings.demoMode {
            demo.setPower(on: false)
            power = PowerReading(state: .off, available: true, provider: .demo, device: "demo-switch")
            Haptics.success()
            return true
        }
        do {
            power = try await powerProvider.turnOff(force: force)
            lastMessage = L.t("power.turned_off")
            Haptics.success()
            return true
        } catch {
            handle(error)
            return false
        }
    }

    // MARK: - Conditions

    /// What is currently worth telling the user, derived from live Klipper
    /// objects rather than from log text.
    ///
    /// Recomputed from the snapshot every time it changes, so a condition
    /// disappears the moment its cause is resolved - homing clears the homing
    /// card without anything having to remember to dismiss it.
    var conditions: [PrinterCondition] {
        PrinterConditionEvaluator.conditions(for: conditionInput)
    }

    /// The worst condition, for the single card Home shows.
    var primaryCondition: PrinterCondition? { conditions.first }

    /// Genuine faults only - used where the UI wants to know whether something
    /// is actually wrong, as opposed to merely needing a Home.
    var errorConditions: [PrinterCondition] { conditions.filter(\.isError) }

    private var conditionInput: PrinterConditionEvaluator.Input {
        var input = PrinterConditionEvaluator.Input()
        input.klippy = snapshot.klippy
        input.klippyMessage = snapshot.klippyMessage
        input.homedAxes = snapshot.homedAxes
        input.printState = snapshot.state
        input.printMessage = snapshot.stateMessage
        input.isPrinting = snapshot.isActive
        input.connected = moonrakerConnected
        input.filamentRunoutSensor = snapshot.filamentRunoutSensor
        // Only ask about axes this printer actually has.
        if !capabilities.axisLimits.isEmpty {
            input.configuredAxes = capabilities.axisLimits.keys.sorted()
        }
        return input
    }

    /// Whether a print may start: every configured axis homed and Klipper ready.
    var isReadyToPrint: Bool {
        guard snapshot.klippy == .ready else { return false }
        return PrinterConditionEvaluator.missingAxes(
            homed: snapshot.homedAxes,
            configured: capabilities.axisLimits.isEmpty
                ? ["x", "y", "z"]
                : capabilities.axisLimits.keys.sorted()
        ).isEmpty
    }

    /// Homes the printer, refusing when it would be unsafe.
    ///
    /// G28 goes through `safe_z_home` when the config has it, which is why no
    /// Z coordinate is invented here: Klipper moves to the configured position
    /// itself. The checks are the ones a person would make before pressing the
    /// button - Klipper alive, nothing printing, no shutdown pending.
    ///
    /// This is the **only** public way to home. There used to be an unguarded
    /// `home()` next to it, and it was the one every button in the app called
    /// while the checked version was wired to a single card - the safe path
    /// existed and almost nothing used it.
    @discardableResult
    func home(axes: String = "") async -> Bool {
        guard !settings.demoMode else {
            _ = await sendHome(axes)
            return true
        }
        guard moonrakerConnected || snapshot.isOnline else {
            lastError = .unsafeOperation([L.t("condition.home.not_connected")])
            Haptics.warning()
            return false
        }
        guard snapshot.klippy == .ready else {
            lastError = .unsafeOperation([L.t("condition.home.not_ready")])
            Haptics.warning()
            return false
        }
        guard !snapshot.isActive else {
            lastError = .unsafeOperation([L.t("condition.home.printing")])
            Haptics.warning()
            return false
        }

        let ok = await sendHome(axes)
        // Homing changes homed_axes, and that is what the condition list keys
        // off, so pull a fresh reading rather than waiting for the next poll.
        if ok { await refreshNow() }
        return ok
    }

    /// Tells Klipper where the toolhead is, without homing it.
    ///
    /// The way out of a printer that cannot home. When the probe is dead the
    /// endstop never fires, `G28` fails, and from then on Klipper refuses every
    /// move - so the nozzle cannot be raised off the bed to go and look at the
    /// probe that caused it. That is a machine you cannot touch because the part
    /// that tells you where it is has broken.
    ///
    /// `SET_KINEMATIC_POSITION` breaks the deadlock by asserting a position
    /// rather than measuring one. Klipper then believes it and will move. Which
    /// is exactly why this is not homing and is not offered as homing: the
    /// number is the user's claim, not a measurement, and if it is wrong the
    /// printer will happily drive to a place that does not exist.
    ///
    /// The safety that is left is the one that still means something: the axis
    /// is declared at the *bottom* of its travel, so the only unrestricted
    /// direction is away from the bed.
    @discardableResult
    func assumePosition(x: Double?, y: Double?, z: Double?) async -> Bool {
        guard capabilities.canSetKinematicPosition else {
            lastError = .unsafeOperation([L.t("control.force_move.not_enabled")])
            Haptics.warning()
            return false
        }
        guard !snapshot.isActive else {
            lastError = .unsafeOperation([L.t("condition.home.printing")])
            Haptics.warning()
            return false
        }

        var parts: [String] = ["SET_KINEMATIC_POSITION"]
        if let x { parts.append(String(format: "X=%.3f", x)) }
        if let y { parts.append(String(format: "Y=%.3f", y)) }
        if let z { parts.append(String(format: "Z=%.3f", z)) }
        guard parts.count > 1 else { return false }

        Haptics.impact(.medium)
        let ok = await send(gcode: parts.joined(separator: " "))
        if ok { await refreshNow() }
        return ok
    }

    // MARK: - Capability discovery

    /// Re-reads printer.cfg through Klipper and rebuilds the capability model.
    ///
    /// Called on every Moonraker connect and on every Klipper ready event, so a
    /// printer.cfg edit followed by FIRMWARE_RESTART is picked up without
    /// touching the app. `force` skips the "nothing changed" shortcut.
    func refreshCapabilities(force: Bool = false) {
        guard !settings.demoMode else {
            capabilities = DemoCapabilities.neptune3Plus
            return
        }
        capabilityTask?.cancel()
        capabilityTask = Task { [weak self] in
            await self?.discoverCapabilities(force: force)
        }
    }

    private func discoverCapabilities(force: Bool) async {
        do {
            let discovered = try await moonraker.discoverCapabilities(homedAxes: snapshot.homedAxes)
            guard !Task.isCancelled else { return }
            capabilityError = nil

            // The signature covers every section and option, so an unchanged
            // config re-uses what is already on screen and avoids a needless
            // round of view updates on every reconnect.
            if force || discovered.configSignature != capabilities.configSignature {
                capabilities = discovered
                // The set of objects worth subscribing to changed with it.
                await resubscribe()
                lightLevels = lightLevels.filter { key, _ in
                    discovered.lights.contains { $0.object == key }
                }
                await refreshLights()
            } else {
                capabilities.homedAxes = discovered.homedAxes
            }
        } catch {
            guard !Task.isCancelled else { return }
            capabilityError = APIError.from(error, host: settings.host)
        }
    }

    /// Re-issues the Moonraker subscription so newly discovered objects start
    /// streaming.
    private func resubscribe() async {
        await moonrakerSocket.subscribe(objects: subscriptionObjects)
    }

    /// The objects to subscribe to: the standard set the dashboard decodes, plus
    /// everything discovered on this particular machine.
    var subscriptionObjects: [String] {
        var names = Set(PrinterObjects.queryObjects)
        names.formUnion(capabilities.fans.map(\.object))
        names.formUnion(capabilities.temperatureSensors.map(\.object))
        names.formUnion(capabilities.filamentSensors.map(\.object))
        names.formUnion(capabilities.heaters.map(\.object))
        names.formUnion(capabilities.lights.map(\.object))
        if capabilities.hasBedMesh { names.insert("bed_mesh") }
        if capabilities.hasExcludeObject { names.insert("exclude_object") }
        if capabilities.hasPauseResume { names.insert("pause_resume") }
        if let probe = capabilities.probe { names.insert(probe.kind) }
        // Only ask for objects Klipper actually reported; a subscription to an
        // object that does not exist makes Moonraker reject the whole request.
        let available = Set(capabilities.objects)
        return names.filter { available.isEmpty || available.contains($0) }.sorted()
    }

    // MARK: - Diagnostics

    struct Diagnostics: Equatable {
        var moonrakerReachable: Bool?
        var backendReachable: Bool?
        var websocketConnected: Bool
        var klipperReady: Bool?
        var backendVersion: String?
        var slicerAvailable: Bool?
        var powerProvider: String?
        var moonrakerError: APIError?
        var backendError: APIError?

        // Independent probes. Each of these can pass or fail without saying
        // anything about the others: Moonraker can be up while Klipper is in
        // shutdown, the backend can be up while Moonraker is not, and either
        // WebSocket can fail while the matching HTTP endpoint answers fine.
        var hostReachable: Bool?
        var klippyConnected: Bool?
        var klippyState: String?
        var klipperError: APIError?
        var moonrakerWebSocketConnected: Bool?
        var moonrakerWebSocketError: APIError?
        var backendWebSocketConnected: Bool?
        var backendWebSocketError: APIError?
        /// The socket is only failing because no backend token has been entered
        /// yet - expected during first-run setup, not a fault.
        var backendWebSocketNeedsToken = false

        /// Endpoints actually used, so the diagnostics panel shows the URL that
        /// was tried rather than the one the user assumes was tried.
        var moonrakerURL: String?
        var backendURL: String?
        var moonrakerWebSocketURL: String?
        var backendWebSocketURL: String?
        var usingDirectMoonrakerPort = false
        var atsSummary: String = ""

        /// One-line verdict for the Klipper row, as a localisation key.
        ///
        /// Lives here rather than in the view so that the rule it encodes - a
        /// healthy Moonraker with a stopped Klipper is a *Klipper* problem, not
        /// a connection problem - is testable.
        var klipperVerdictKey: String? {
            guard moonrakerReachable == true else { return "diagnostics.klipper_unknown" }
            if klipperReady == true { return nil }
            if klippyConnected == false { return "diagnostics.moonraker_ok_klipper_down" }
            return "diagnostics.moonraker_ok_klipper_not_ready"
        }

        /// Moonraker being down must never be reported as Klipper being down,
        /// and vice versa.
        var moonrakerVerdictKey: String? {
            if moonrakerReachable == true {
                return usingDirectMoonrakerPort ? "diagnostics.direct_port" : nil
            }
            return moonrakerError == nil ? "diagnostics.moonraker_unreachable" : nil
        }
    }

    func runDiagnostics() async -> Diagnostics {
        var result = Diagnostics(websocketConnected: moonrakerConnected)
        result.atsSummary = ATSPolicy.summary()
        result.backendURL = settings.connection.backendBaseURL?.absoluteString
        result.backendWebSocketURL = settings.connection.backendWebSocketURL?.absoluteString

        // ATS blocks requests before they leave the device, so there is nothing
        // to learn from probing the network - and every result would be a
        // misleading "the Pi is unreachable".
        guard ATSPolicy.allowsPlainHTTP || settings.connection.useHTTPS else {
            result.hostReachable = false
            result.moonrakerReachable = false
            result.backendReachable = false
            result.moonrakerError = .blockedByATS
            result.backendError = .blockedByATS
            return result
        }

        // 1 + 2. Moonraker over HTTP, which doubles as the host reachability
        // check: anything other than a transport failure means packets are
        // getting to the Pi.
        do {
            let info = try await moonraker.serverInfo()
            result.hostReachable = true
            result.moonrakerReachable = true

            // 3. Klipper, reported separately from Moonraker.
            result.klippyConnected = info.klippyConnected
            result.klippyState = info.klippyState
            result.klipperReady = info.klippyConnected && info.klippyState == "ready"
            if !result.klipperReady! {
                result.klipperError = .moonraker(L.t("error.klipper_not_ready"))
            }
        } catch {
            let apiError = APIError.from(error, host: settings.host)
            result.moonrakerReachable = false
            result.moonrakerError = apiError
            // A reply of any kind - 401, 404, malformed JSON - proves the host
            // is up even though Moonraker itself did not answer usefully.
            result.hostReachable = apiError.isTransportFailure ? false : true
        }
        result.moonrakerURL = await moonraker.baseURL?.absoluteString
        result.usingDirectMoonrakerPort = await moonraker.isUsingDirectPort
        result.moonrakerWebSocketURL = moonrakerSocket.activeURL?.absoluteString
            ?? settings.connection.moonrakerWebSocketURL?.absoluteString

        // 4. Backend, independent of everything above.
        do {
            let health = try await backend.health()
            result.backendReachable = true
            result.backendVersion = health.version
            result.slicerAvailable = health.slicerAvailable
            result.powerProvider = health.powerProvider
            backendHealth = health
            if result.hostReachable != true { result.hostReachable = true }
        } catch {
            let apiError = APIError.from(error, host: settings.host)
            result.backendReachable = false
            result.backendError = apiError
            if result.hostReachable == nil, !apiError.isTransportFailure {
                result.hostReachable = true
            }
        }

        // 5. The two WebSockets, each reported on its own.
        result.moonrakerWebSocketConnected = moonrakerConnected
        if !moonrakerConnected, case .failed(let message) = moonrakerSocket.state {
            result.moonrakerWebSocketError = .unknown(message)
        }

        result.backendWebSocketConnected = backendSocket.isConnected
        if !backendSocket.isConnected {
            // The backend leaves /api/health unauthenticated but guards /ws, so
            // a healthy backend with a failing socket is almost always a token
            // that has not been entered yet - which is its own message, not a
            // network failure.
            if backendHealth?.authRequired == true, settings.backendToken.isEmpty {
                result.backendWebSocketError = .unauthorized
                result.backendWebSocketNeedsToken = true
            } else {
                result.backendWebSocketError = backendSocket.lastError
            }
        }

        return result
    }

    // MARK: - Demo helpers

    var isDemo: Bool { settings.demoMode }

    func demoStartPrint(filename: String, estimatedSeconds: Double, layers: Int) {
        demo.startPrint(filename: filename, estimatedSeconds: estimatedSeconds, layers: layers)
    }

    func thumbnailURL(for relativePath: String) -> URL? {
        guard let base = settings.connection.moonrakerBaseURL else { return nil }
        let encoded = relativePath
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relativePath
        return URL(string: "\(base.absoluteString)/server/files/gcodes/\(encoded)")
    }
}
