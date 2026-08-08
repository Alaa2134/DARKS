import Foundation

/// Physically plausible printer simulation so the whole app can be used in the
/// Xcode simulator with no Raspberry Pi, no Klipper and no printer.
@MainActor
final class DemoSimulator {

    private(set) var snapshot: PrinterSnapshot
    private(set) var consoleLines: [String] = []

    private var timer: Task<Void, Never>?
    private var tick: Double = 0
    private var totalPrintSeconds: Double = 45 * 60
    private var isPoweredOn = true

    var onUpdate: ((PrinterSnapshot) -> Void)?
    var onConsole: ((String) -> Void)?
    var onEvent: ((String, String) -> Void)?

    init() {
        var initial = PrinterSnapshot()
        initial.isOnline = true
        initial.klippy = .ready
        initial.state = .standby
        initial.nozzleActual = 24.5
        initial.bedActual = 23.8
        initial.position = [160, 160, 0]
        initial.gcodePosition = [160, 160, 0]
        initial.homedAxes = ""
        initial.maxVelocity = 300
        initial.maxAcceleration = 3000
        initial.squareCornerVelocity = 5
        initial.lastUpdate = Date()
        snapshot = initial
    }

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.step() }
            }
        }
        log("Demo mode active - no printer is connected")
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - Simulation

    private func step() {
        tick += 1
        guard isPoweredOn else {
            snapshot.isOnline = false
            snapshot.klippy = .disconnected
            snapshot.state = .unknown
            snapshot.lastUpdate = Date()
            onUpdate?(snapshot)
            return
        }

        snapshot.isOnline = true
        snapshot.klippy = .ready

        approachTemperature(&snapshot.nozzleActual, target: snapshot.nozzleTarget, ambient: 24.5, rate: 3.2)
        approachTemperature(&snapshot.bedActual, target: snapshot.bedTarget, ambient: 23.8, rate: 0.9)

        if snapshot.state == .printing {
            snapshot.printDuration += 1
            snapshot.totalDuration += 1
            snapshot.progress = min(1.0, snapshot.printDuration / totalPrintSeconds)
            snapshot.filamentUsedMM += 1.8
            snapshot.fanSpeed = 1.0

            let layers = snapshot.totalLayer ?? 240
            snapshot.currentLayer = max(1, Int(snapshot.progress * Double(layers)))

            // Gentle motion so the coordinate readout looks alive.
            let angle = tick / 8
            snapshot.position = [
                160 + 45 * cos(angle),
                160 + 45 * sin(angle),
                0.2 + Double(snapshot.currentLayer ?? 1) * 0.2
            ]
            snapshot.gcodePosition = snapshot.position
            snapshot.speed = 3600 * snapshot.speedFactor

            if snapshot.progress >= 1.0 {
                finishPrint()
            }
        } else if snapshot.state == .paused {
            snapshot.totalDuration += 1
            snapshot.speed = 0
        }

        snapshot.lastUpdate = Date()
        onUpdate?(snapshot)
    }

    private func approachTemperature(_ value: inout Double, target: Double, ambient: Double, rate: Double) {
        let goal = target > 0 ? target : ambient
        let delta = goal - value
        if abs(delta) < 0.15 {
            value = goal
            return
        }
        // Heating is faster than passive cooling, like a real machine.
        let step = delta > 0 ? rate : rate * 0.35
        value += max(-step, min(step, delta)) + Double.random(in: -0.06...0.06)
    }

    private func finishPrint() {
        snapshot.state = .complete
        snapshot.progress = 1
        snapshot.nozzleTarget = 0
        snapshot.bedTarget = 0
        snapshot.speed = 0
        snapshot.fanSpeed = 0
        log("Print finished: \(snapshot.filename)")
        onEvent?("print_finished", snapshot.filename)
    }

    // MARK: - Commands

    func handle(gcode: String) {
        let command = gcode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        log("> \(gcode)")

        if command.hasPrefix("G28") {
            let axes = command.replacingOccurrences(of: "G28", with: "").trimmingCharacters(in: .whitespaces)
            snapshot.homedAxes = axes.isEmpty ? "xyz" : axes.lowercased().filter { "xyz".contains($0) }
            snapshot.position = [160, 160, 5]
            log("// Homing complete (\(snapshot.homedAxes))")
        } else if command.hasPrefix("M104") || command.hasPrefix("M109") {
            snapshot.nozzleTarget = value(in: command, prefix: "S") ?? snapshot.nozzleTarget
            log("// Nozzle target \(Int(snapshot.nozzleTarget))C")
        } else if command.hasPrefix("M140") || command.hasPrefix("M190") {
            snapshot.bedTarget = value(in: command, prefix: "S") ?? snapshot.bedTarget
            log("// Bed target \(Int(snapshot.bedTarget))C")
        } else if command.hasPrefix("M106") {
            let raw = value(in: command, prefix: "S") ?? 255
            snapshot.fanSpeed = min(1, max(0, raw / 255))
        } else if command.hasPrefix("M107") {
            snapshot.fanSpeed = 0
        } else if command.hasPrefix("M220") {
            snapshot.speedFactor = (value(in: command, prefix: "S") ?? 100) / 100
        } else if command.hasPrefix("M221") {
            snapshot.extrudeFactor = (value(in: command, prefix: "S") ?? 100) / 100
        } else if command == "TURN_OFF_HEATERS" || command.hasPrefix("M84") {
            snapshot.nozzleTarget = 0
            snapshot.bedTarget = 0
            if command.hasPrefix("M84") { snapshot.homedAxes = "" }
        } else if command.hasPrefix("SET_VELOCITY_LIMIT") {
            if let velocity = value(in: command, prefix: "VELOCITY=") { snapshot.maxVelocity = velocity }
            if let accel = value(in: command, prefix: "ACCEL=") { snapshot.maxAcceleration = accel }
            if let scv = value(in: command, prefix: "SQUARE_CORNER_VELOCITY=") {
                snapshot.squareCornerVelocity = scv
            }
        } else if command.hasPrefix("G1") || command.hasPrefix("G0") {
            applyMove(command)
        } else {
            log("// ok")
        }

        snapshot.lastUpdate = Date()
        onUpdate?(snapshot)
    }

    private func applyMove(_ command: String) {
        var position = snapshot.position
        while position.count < 3 { position.append(0) }
        if let x = value(in: command, prefix: "X") { position[0] = x }
        if let y = value(in: command, prefix: "Y") { position[1] = y }
        if let z = value(in: command, prefix: "Z") { position[2] = z }
        snapshot.position = position
        snapshot.gcodePosition = position
        log("// ok")
    }

    private func value(in command: String, prefix: String) -> Double? {
        guard let range = command.range(of: prefix) else { return nil }
        let rest = command[range.upperBound...]
        let token = rest.prefix { "0123456789.-".contains($0) }
        return Double(token)
    }

    // MARK: - Print control

    func startPrint(filename: String, estimatedSeconds: Double = 45 * 60, layers: Int = 240) {
        snapshot.filename = filename
        snapshot.state = .printing
        snapshot.progress = 0
        snapshot.printDuration = 0
        snapshot.totalDuration = 0
        snapshot.filamentUsedMM = 0
        snapshot.currentLayer = 1
        snapshot.totalLayer = layers
        snapshot.nozzleTarget = 210
        snapshot.bedTarget = 60
        snapshot.homedAxes = "xyz"
        totalPrintSeconds = max(60, estimatedSeconds)
        log("Started print: \(filename)")
        onEvent?("print_started", filename)
        onUpdate?(snapshot)
    }

    func pause() {
        guard snapshot.state == .printing else { return }
        snapshot.state = .paused
        log("Print paused")
        onEvent?("print_paused", snapshot.filename)
        onUpdate?(snapshot)
    }

    func resume() {
        guard snapshot.state == .paused else { return }
        snapshot.state = .printing
        log("Print resumed")
        onEvent?("print_resumed", snapshot.filename)
        onUpdate?(snapshot)
    }

    func cancel() {
        guard snapshot.state.isActive else { return }
        snapshot.state = .cancelled
        snapshot.nozzleTarget = 0
        snapshot.bedTarget = 0
        snapshot.progress = 0
        log("Print cancelled")
        onEvent?("print_failed", snapshot.filename)
        onUpdate?(snapshot)
    }

    func emergencyStop() {
        snapshot.klippy = .shutdown
        snapshot.state = .error
        snapshot.stateMessage = "Emergency stop requested (demo)"
        snapshot.nozzleTarget = 0
        snapshot.bedTarget = 0
        log("!! Emergency stop - firmware restart required")
        onEvent?("klipper_error", "Emergency stop")
        onUpdate?(snapshot)
    }

    func firmwareRestart() {
        snapshot.klippy = .ready
        snapshot.state = .standby
        snapshot.stateMessage = ""
        snapshot.homedAxes = ""
        log("// Firmware restarted")
        onUpdate?(snapshot)
    }

    // MARK: - Power

    func setPower(on: Bool) {
        isPoweredOn = on
        if !on {
            snapshot.state = .unknown
            snapshot.nozzleTarget = 0
            snapshot.bedTarget = 0
        } else {
            snapshot.state = .standby
            snapshot.klippy = .ready
        }
        log(on ? "Printer powered on (demo)" : "Printer powered off (demo)")
        onUpdate?(snapshot)
    }

    var powerState: PowerState { isPoweredOn ? .on : .off }

    // MARK: - Console

    private func log(_ line: String) {
        consoleLines.append(line)
        if consoleLines.count > 400 { consoleLines.removeFirst(consoleLines.count - 400) }
        onConsole?(line)
    }

    /// Sample files shown in Demo Mode.
    static let demoGCodes: [BackendGCodeFile] = [
        BackendGCodeFile(
            path: "benchy.gcode", filename: "benchy.gcode", size: 4_312_000,
            modified: Date().addingTimeInterval(-3_600).timeIntervalSince1970,
            estimatedTime: 5_053, filamentTotalMM: 4_321, filamentWeightG: 12.9,
            layerHeight: 0.2, firstLayerHeight: 0.24, objectHeight: 48,
            filamentType: "PLA", filamentName: "Generic PLA", slicer: "PrusaSlicer",
            thumbnailPath: nil, layerCount: 240, source: "demo"
        ),
        BackendGCodeFile(
            path: "calibration_cube.gcode", filename: "calibration_cube.gcode", size: 812_000,
            modified: Date().addingTimeInterval(-86_400).timeIntervalSince1970,
            estimatedTime: 1_820, filamentTotalMM: 1_140, filamentWeightG: 3.4,
            layerHeight: 0.2, firstLayerHeight: 0.24, objectHeight: 20,
            filamentType: "PETG", filamentName: "Generic PETG", slicer: "PrusaSlicer",
            thumbnailPath: nil, layerCount: 100, source: "demo"
        ),
        BackendGCodeFile(
            path: "phone_stand.gcode", filename: "phone_stand.gcode", size: 9_140_000,
            modified: Date().addingTimeInterval(-172_800).timeIntervalSince1970,
            estimatedTime: 14_400, filamentTotalMM: 18_900, filamentWeightG: 56.4,
            layerHeight: 0.28, firstLayerHeight: 0.3, objectHeight: 132,
            filamentType: "PLA", filamentName: "Generic PLA", slicer: "PrusaSlicer",
            thumbnailPath: nil, layerCount: 471, source: "demo"
        )
    ]

    static let demoModels: [BackendModelFile] = [
        BackendModelFile(id: "demo-benchy", filename: "3DBenchy.stl", size: 11_500_000,
                         modified: Date().addingTimeInterval(-7_200).timeIntervalSince1970, fileExtension: ".stl"),
        BackendModelFile(id: "demo-cube", filename: "calibration_cube.stl", size: 684_000,
                         modified: Date().addingTimeInterval(-90_000).timeIntervalSince1970, fileExtension: ".stl")
    ]
}
