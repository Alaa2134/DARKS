import Foundation

/// Print modes, the generated calibration prints, and what the history has learned.
///
/// One store because they are one loop: a mode tells you what the printer will
/// actually do, a calibration fixes the numbers underneath it, and the history
/// says whether the fix worked. Splitting them would mean three screens that
/// each know a third of the story.
@MainActor
final class CalibrationStore: ObservableObject {

    @Published private(set) var modes: PrintModeList = PrintModeList()
    @Published private(set) var tests: [CalibrationTestSummary] = []
    @Published private(set) var learning = LearningReport()
    @Published private(set) var anomalies = AnomalyStatus()

    @Published private(set) var generated: CalibrationTest?
    @Published private(set) var firstLayer: FirstLayerReading?
    /// Macros built from the live printer.cfg. Text only - the app never
    /// installs one.
    @Published private(set) var macros: MacroSuggestions?
    @Published private(set) var isLoadingMacros = false
    /// Whether the bed is actually calibrated, from the live printer.cfg.
    ///
    /// nil until asked, and nil again on failure - the home screen shows
    /// nothing rather than claiming a printer it cannot read is fine.
    @Published private(set) var status: CalibrationStatus?

    @Published private(set) var isLoading = false
    @Published private(set) var isGenerating = false
    @Published private(set) var isInspecting = false
    @Published var lastError: APIError?

    /// The material the mode list is resolved against. The same mode is
    /// genuinely different settings on PLA and PETG, so this is not cosmetic.
    @Published var filamentProfile: String = "pla" {
        didSet { Task { await loadModes() } }
    }
    @Published var printerProfile: String = "neptune3plus_0.4"

    private let settings: AppSettings
    private let printer: PrinterStore

    init(settings: AppSettings, printer: PrinterStore) {
        self.settings = settings
        self.printer = printer
    }

    // MARK: - Loading

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        if settings.demoMode {
            modes = Self.demoModes
            tests = Self.demoTests
            return
        }

        await loadModes()
        do {
            tests = try await printer.backend.calibrationTests()
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    func loadModes() async {
        guard !settings.demoMode else { return }
        do {
            modes = try await printer.backend.printModes(
                printerProfile: printerProfile, filamentProfile: filamentProfile
            )
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    func loadLearning() async {
        guard !settings.demoMode else { return }
        do {
            learning = try await printer.backend.learningReport()
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    func refreshAnomalies() async {
        guard !settings.demoMode else { return }
        if let fresh = try? await printer.backend.anomalies() { anomalies = fresh }
    }

    // MARK: - Calibration prints

    func generate(_ id: String, nozzleTemp: Double, bedTemp: Double) async {
        guard !isGenerating else { return }
        isGenerating = true
        defer { isGenerating = false }

        do {
            generated = try await printer.backend.calibrationTest(
                id, nozzleTemp: nozzleTemp, bedTemp: bedTemp
            )
            lastError = nil
        } catch {
            generated = nil
            lastError = APIError.from(error, host: settings.host)
        }
    }

    func clearGenerated() { generated = nil }

    func flowResult(measured: Double, expected: Double, currentFlow: Double) async -> FlowResult? {
        do {
            let result = try await printer.backend.flowResult(
                measured: measured, expected: expected, currentFlow: currentFlow
            )
            lastError = nil
            return result
        } catch {
            lastError = APIError.from(error, host: settings.host)
            return nil
        }
    }

    func pressureAdvanceResult(
        heightMM: Double, start: Double, step: Double, layerHeight: Double
    ) async -> PressureAdvanceResult? {
        do {
            let result = try await printer.backend.pressureAdvanceResult(
                heightMM: heightMM, start: start, step: step, layerHeight: layerHeight
            )
            lastError = nil
            return result
        } catch {
            lastError = APIError.from(error, host: settings.host)
            return nil
        }
    }

    // MARK: - First layer

    func inspectFirstLayer() async {
        guard !isInspecting else { return }
        isInspecting = true
        defer { isInspecting = false }

        do {
            firstLayer = try await printer.backend.inspectFirstLayer()
            lastError = nil
        } catch {
            firstLayer = nil
            lastError = APIError.from(error, host: settings.host)
        }
    }

    /// Reads the macros the backend generates from this printer's own config.
    ///
    /// Nothing is installed and nothing is written. The result is text plus the
    /// reasoning behind every coordinate in it, which the user copies into
    /// printer.cfg themselves - the one place this app has always refused to
    /// touch on its own.
    func loadMacros() async {
        guard !isLoadingMacros else { return }
        isLoadingMacros = true
        defer { isLoadingMacros = false }

        do {
            macros = try await printer.backend.suggestedMacros()
            lastError = nil
        } catch {
            macros = nil
            lastError = APIError.from(error, host: settings.host)
        }
    }

    /// Refreshes the calibration status.
    ///
    /// Quiet on failure. This drives a card on the home screen, and a printer
    /// that is briefly unreachable must not put an error banner over the
    /// dashboard - the card simply is not there.
    func loadStatus() async {
        guard !settings.demoMode else {
            status = Self.demoStatus
            return
        }
        status = try? await printer.backend.calibrationStatus()
    }

    /// Applies the measured Z correction.
    ///
    /// Goes through the printer's safety engine like every other command, and
    /// only ever sends what the reading itself produced - the app never
    /// composes a Z offset of its own.
    @discardableResult
    func applyFirstLayerCorrection() async -> Bool {
        guard let command = firstLayer?.command else { return false }
        return await printer.send(gcode: command)
    }

    func clearFirstLayer() { firstLayer = nil }

    static let demoStatus = CalibrationStatus(
        items: [
            CalibrationItem(
                id: "screws_tilt", state: "unknown", ok: false,
                title: "استواء السرير من المسامير",
                detail: "لسه ماتقاسش من التطبيق."
            ),
            CalibrationItem(
                id: "z_offset", state: "done", ok: true,
                title: "مسافة الفوهة عن السرير (Z offset)",
                detail: "معايَرة ومحفوظة: 1.802 مم.", value: 1.802
            ),
            CalibrationItem(
                id: "bed_mesh", state: "done", ok: true,
                title: "خريطة السرير (Bed mesh)",
                detail: "محفوظة: default."
            )
        ],
        allDone: false,
        nextID: "screws_tilt",
        nextTitle: "استواء السرير من المسامير"
    )
}

// MARK: - Demo data

extension CalibrationStore {
    static var demoModes: PrintModeList {
        var list = PrintModeList()
        list.limitsFromConfig = true
        list.maxAccel = 3000
        list.filamentProfile = "petg"
        list.modes = [
            demoMode(id: "draft", ar: "مسودة", en: "Draft", layer: 0.28, speed: 63,
                     time: 0.68, flowLimited: true,
                     note: "مش هيكون أسرع من «سريع» مع الخامة دي — الاتنين واصلين لحد سيحان البلاستيك."),
            demoMode(id: "fast", ar: "سريع", en: "Fast", layer: 0.22, speed: 81,
                     time: 0.68, flowLimited: true),
            demoMode(id: "balanced", ar: "متوازن", en: "Balanced", layer: 0.20, speed: 60, time: 1.0),
            demoMode(id: "quality", ar: "جودة عالية", en: "Quality", layer: 0.14, speed: 33, time: 2.6),
            demoMode(id: "strong", ar: "متين", en: "Strong", layer: 0.20, speed: 52, time: 1.15),
            demoMode(id: "miniature", ar: "تفاصيل دقيقة", en: "Fine detail", layer: 0.11,
                     speed: 27, time: 3.97),
        ]
        return list
    }

    private static func demoMode(
        id: String, ar: String, en: String, layer: Double, speed: Double,
        time: Double, flowLimited: Bool = false, note: String? = nil
    ) -> PrintMode {
        var mode = PrintMode()
        mode.id = id
        mode.titleAR = ar
        mode.titleEN = en
        mode.layerHeight = layer
        mode.printSpeed = speed
        mode.relativeTime = time
        mode.flowLimited = flowLimited
        mode.wasClamped = flowLimited
        mode.perimeters = 3
        mode.infillPercent = 20
        mode.acceleration = 3000
        if let note { mode.notesAR = [note] }
        return mode
    }

    static var demoTests: [CalibrationTestSummary] {
        [
            summary("first_layer", "فحص الطبقة الأولى", "First layer check", 5),
            summary("flow", "معايرة التدفق", "Flow calibration", 6),
            summary("pressure_advance", "معايرة Pressure Advance", "Pressure advance", 12),
            summary("temperature", "برج الحرارة", "Temperature tower", 20),
        ]
    }

    private static func summary(
        _ id: String, _ ar: String, _ en: String, _ minutes: Double
    ) -> CalibrationTestSummary {
        var item = CalibrationTestSummary()
        item.id = id
        item.titleAR = ar
        item.titleEN = en
        item.ok = true
        item.estimatedMinutes = minutes
        return item
    }
}
