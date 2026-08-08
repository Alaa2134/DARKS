import Foundation

/// Normalised, view-ready printer state. Everything the dashboard renders comes
/// from here, so the views never touch raw Moonraker JSON.
struct PrinterSnapshot: Equatable {
    var isOnline: Bool = false
    var klippy: KlippyState = .unknown
    var klippyMessage: String = ""
    var state: PrinterState = .unknown
    var stateMessage: String = ""

    var filename: String = ""
    var progress: Double = 0
    var printDuration: TimeInterval = 0
    var totalDuration: TimeInterval = 0
    var filamentUsedMM: Double = 0

    var nozzleActual: Double = 0
    var nozzleTarget: Double = 0
    var nozzlePower: Double = 0
    var bedActual: Double = 0
    var bedTarget: Double = 0
    var bedPower: Double = 0

    var position: [Double] = [0, 0, 0]
    var gcodePosition: [Double] = [0, 0, 0]
    var homedAxes: String = ""

    var speed: Double = 0            // mm/min, as reported by gcode_move
    var speedFactor: Double = 1
    var extrudeFactor: Double = 1
    var fanSpeed: Double = 0

    var maxVelocity: Double = 0
    var maxAcceleration: Double = 0
    var squareCornerVelocity: Double = 0

    var currentLayer: Int?
    var totalLayer: Int?

    var thumbnailPath: String?
    var lastUpdate: Date = .distantPast
    var errorMessage: String?

    // MARK: - Derived

    var isPrinting: Bool { state == .printing }
    var isPaused: Bool { state == .paused }
    var isActive: Bool { state.isActive }
    var isReady: Bool { klippy == .ready }

    var isHot: Bool { nozzleActual > 40 || bedActual > 35 }

    var hasHomedAll: Bool {
        let axes = homedAxes.lowercased()
        return axes.contains("x") && axes.contains("y") && axes.contains("z")
    }

    func isHomed(_ axis: String) -> Bool {
        homedAxes.lowercased().contains(axis.lowercased())
    }

    /// Remaining time estimated from elapsed print time and file progress
    /// (the same approach Mainsail and Fluidd use - Klipper itself has none).
    var estimatedTimeLeft: TimeInterval? {
        guard isActive, progress > 0.02, printDuration > 0 else { return nil }
        let total = printDuration / progress
        return max(0, total - printDuration)
    }

    var estimatedFinishDate: Date? {
        guard let remaining = estimatedTimeLeft else { return nil }
        return Date().addingTimeInterval(remaining)
    }

    var x: Double { position.count > 0 ? position[0] : 0 }
    var y: Double { position.count > 1 ? position[1] : 0 }
    var z: Double { position.count > 2 ? position[2] : 0 }

    var printSpeedMMPerSecond: Double { speed / 60.0 }

    /// Cold-extrusion guard: Klipper refuses extrusion below min_extrude_temp.
    func canExtrude(minimumTemperature: Double) -> Bool {
        nozzleActual >= minimumTemperature
    }

    var widgetSnapshot: PrinterWidgetSnapshot {
        PrinterWidgetSnapshot(
            printerName: SharedStore.defaults.string(forKey: "printerName") ?? "Neptune 3 Plus",
            isOnline: isOnline,
            state: state,
            klippy: klippy,
            power: .unknown,
            filename: filename,
            progress: progress,
            nozzleActual: nozzleActual,
            nozzleTarget: nozzleTarget,
            bedActual: bedActual,
            bedTarget: bedTarget,
            estimatedRemaining: estimatedTimeLeft,
            updatedAt: Date()
        )
    }

    // MARK: - Construction

    static func offline(error: String?) -> PrinterSnapshot {
        var snapshot = PrinterSnapshot()
        snapshot.isOnline = false
        snapshot.klippy = .disconnected
        snapshot.state = .unknown
        snapshot.errorMessage = error
        snapshot.lastUpdate = Date()
        return snapshot
    }

    /// Build from a Moonraker objects payload plus the server info envelope.
    static func make(objects: PrinterObjects, serverInfo: MoonrakerServerInfo?) -> PrinterSnapshot {
        var snapshot = PrinterSnapshot()
        snapshot.isOnline = true
        snapshot.lastUpdate = Date()

        let webhookState = objects.webhooks?.state
        snapshot.klippy = KlippyState(raw: webhookState ?? serverInfo?.klippyState)
        snapshot.klippyMessage = objects.webhooks?.stateMessage ?? ""

        if let stats = objects.printStats {
            snapshot.state = PrinterState(moonraker: stats.state)
            snapshot.stateMessage = stats.message ?? ""
            snapshot.filename = stats.filename ?? ""
            snapshot.printDuration = stats.printDuration ?? 0
            snapshot.totalDuration = stats.totalDuration ?? 0
            snapshot.filamentUsedMM = stats.filamentUsed ?? 0
            snapshot.currentLayer = stats.info?.currentLayer
            snapshot.totalLayer = stats.info?.totalLayer
        }

        if let progress = objects.displayStatus?.progress {
            snapshot.progress = min(max(progress, 0), 1)
        } else if let progress = objects.virtualSDCard?.progress {
            snapshot.progress = min(max(progress, 0), 1)
        }

        if let extruder = objects.extruder {
            snapshot.nozzleActual = extruder.temperature ?? 0
            snapshot.nozzleTarget = extruder.target ?? 0
            snapshot.nozzlePower = extruder.power ?? 0
        }
        if let bed = objects.heaterBed {
            snapshot.bedActual = bed.temperature ?? 0
            snapshot.bedTarget = bed.target ?? 0
            snapshot.bedPower = bed.power ?? 0
        }

        if let toolhead = objects.toolhead {
            snapshot.position = Array((toolhead.position ?? []).prefix(3))
            while snapshot.position.count < 3 { snapshot.position.append(0) }
            snapshot.homedAxes = toolhead.homedAxes ?? ""
            snapshot.maxVelocity = toolhead.maxVelocity ?? 0
            snapshot.maxAcceleration = toolhead.maxAccel ?? 0
            snapshot.squareCornerVelocity = toolhead.squareCornerVelocity ?? 0
        }

        if let move = objects.gcodeMove {
            snapshot.speed = move.speed ?? 0
            snapshot.speedFactor = move.speedFactor ?? 1
            snapshot.extrudeFactor = move.extrudeFactor ?? 1
            snapshot.gcodePosition = Array((move.gcodePosition ?? []).prefix(3))
            while snapshot.gcodePosition.count < 3 { snapshot.gcodePosition.append(0) }
        }

        snapshot.fanSpeed = objects.fan?.speed ?? 0

        if snapshot.klippy == .shutdown || snapshot.klippy == .error {
            snapshot.errorMessage = snapshot.klippyMessage.isEmpty
                ? L.t("error.klipper_not_ready")
                : snapshot.klippyMessage
        }

        return snapshot
    }
}

/// One temperature sample used by the charts.
struct TemperatureSample: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let nozzle: Double
    let nozzleTarget: Double
    let bed: Double
    let bedTarget: Double
}
