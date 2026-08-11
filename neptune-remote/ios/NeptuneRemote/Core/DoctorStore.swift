import Foundation
import SwiftUI

/// Fix My Printer, the guided calibration wizards, printer.cfg versions,
/// G-code inspection and the pre-print check.
///
/// Every printer command this store issues goes to the backend's safety engine
/// - there is no path from here straight to Klipper.
@MainActor
final class DoctorStore: ObservableObject {

    // MARK: - Diagnosis

    @Published private(set) var diagnosis: DiagnosisReport?
    @Published private(set) var isDiagnosing = false
    @Published private(set) var lastDiagnosedAt: Date?

    // MARK: - Workflows

    @Published private(set) var workflowOptions: [WorkflowOption] = []
    @Published private(set) var workflow: WorkflowRun?
    @Published private(set) var isAdvancing = false

    // MARK: - Config

    @Published private(set) var liveConfig: LiveConfig?
    @Published private(set) var configVersions: [ConfigVersion] = []
    @Published private(set) var goldenConfig: ConfigVersion?
    @Published private(set) var isLoadingConfig = false

    // MARK: - G-code

    @Published private(set) var lastInspection: GCodeReport?
    @Published private(set) var lastPreflight: PreflightReport?
    @Published private(set) var isInspecting = false

    // MARK: - Slicer profiles

    @Published private(set) var slicerProfiles: [SlicerProfile] = []

    @Published var lastError: APIError?
    @Published var lastMessage: String?

    private let settings: AppSettings
    private let printer: PrinterStore

    init(settings: AppSettings, printer: PrinterStore) {
        self.settings = settings
        self.printer = printer
    }

    // MARK: - Fix My Printer

    /// `deep` also queries the probe and endstops. It still never moves anything.
    func diagnose(deep: Bool = true) async {
        guard !isDiagnosing else { return }
        isDiagnosing = true
        defer { isDiagnosing = false }

        guard !settings.demoMode else {
            diagnosis = DemoDoctor.diagnosis
            lastDiagnosedAt = Date()
            return
        }
        do {
            diagnosis = try await printer.backend.diagnose(deep: deep)
            lastDiagnosedAt = Date()
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    var criticalFindings: [DoctorFinding] {
        diagnosis?.findings.filter(\.isCritical) ?? []
    }

    var warningFindings: [DoctorFinding] {
        diagnosis?.findings.filter { $0.severity == "warning" } ?? []
    }

    var healthCards: [HealthCard] { diagnosis?.cards ?? [] }

    /// The one-line state for the Home card.
    var headline: String {
        guard let diagnosis else { return L.t("doctor.not_checked") }
        return diagnosis.summary
    }

    // MARK: - Workflows

    func loadWorkflows() async {
        guard !settings.demoMode else {
            workflowOptions = DemoDoctor.workflowOptions
            return
        }
        do {
            let result = try await printer.backend.workflowOptions()
            workflowOptions = result.available
            workflow = result.active
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    // MARK: - Probe

    /// The last wiring reading, and the last repeatability measurement.
    ///
    /// Kept apart because they answer different questions: the first is "is the
    /// probe connected and the right way round", the second is "does it fire in
    /// the same place twice". A probe can pass one and fail the other, and the
    /// fixes have nothing to do with each other.
    @Published private(set) var probeWiring: ProbeDiagnosis?
    @Published private(set) var probeAccuracy: ProbeDiagnosis?
    @Published private(set) var isCheckingProbe = false

    /// Reads the probe. `pressed` is the second half of the test, taken while
    /// something is held against the sensor.
    ///
    /// Nothing moves and nothing heats - it only reads a pin - so there is no
    /// confirmation and no safety gate to pass.
    func checkProbeWiring(pressed: Bool) async {
        guard !settings.demoMode else {
            lastMessage = L.t("demo.action.ignored")
            return
        }
        isCheckingProbe = true
        defer { isCheckingProbe = false }
        do {
            probeWiring = try await printer.backend.diagnoseProbe(pressed: pressed)
            lastError = nil
            Haptics.impact(.light)
        } catch {
            lastError = APIError.from(error, host: settings.host)
            Haptics.error()
        }
    }

    /// Measures repeatability with PROBE_ACCURACY.
    ///
    /// This one does move: it drops the toolhead onto the bed ten times, so it
    /// needs the printer homed first and it takes the better part of a minute.
    func measureProbeAccuracy() async {
        guard !settings.demoMode else {
            lastMessage = L.t("demo.action.ignored")
            return
        }
        isCheckingProbe = true
        defer { isCheckingProbe = false }
        do {
            probeAccuracy = try await printer.backend.probeAccuracy()
            lastError = nil
            Haptics.success()
        } catch {
            lastError = APIError.from(error, host: settings.host)
            Haptics.error()
        }
    }

    @discardableResult
    func startWorkflow(_ kind: String) async -> Bool {
        guard !settings.demoMode else {
            lastMessage = L.t("demo.action.ignored")
            return false
        }
        do {
            workflow = try await printer.backend.startWorkflow(kind)
            lastError = nil
            Haptics.impact(.medium)
            return true
        } catch {
            lastError = APIError.from(error, host: settings.host)
            Haptics.error()
            return false
        }
    }

    /// `force` acknowledges a warning. It can never override a refusal - the
    /// backend blocks those regardless.
    func advance(force: Bool = false) async {
        guard !settings.demoMode, workflow != nil else { return }
        guard !isAdvancing else { return }
        isAdvancing = true
        defer { isAdvancing = false }
        do {
            workflow = try await printer.backend.advanceWorkflow(force: force)
            lastError = nil
            if workflow?.failed == true { Haptics.error() }
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    func confirmStep(_ payload: [String: String] = [:]) async {
        guard !settings.demoMode, workflow != nil else { return }
        do {
            workflow = try await printer.backend.confirmWorkflowStep(payload)
            Haptics.success()
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    func repeatStep() async {
        guard !settings.demoMode, workflow != nil else { return }
        isAdvancing = true
        defer { isAdvancing = false }
        do {
            workflow = try await printer.backend.repeatWorkflowStep()
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    func goToStep(_ stepID: String) async {
        guard !settings.demoMode, workflow != nil else { return }
        do {
            workflow = try await printer.backend.goToWorkflowStep(stepID)
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    func cancelWorkflow() async {
        guard !settings.demoMode else { return }
        try? await printer.backend.cancelWorkflow()
        workflow = nil
    }

    /// Screw readings from the current workflow, when it has any.
    var screws: ScrewsTiltReport? { workflow?.data.screws }

    // MARK: - Z offset stepping

    /// One nudge of the nozzle during PROBE_CALIBRATE.
    @discardableResult
    func stepZ(_ delta: Double) async -> CommandDecision? {
        guard !settings.demoMode else { return nil }
        do {
            let decision = try await printer.backend.testZ(delta: delta)
            Haptics.impact(.light)
            lastError = nil
            return decision
        } catch {
            lastError = APIError.from(error, host: settings.host)
            Haptics.error()
            return nil
        }
    }

    // MARK: - Safe commands

    /// Ask what would happen, without sending anything.
    func evaluate(_ command: String) async -> CommandDecision? {
        guard !settings.demoMode else { return nil }
        return try? await printer.backend.evaluateCommand(command)
    }

    @discardableResult
    func run(_ command: String, force: Bool = false) async -> CommandDecision? {
        guard !settings.demoMode else {
            lastMessage = L.t("demo.action.ignored")
            return nil
        }
        do {
            let decision = try await printer.backend.runCommand(command, force: force)
            lastError = nil
            return decision
        } catch {
            lastError = APIError.from(error, host: settings.host)
            Haptics.error()
            return nil
        }
    }

    // MARK: - printer.cfg

    func loadConfig() async {
        guard !isLoadingConfig else { return }
        isLoadingConfig = true
        defer { isLoadingConfig = false }

        guard !settings.demoMode else {
            configVersions = DemoDoctor.configVersions
            goldenConfig = DemoDoctor.configVersions.first { $0.golden }
            return
        }
        do {
            async let configTask = printer.backend.liveConfig()
            async let versionsTask = printer.backend.configVersions()
            liveConfig = try await configTask
            let versions = try await versionsTask
            configVersions = versions.versions
            goldenConfig = versions.golden
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    func snapshotConfig(label: String) async {
        guard !settings.demoMode else { return }
        do {
            _ = try await printer.backend.snapshotConfig(label: label)
            await loadConfig()
            lastMessage = L.t("config.snapshot.saved")
            Haptics.success()
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    func markGolden(_ version: ConfigVersion) async {
        guard !settings.demoMode else { return }
        do {
            _ = try await printer.backend.markConfigGolden(version.id)
            await loadConfig()
            lastMessage = L.t("config.golden.marked")
            Haptics.success()
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    func rename(_ version: ConfigVersion, label: String) async {
        guard !settings.demoMode else { return }
        _ = try? await printer.backend.labelConfigVersion(version.id, label: label)
        await loadConfig()
    }

    func delete(_ version: ConfigVersion) async {
        guard !settings.demoMode else { return }
        do {
            try await printer.backend.deleteConfigVersion(version.id)
            await loadConfig()
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    func diff(from: ConfigVersion, to: ConfigVersion? = nil) async -> ConfigDiff? {
        guard !settings.demoMode else { return nil }
        do {
            return try await printer.backend.configDiff(from: from.id, to: to?.id)
        } catch {
            lastError = APIError.from(error, host: settings.host)
            return nil
        }
    }

    /// Preview first; the caller shows the diff and asks before confirming.
    func previewRestore(_ version: ConfigVersion?) async -> ConfigRestoreResult? {
        guard !settings.demoMode else { return nil }
        do {
            return try await printer.backend.restoreConfig(versionID: version?.id, confirm: false)
        } catch {
            lastError = APIError.from(error, host: settings.host)
            return nil
        }
    }

    @discardableResult
    func confirmRestore(_ version: ConfigVersion?) async -> Bool {
        guard !settings.demoMode else { return false }
        do {
            let result = try await printer.backend.restoreConfig(versionID: version?.id, confirm: true)
            await loadConfig()
            lastMessage = L.t("config.restored")
            Haptics.success()
            return result.didRestore
        } catch {
            lastError = APIError.from(error, host: settings.host)
            Haptics.error()
            return false
        }
    }

    // MARK: - G-code

    func inspect(filename: String) async {
        guard !isInspecting else { return }
        isInspecting = true
        defer { isInspecting = false }

        guard !settings.demoMode else {
            lastInspection = DemoDoctor.gcodeReport
            return
        }
        do {
            lastInspection = try await printer.backend.inspectGCode(filename: filename)
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    @discardableResult
    func runPreflight(filename: String) async -> PreflightReport? {
        guard !settings.demoMode else {
            lastPreflight = DemoDoctor.preflight
            return lastPreflight
        }
        do {
            let report = try await printer.backend.preflight(
                filename: filename, strict: settings.strictSafetyMode
            )
            lastPreflight = report
            lastError = nil
            return report
        } catch {
            lastError = APIError.from(error, host: settings.host)
            return nil
        }
    }

    // MARK: - Slicer profiles

    func loadSlicerProfiles() async {
        guard !settings.demoMode else { return }
        do {
            slicerProfiles = try await printer.backend.slicerProfiles().profiles
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    func markSlicerProfileGolden(_ profile: SlicerProfile) async {
        guard !settings.demoMode else { return }
        do {
            _ = try await printer.backend.markSlicerProfileGolden(profile.id)
            await loadSlicerProfiles()
            lastMessage = L.t("slicer.golden.marked")
            Haptics.success()
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    func deleteSlicerProfile(_ profile: SlicerProfile) async {
        guard !settings.demoMode else { return }
        do {
            try await printer.backend.deleteSlicerProfile(profile.id)
            await loadSlicerProfiles()
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }
}

// MARK: - Demo data

enum DemoDoctor {
    static let diagnosis = DiagnosisReport(
        generatedAt: Date().timeIntervalSince1970,
        overall: "yellow",
        summary: "2 things to look at.",
        safeToPrint: true,
        criticalCount: 0,
        warningCount: 2,
        findings: [
            DoctorFinding(
                code: "bed_mesh_missing",
                subsystem: "bed_mesh",
                severity: "warning",
                title: "There is no saved bed mesh.",
                cause: "BED_MESH_CALIBRATE has not been run, or the result was never saved.",
                recommendation: "Run a bed mesh - first layers on a 320 mm bed depend on it.",
                autoFix: "bed_mesh_wizard",
                autoFixLabel: "Run a bed mesh",
                manualSteps: [],
                detail: ""
            ),
            DoctorFinding(
                code: "accel_above_recommended",
                subsystem: "config",
                severity: "warning",
                title: "max_accel is 6000 mm/s², above the 3000 recommended for a Neptune 3 Plus.",
                cause: "Y carries the moving bed on this frame, so it is the axis most likely to skip steps.",
                recommendation: "Lower it and run the Axis Health Test if you see layer shifts.",
                autoFix: nil,
                autoFixLabel: "",
                manualSteps: [],
                detail: ""
            )
        ],
        cards: [
            HealthCard(subsystem: "moonraker", health: "green", status: "Connected", detail: "v0.9.3", recommendation: "", checkedAt: 0),
            HealthCard(subsystem: "klipper", health: "green", status: "Ready", detail: "", recommendation: "", checkedAt: 0),
            HealthCard(subsystem: "mcu", health: "green", status: "Connected", detail: "v0.12.0", recommendation: "", checkedAt: 0),
            HealthCard(subsystem: "config", health: "yellow", status: "1 warning", detail: "max_accel is high", recommendation: "", checkedAt: 0),
            HealthCard(subsystem: "x_axis", health: "green", status: "Homed", detail: "-3 to 330 mm", recommendation: "", checkedAt: 0),
            HealthCard(subsystem: "y_axis", health: "green", status: "Homed", detail: "-8 to 330 mm", recommendation: "", checkedAt: 0),
            HealthCard(subsystem: "z_axis", health: "green", status: "Homed", detail: "0 to 410 mm", recommendation: "", checkedAt: 0),
            HealthCard(subsystem: "probe", health: "green", status: "Open", detail: "", recommendation: "", checkedAt: 0),
            HealthCard(subsystem: "z_offset", health: "green", status: "2.145 mm", detail: "Saved by SAVE_CONFIG", recommendation: "", checkedAt: 0),
            HealthCard(subsystem: "bed_mesh", health: "yellow", status: "No saved mesh", detail: "", recommendation: "Run a bed mesh.", checkedAt: 0),
            HealthCard(subsystem: "hotend", health: "green", status: "24.1 °C", detail: "", recommendation: "", checkedAt: 0),
            HealthCard(subsystem: "bed", health: "green", status: "23.4 °C", detail: "", recommendation: "", checkedAt: 0),
            HealthCard(subsystem: "part_cooling", health: "green", status: "Off", detail: "fan", recommendation: "", checkedAt: 0),
            HealthCard(subsystem: "filament_sensor", health: "unknown", status: "Not configured", detail: "", recommendation: "", checkedAt: 0),
            HealthCard(subsystem: "motion_limits", health: "yellow", status: "300 mm/s, 6000 mm/s²", detail: "", recommendation: "", checkedAt: 0),
            HealthCard(subsystem: "accelerometer", health: "unknown", status: "Not installed", detail: "", recommendation: "", checkedAt: 0),
            HealthCard(subsystem: "camera", health: "green", status: "Available", detail: "", recommendation: "", checkedAt: 0),
            HealthCard(subsystem: "host", health: "green", status: "CPU 14%, 48 °C", detail: "", recommendation: "", checkedAt: 0),
            HealthCard(subsystem: "storage", health: "green", status: "82.0 GB free", detail: "", recommendation: "", checkedAt: 0)
        ]
    )

    static let workflowOptions: [WorkflowOption] = [
        WorkflowOption(kind: "safe_home", title: "Home safely"),
        WorkflowOption(kind: "z_offset", title: "Z Offset wizard"),
        WorkflowOption(kind: "screws_tilt", title: "Bed screw adjustment"),
        WorkflowOption(kind: "bed_mesh", title: "Bed mesh"),
        WorkflowOption(kind: "full_bed_calibration", title: "Full bed calibration"),
        WorkflowOption(kind: "axis_health", title: "Axis health test"),
        WorkflowOption(kind: "input_shaper", title: "Input shaper calibration")
    ]

    static let configVersions: [ConfigVersion] = [
        ConfigVersion(
            id: "demo-golden", createdAt: Date().timeIntervalSince1970 - 604_800,
            label: "Golden Config", reason: "manual", sizeBytes: 8_412,
            sha256: "abc", golden: true, provenPrints: 14,
            lastProvenAt: Date().timeIntervalSince1970 - 86_400, note: "", sectionCount: 32
        ),
        ConfigVersion(
            id: "demo-recent", createdAt: Date().timeIntervalSince1970 - 3_600,
            label: "", reason: "pre_save_config", sizeBytes: 8_501,
            sha256: "def", golden: false, provenPrints: 0,
            lastProvenAt: nil, note: "", sectionCount: 32
        )
    ]

    static let gcodeReport = GCodeReport(
        verdict: "safe", blocked: false, errorCount: 0, warningCount: 0, issues: [],
        slicer: "PrusaSlicer", slicerVersion: "2.8.1", profileName: "Neptune3Plus 0.20 Standard",
        filament: "Generic PLA", verifiedProfile: true, profileStatus: "golden",
        bounds: GCodeBounds(minX: 84.2, maxX: 235.8, minY: 92.1, maxY: 227.9, minZ: 0.2, maxZ: 38.5),
        estimatedSeconds: 5_400, layerHeight: 0.2, firstLayerHeight: 0.25,
        nozzleDiameter: 0.4, layerCount: 192,
        maxRequestedFeedrate: 9_000, maxRequestedAccel: 3_000,
        positioningAbsolute: true, extrusionRelative: true, hasHome: true,
        setsHotendTemp: true, setsBedTemp: true, unsupported: [], linesScanned: 184_302
    )

    static let preflight = PreflightReport(
        verdict: "ready", ready: true, strict: false, summary: "Ready to print.",
        failureCount: 0, warningCount: 0,
        checks: [
            PreflightCheck(id: "printer_health", label: "Printer health", passed: true, severity: "info", detail: "All checks green.", remedy: ""),
            PreflightCheck(id: "gcode_validation", label: "G-code validation", passed: true, severity: "info", detail: "Passed.", remedy: "")
        ],
        gcode: gcodeReport,
        banner: PreflightBanner(
            slicer: "PrusaSlicer",
            printerProfile: "Neptune3Plus 0.20 Standard",
            profileStatus: "GOLDEN",
            gcodeValidation: "SAFE",
            buildVolume: "PASSED",
            unsupportedCommands: "NONE",
            motionLimits: "PASSED",
            bounds: "X 84.2…235.8   Y 92.1…227.9   Z 0.2…38.5"
        )
    )
}
