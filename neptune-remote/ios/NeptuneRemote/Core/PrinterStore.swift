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

    @Published private(set) var moonrakerConnected = false
    @Published private(set) var backendConnected = false
    @Published private(set) var backendHealth: BackendHealth?
    @Published private(set) var power = PowerReading.unavailable
    @Published private(set) var isBusy = false

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
        } catch {
            let apiError = APIError.from(error, host: settings.host)
            update(snapshot: .offline(error: apiError.localizedDescription))
            lastError = apiError
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

    func home(_ axes: String = "") async {
        Haptics.impact(.medium)
        await send(gcode: axes.isEmpty ? "G28" : "G28 \(axes.uppercased())")
    }

    func jog(axis: String, distance: Double, feedrate: Double) async {
        Haptics.impact(.light)
        // Relative move, then restore absolute positioning (Klipper style).
        await send(gcode: "G91", echo: false)
        await send(gcode: String(format: "G1 %@%.3f F%.0f", axis.uppercased(), distance, feedrate))
        await send(gcode: "G90", echo: false)
    }

    func disableSteppers() async {
        await send(gcode: "M84")
    }

    /// Cold extrusion is refused unless the user explicitly overrides it.
    func extrude(length: Double, speedMMPerSecond: Double) async -> Bool {
        if !settings.allowColdExtrusion,
           !snapshot.canExtrude(minimumTemperature: settings.minExtrusionTemp) {
            lastError = .unknown(L.t("control.cold_extrusion_blocked", settings.minExtrusionTemp))
            Haptics.warning()
            return false
        }
        Haptics.impact(.light)
        await send(gcode: "M83", echo: false)
        let ok = await send(gcode: String(format: "G1 E%.2f F%.0f", length, speedMMPerSecond * 60))
        return ok
    }

    // MARK: Temperature

    func setNozzleTarget(_ temperature: Double) async {
        await send(gcode: String(format: "M104 S%.0f", max(0, temperature)))
    }

    func setBedTarget(_ temperature: Double) async {
        await send(gcode: String(format: "M140 S%.0f", max(0, temperature)))
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

    func startPrint(filename: String) async {
        isBusy = true
        defer { isBusy = false }

        if settings.demoMode {
            demo.startPrint(filename: filename)
            Haptics.success()
            return
        }
        do {
            try await moonraker.startPrint(filename: filename)
            lastMessage = L.t("print.started", filename)
            Haptics.success()
        } catch {
            handle(error)
        }
    }

    func pausePrint() async {
        if settings.demoMode { demo.pause(); Haptics.impact(.medium); return }
        await run { try await self.moonraker.pausePrint() }
    }

    func resumePrint() async {
        if settings.demoMode { demo.resume(); Haptics.impact(.medium); return }
        await run { try await self.moonraker.resumePrint() }
    }

    func cancelPrint() async {
        if settings.demoMode { demo.cancel(); Haptics.warning(); return }
        await run { try await self.moonraker.cancelPrint() }
    }

    func emergencyStop() async {
        Haptics.error()
        if settings.demoMode { demo.emergencyStop(); return }
        await run { try await self.moonraker.emergencyStop() }
        appendConsole(L.t("action.emergency_stop_sent"), kind: .error)
    }

    func restartFirmware() async {
        if settings.demoMode { demo.firmwareRestart(); return }
        await run { try await self.moonraker.restartFirmware() }
    }

    func restartKlipper() async {
        if settings.demoMode { demo.firmwareRestart(); return }
        await run { try await self.moonraker.restartKlipper() }
    }

    func restartMoonraker() async {
        guard !settings.demoMode else { return }
        await run { try await self.moonraker.restartService("moonraker") }
    }

    private func run(_ operation: @escaping () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await operation()
            lastError = nil
        } catch {
            handle(error)
        }
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
        isBusy = true
        defer { isBusy = false }

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

        isBusy = true
        defer { isBusy = false }

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
