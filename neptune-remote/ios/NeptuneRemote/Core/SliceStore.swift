import Foundation

/// Drives the mobile slicing workflow: upload a model, pick parameters, run the
/// real slicer on the Raspberry Pi, follow progress, then print the result.
@MainActor
final class SliceStore: ObservableObject {

    @Published private(set) var profiles = BackendProfiles.empty
    @Published private(set) var slicerInfo: BackendSlicerInfo?
    @Published private(set) var job: SliceJob?
    @Published private(set) var progress: Double = 0
    @Published private(set) var stage: String = ""
    @Published private(set) var logs: [String] = []
    @Published private(set) var isSlicing = false
    @Published var lastError: APIError?

    // Slicing form state
    @Published var selectedModel: BackendModelFile?
    /// Extra models sharing the plate with `selectedModel`, in the order they
    /// were picked. One G-code file, one heat-up, one purge - and one failure
    /// that takes all of them, which the screen says out loud.
    @Published var plateModels: [BackendModelFile] = []
    /// Copies of everything on the plate.
    @Published var copies: Int = 1
    @Published var printerProfile = "neptune3plus_0.4"
    @Published var filamentProfile = "pla"
    @Published var printProfile = "standard"
    /// A print mode, when one was chosen. The backend expands it into layer
    /// height, walls, infill, speeds and acceleration - resolved against this
    /// nozzle and this material - so the app sends one word instead of eleven
    /// fields, and any field set explicitly still wins.
    @Published var mode: String?
    @Published var layerHeight: Double = 0.2
    @Published var infill: Int = 20
    @Published var perimeters: Int = 3
    @Published var supports = false
    @Published var supportStyle = "grid"
    /// Where support may start from. This is the choice that changes how the
    /// part comes out: support growing off the model itself marks whatever
    /// surface it stood on, and no support *style* fixes that.
    @Published var supportPlacement = "everywhere"
    /// Overhangs steeper than this get support. 0 means "leave the slicer's
    /// own threshold alone" rather than "support nothing".
    @Published var supportThresholdAngle: Int = 0
    @Published var adhesion = "skirt"
    @Published var nozzleTemperature: Int = 205
    @Published var bedTemperature: Int = 60
    @Published var overrideTemperatures = false
    @Published var retractionLength: Double = 1.0
    @Published var retractionZHop: Double = 0

    /// Every one of these is optional to the backend, and the sentinel that
    /// means "leave it alone" is deliberate rather than lazy: sending a value
    /// the user never chose overrides the printer profile silently, and the
    /// profile is usually right. Zero here is "the profile decides", not
    /// "none" - which is why the screen labels it rather than showing 0.
    @Published var infillPattern = ""
    @Published var topSolidLayers: Int = 0
    @Published var bottomSolidLayers: Int = 0
    @Published var ironing = false
    @Published var seamPosition = ""
    @Published var spiralVase = false
    @Published var supportZDistance: Double = 0
    @Published var supportInterfaceLayers: Int = 0
    @Published var fanMinPercent: Int = 0
    @Published var fanMaxPercent: Int = 0
    @Published var disableFanFirstLayers: Int = 0
    @Published var avoidCrossingPerimeters = false
    @Published var customOverrides: [String: String] = [:]
    @Published var uploadToPrinter = true
    @Published var startPrintAfterSlicing = false

    private let settings: AppSettings
    private let printer: PrinterStore
    private var pollTask: Task<Void, Never>?

    init(settings: AppSettings, printer: PrinterStore) {
        self.settings = settings
        self.printer = printer
    }

    // MARK: - Profiles

    func loadProfiles() async {
        if settings.demoMode {
            profiles = Self.demoProfiles
            slicerInfo = BackendSlicerInfo(
                engine: "prusaslicer",
                binary: "prusa-slicer",
                resolvedBinary: "/usr/bin/prusa-slicer",
                available: true,
                version: "PrusaSlicer 2.7.4 (demo)",
                profilesDir: "/opt/neptune-remote/profiles"
            )
            return
        }
        do {
            profiles = try await printer.backend.profiles()
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
        slicerInfo = try? await printer.backend.slicerInfo()
    }

    var isSlicerAvailable: Bool {
        slicerInfo?.available ?? (printer.backendHealth?.slicerAvailable ?? false)
    }

    /// Apply the defaults from the selected profiles into the form.
    func applyProfileDefaults() {
        if let profile = profiles.prints.first(where: { $0.id == printProfile }) {
            if let value = profile.values["layer_height"].flatMap(Double.init) { layerHeight = value }
            if let value = profile.values["perimeters"].flatMap(Int.init) { perimeters = value }
            if let raw = profile.values["fill_density"]?.replacingOccurrences(of: "%", with: ""),
               let value = Int(raw) {
                infill = value
            }
        }
        if let profile = profiles.filaments.first(where: { $0.id == filamentProfile }) {
            if let value = profile.values["temperature"].flatMap(Int.init) { nozzleTemperature = value }
            if let value = profile.values["bed_temperature"].flatMap(Int.init) { bedTemperature = value }
        }
    }

    func apply(preset: SlicePreset) {
        printerProfile = preset.printerProfile
        filamentProfile = preset.filamentProfile
        printProfile = preset.printProfile
        layerHeight = preset.layerHeight
        infill = preset.infill
        supports = preset.supports
        adhesion = preset.adhesion
        applyProfileDefaults()
    }

    // MARK: - Request

    var request: SliceRequestPayload? {
        guard let model = selectedModel else { return nil }
        var payload = SliceRequestPayload(modelID: model.id)
        payload.extraModelIDs = plateModels.map(\.id).filter { $0 != model.id }
        payload.copies = max(1, copies)
        payload.mode = mode
        payload.printerProfile = printerProfile
        payload.filamentProfile = filamentProfile
        payload.printProfile = printProfile
        payload.layerHeight = layerHeight
        payload.infillPercent = infill
        payload.perimeters = perimeters
        payload.supports = supports
        payload.supportStyle = supports ? supportStyle : nil
        payload.supportPlacement = supports ? supportPlacement : nil
        payload.supportThresholdAngle = (supports && supportThresholdAngle > 0)
            ? supportThresholdAngle
            : nil
        payload.adhesion = adhesion
        payload.retractionLength = retractionLength
        payload.retractionZHop = retractionZHop > 0 ? retractionZHop : nil
        payload.infillPattern = infillPattern.isEmpty ? nil : infillPattern
        payload.topSolidLayers = topSolidLayers > 0 ? topSolidLayers : nil
        payload.bottomSolidLayers = bottomSolidLayers > 0 ? bottomSolidLayers : nil
        payload.ironing = ironing ? true : nil
        payload.seamPosition = seamPosition.isEmpty ? nil : seamPosition
        payload.spiralVase = spiralVase ? true : nil
        payload.supportZDistance = (supports && supportZDistance > 0) ? supportZDistance : nil
        payload.supportInterfaceLayers = (supports && supportInterfaceLayers > 0)
            ? supportInterfaceLayers
            : nil
        payload.fanMinPercent = fanMinPercent > 0 ? fanMinPercent : nil
        payload.fanMaxPercent = fanMaxPercent > 0 ? fanMaxPercent : nil
        payload.disableFanFirstLayers = disableFanFirstLayers > 0 ? disableFanFirstLayers : nil
        payload.avoidCrossingPerimeters = avoidCrossingPerimeters ? true : nil
        payload.customOverrides = customOverrides
        payload.uploadToMoonraker = uploadToPrinter
        payload.startPrintAfterUpload = false // never auto-start; the user confirms

        if overrideTemperatures {
            payload.nozzleTemperature = nozzleTemperature
            payload.bedTemperature = bedTemperature
            payload.firstLayerNozzleTemperature = nozzleTemperature + 5
            payload.firstLayerBedTemperature = bedTemperature
        }
        payload.outputName = (model.filename as NSString).deletingPathExtension + ".gcode"
        return payload
    }

    // MARK: - Slicing

    func startSlicing() async {
        guard let payload = request else {
            lastError = .unknown(L.t("slicer.no_model"))
            return
        }
        guard !settings.demoMode else {
            await runDemoSlice(payload: payload)
            return
        }

        isSlicing = true
        progress = 0
        stage = L.t("slicer.stage.queued")
        logs = []
        lastError = nil

        do {
            let created = try await printer.backend.startSlice(payload)
            job = created
            pollJob(id: created.id)
        } catch {
            isSlicing = false
            lastError = APIError.from(error, host: settings.host)
            Haptics.error()
        }
    }

    /// The backend also pushes progress over the WebSocket; polling keeps the UI
    /// correct if that socket drops mid-slice.
    private func pollJob(id: String) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let current = try await self.printer.backend.sliceJob(id: id)
                    self.apply(job: current)
                    if current.isFinished { return }
                } catch {
                    self.lastError = APIError.from(error, host: self.settings.host)
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    func apply(job current: SliceJob) {
        job = current
        progress = current.progress
        stage = current.stage
        if !current.logs.isEmpty { logs = current.logs }
        isSlicing = current.isRunning

        if current.status == "failed" {
            lastError = .unknown(current.error ?? L.t("slicer.failed"))
            Haptics.error()
        } else if current.status == "done" {
            Haptics.success()
        }
    }

    /// Called by the backend WebSocket for live progress.
    func apply(progressEvent event: BackendSocket.SliceProgress) {
        guard job?.id == event.id || job == nil else { return }
        progress = event.progress
        stage = event.stage
        isSlicing = event.status == "running" || event.status == "queued"
        if !event.logTail.isEmpty {
            logs.append(contentsOf: event.logTail.filter { !logs.contains($0) })
            if logs.count > 400 { logs.removeFirst(logs.count - 400) }
        }
        if event.status == "failed", let error = event.error {
            lastError = .unknown(error)
        }
    }

    func cancelSlicing() async {
        pollTask?.cancel()
        guard let id = job?.id, !settings.demoMode else {
            isSlicing = false
            return
        }
        try? await printer.backend.cancelSlice(id: id)
        isSlicing = false
    }

    func printResult() async {
        guard let job, job.didSucceed else { return }
        if settings.demoMode {
            printer.demoStartPrint(
                filename: job.outputFilename,
                estimatedSeconds: job.stats.estimatedTimeSeconds ?? 2_700,
                layers: job.stats.layerCount ?? 240
            )
            return
        }
        do {
            try await printer.backend.printSliceOutput(id: job.id)
            Haptics.success()
        } catch {
            lastError = APIError.from(error, host: settings.host)
            Haptics.error()
        }
    }

    func downloadResult() async -> URL? {
        guard let job, job.didSucceed, !settings.demoMode else { return nil }
        do {
            let data = try await printer.backend.downloadSliceOutput(id: job.id)
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("neptune-share", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(job.outputFilename)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            lastError = APIError.from(error, host: settings.host)
            return nil
        }
    }

    func reset() {
        pollTask?.cancel()
        job = nil
        progress = 0
        stage = ""
        logs = []
        isSlicing = false
        lastError = nil
    }

    // MARK: - Demo

    private func runDemoSlice(payload: SliceRequestPayload) async {
        isSlicing = true
        logs = []
        lastError = nil

        let stages: [(Double, String)] = [
            (0.1, "Processing triangulated mesh"),
            (0.25, "Generating perimeters"),
            (0.4, "Preparing infill"),
            (0.55, "Infilling layers"),
            (0.7, "Generating skirt"),
            (0.85, "Estimating printing time"),
            (0.95, "Exporting G-code")
        ]
        for (value, text) in stages {
            try? await Task.sleep(nanoseconds: 600_000_000)
            progress = value
            stage = text
            logs.append("=> \(text)")
        }

        let layers = max(1, Int(40.0 / max(layerHeight, 0.05)))
        let stats = SliceStats(
            estimatedTimeSeconds: Double(layers) * 22,
            filamentGrams: Double(infill) * 0.42 + 8,
            filamentMeters: Double(infill) * 0.13 + 2.4,
            filamentCM3: Double(infill) * 0.35 + 6,
            layerCount: layers,
            layerHeight: layerHeight,
            objectHeight: 40,
            gcodeSize: 3_400_000
        )
        let name = payload.outputName ?? "demo.gcode"
        job = SliceJob(
            id: UUID().uuidString,
            status: "done",
            progress: 1,
            stage: "Completed",
            modelID: payload.modelID,
            modelFilename: selectedModel?.filename ?? "model.stl",
            outputFilename: name,
            outputPath: "/demo/\(name)",
            moonrakerPath: name,
            createdAt: Date().timeIntervalSince1970,
            startedAt: Date().timeIntervalSince1970,
            finishedAt: Date().timeIntervalSince1970,
            error: nil,
            logs: logs,
            stats: stats,
            engine: "prusaslicer (demo)"
        )
        progress = 1
        stage = "Completed"
        isSlicing = false
        Haptics.success()
    }

    static let demoProfiles = BackendProfiles(
        printers: [
            BackendProfile(id: "neptune3plus_0.2", name: "Elegoo Neptune 3 Plus - 0.2 mm nozzle",
                           kind: "printer", description: "Fine detail", values: ["nozzle_diameter": "0.2"]),
            BackendProfile(id: "neptune3plus_0.4", name: "Elegoo Neptune 3 Plus - 0.4 mm nozzle",
                           kind: "printer", description: "Stock nozzle", values: ["nozzle_diameter": "0.4"]),
            BackendProfile(id: "neptune3plus_0.6", name: "Elegoo Neptune 3 Plus - 0.6 mm nozzle",
                           kind: "printer", description: "High flow", values: ["nozzle_diameter": "0.6"]),
            BackendProfile(id: "neptune3plus_0.8", name: "Elegoo Neptune 3 Plus - 0.8 mm nozzle",
                           kind: "printer", description: "Very high flow", values: ["nozzle_diameter": "0.8"])
        ],
        filaments: [
            BackendProfile(id: "pla", name: "PLA", kind: "filament", description: "",
                           values: ["temperature": "205", "bed_temperature": "60"]),
            BackendProfile(id: "pla_plus", name: "PLA+", kind: "filament", description: "",
                           values: ["temperature": "215", "bed_temperature": "60"]),
            BackendProfile(id: "petg", name: "PETG", kind: "filament", description: "",
                           values: ["temperature": "235", "bed_temperature": "75"]),
            BackendProfile(id: "tpu", name: "TPU", kind: "filament", description: "",
                           values: ["temperature": "220", "bed_temperature": "50"]),
            BackendProfile(id: "asa", name: "ASA", kind: "filament", description: "",
                           values: ["temperature": "250", "bed_temperature": "100"]),
            BackendProfile(id: "abs", name: "ABS", kind: "filament", description: "",
                           values: ["temperature": "245", "bed_temperature": "100"]),
            BackendProfile(id: "custom", name: "Custom", kind: "filament", description: "",
                           values: ["temperature": "210", "bed_temperature": "60"])
        ],
        prints: [
            BackendProfile(id: "quality", name: "Quality", kind: "print", description: "",
                           values: ["layer_height": "0.12", "perimeters": "3", "fill_density": "20%"]),
            BackendProfile(id: "standard", name: "Standard", kind: "print", description: "",
                           values: ["layer_height": "0.2", "perimeters": "3", "fill_density": "20%"]),
            BackendProfile(id: "fast", name: "Fast", kind: "print", description: "",
                           values: ["layer_height": "0.28", "perimeters": "2", "fill_density": "15%"]),
            BackendProfile(id: "klipper_fast", name: "Klipper Fast", kind: "print", description: "",
                           values: ["layer_height": "0.24", "perimeters": "2", "fill_density": "15%"]),
            BackendProfile(id: "custom", name: "Custom", kind: "print", description: "",
                           values: ["layer_height": "0.2", "perimeters": "3", "fill_density": "20%"])
        ]
    )
    /// How many profile settings the user has deliberately overridden.
    ///
    /// Shown as a badge so an override made three sessions ago is visible
    /// rather than quietly shaping every slice from then on.
    var advancedOverrideCount: Int {
        var count = 0
        if !infillPattern.isEmpty { count += 1 }
        if topSolidLayers > 0 { count += 1 }
        if bottomSolidLayers > 0 { count += 1 }
        if ironing { count += 1 }
        if !seamPosition.isEmpty { count += 1 }
        if spiralVase { count += 1 }
        if supportZDistance > 0 { count += 1 }
        if supportInterfaceLayers > 0 { count += 1 }
        if fanMinPercent > 0 { count += 1 }
        if fanMaxPercent > 0 { count += 1 }
        if disableFanFirstLayers > 0 { count += 1 }
        if avoidCrossingPerimeters { count += 1 }
        if retractionZHop > 0 { count += 1 }
        return count
    }

    var hasAdvancedOverrides: Bool { advancedOverrideCount > 0 }


}
