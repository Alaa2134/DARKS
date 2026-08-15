import Foundation

/// Normalised, view-ready printer state. Everything the dashboard renders comes
/// from here, so the views never touch raw Moonraker JSON.
struct PrinterSnapshot: Equatable {
    var isOnline: Bool = false
    var klippy: KlippyState = .unknown
    var klippyMessage: String = ""
    var state: PrinterState = .unknown
    var stateMessage: String = ""
    /// Whatever M117 last put on the printer's display.
    ///
    /// The only channel a running G-code file has for saying something to a
    /// person, and the colour-change stops use it: the message names the colour
    /// the printer is standing still waiting for.
    var displayMessage: String = ""

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

    /// Filament sensors this machine reports, keyed by short name. Empty on a
    /// printer that has none - never assumed to exist.
    var filamentSensors: [String: BackendFilamentSensor] = [:]

    /// The backend's worked-out remaining time, with its reasoning. Nil when
    /// talking to Moonraker directly, or when the backend has too little
    /// evidence to answer yet - which it says rather than guessing.
    var estimate: PrintEstimate?

    // MARK: - Derived

    /// A sensor that is switched on and currently seeing no filament.
    ///
    /// Klipper's `pause_on_runout` turns this into a PAUSE, which on its own is
    /// indistinguishable from someone tapping pause - so the sensor state is
    /// what the UI reads, not the pause.
    var filamentRunoutSensor: BackendFilamentSensor? {
        filamentSensors.values.first { $0.enabled && !$0.filamentDetected }
    }

    var hasFilamentRunout: Bool { filamentRunoutSensor != nil }

    var isPrinting: Bool { state == .printing }
    var isPaused: Bool { state == .paused }
    var isActive: Bool { state.isActive }
    var isReady: Bool { klippy == .ready }

    /// How long ago this reading arrived.
    var age: TimeInterval { Date().timeIntervalSince(lastUpdate) }

    /// Beyond this, a reading is history rather than telemetry.
    ///
    /// The socket pushes on change and the poll runs every four seconds, so a
    /// gap this long means neither is getting through.
    static let staleAfter: TimeInterval = 20

    /// Whether these numbers are old enough that showing them as live would be
    /// a lie.
    ///
    /// `lastUpdate` was being stamped in six places and read in none, so when
    /// the connection dropped the app kept displaying the last temperatures it
    /// had - indefinitely, and indistinguishably from live ones. A bed reading
    /// three minutes old looks exactly like a bed reading one second old, and
    /// the difference is whether it is safe to reach into the machine.
    var isStale: Bool {
        lastUpdate != .distantPast && age > Self.staleAfter
    }

    var isHot: Bool { nozzleActual > 40 || bedActual > 35 }

    var hasHomedAll: Bool {
        let axes = homedAxes.lowercased()
        return axes.contains("x") && axes.contains("y") && axes.contains("z")
    }

    func isHomed(_ axis: String) -> Bool {
        homedAxes.lowercased().contains(axis.lowercased())
    }

    /// How long is left.
    ///
    /// The backend's estimate when there is one: it has the slicer's own
    /// figure from the G-code metadata, a correction factor learned from this
    /// printer's completed prints, and the filament total, none of which the
    /// phone has. This used to compute `printDuration / progress` locally and
    /// ignore all of that - the same formula the backend had already been
    /// fixed to stop using, kept alive in a second place.
    ///
    /// The local fallback stays for the Moonraker-direct path, where no
    /// backend is in the picture at all. It is deliberately silent below 8 %
    /// rather than dividing by a byte count during the warm-up, which is what
    /// produced "3 days remaining" thirty seconds into a print.
    var estimatedTimeLeft: TimeInterval? {
        if let backend = estimate?.remainingSeconds { return backend }
        guard isActive, progress > 0.08, printDuration > 0 else { return nil }
        let total = printDuration / progress
        return max(0, total - printDuration)
    }

    /// Where the number above came from, when the backend supplied it.
    var estimateMethodText: String? {
        guard let estimate, estimate.remainingSeconds != nil else { return nil }
        return L.isArabic ? estimate.methodAR : estimate.methodEN
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

        snapshot.displayMessage = objects.displayStatus?.message ?? ""

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

        // `errorMessage` carries Klipper's own words and nothing else. It used
        // to be filled in with a generic "not ready" string whenever Klipper was
        // not ready, which is how a routine startup or an unhomed axis ended up
        // presented as a fault. Classification now belongs to
        // PrinterConditionEvaluator, which reads live objects; this field is
        // only the raw text it shows under technical details.
        if snapshot.klippy == .shutdown || snapshot.klippy == .error {
            snapshot.errorMessage = snapshot.klippyMessage.isEmpty
                ? nil
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
