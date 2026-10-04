import Foundation
import SwiftUI

/// Diagnostics, the offline Arabic troubleshooting trees, the Klipper error
/// translator, bed mesh and backups.
///
/// The troubleshooting content ships with the backend and is answered entirely
/// offline - no cloud service is contacted for any of it. The error translator
/// always keeps `original` so the raw Klipper text stays visible.
@MainActor
final class SupportStore: ObservableObject {

    // MARK: - Published state

    @Published private(set) var diagnostics: DiagnosticsReport?
    @Published private(set) var topics: [TroubleshootingTopic] = []
    @Published private(set) var bedMesh: BedMeshReport?
    @Published private(set) var backups: [BackupInfo] = []

    @Published private(set) var isRunningDiagnostics = false
    @Published private(set) var isLoadingTopics = false
    @Published private(set) var isBusy = false
    @Published var lastError: APIError?
    @Published var lastMessage: String?

    /// Cache so the same Klipper line is not re-translated on every redraw.
    private var translationCache: [String: TranslatedError] = [:]

    private let settings: AppSettings
    private let printer: PrinterStore

    init(settings: AppSettings, printer: PrinterStore) {
        self.settings = settings
        self.printer = printer
    }

    // MARK: - Diagnostics

    var diagnosticsOverall: String { diagnostics?.overall ?? "unknown" }

    var failedChecks: [DiagnosticCheck] {
        diagnostics?.checks.filter { $0.status != "ok" } ?? []
    }

    func runDiagnostics() async {
        guard !isRunningDiagnostics else { return }
        isRunningDiagnostics = true
        defer { isRunningDiagnostics = false }

        if settings.demoMode {
            diagnostics = DemoSupport.diagnostics
            return
        }
        do {
            diagnostics = try await printer.backend.diagnostics()
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    /// Plain-text report for sharing. The backend redacts tokens and secrets
    /// before it ever leaves the Pi.
    func diagnosticsText() async -> String? {
        guard !settings.demoMode else { return DemoSupport.reportText }
        do {
            let text = try await printer.backend.diagnosticsReport()
            lastError = nil
            return text
        } catch {
            lastError = APIError.from(error, host: settings.host)
            return nil
        }
    }

    // MARK: - Troubleshooting

    func loadTopics(force: Bool = false) async {
        guard force || topics.isEmpty else { return }
        guard !isLoadingTopics else { return }
        isLoadingTopics = true
        defer { isLoadingTopics = false }

        if settings.demoMode {
            topics = DemoSupport.topics
            return
        }
        do {
            topics = try await printer.backend.troubleshootingTopics()
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    func topic(id: String) -> TroubleshootingTopic? {
        topics.first { $0.id == id }
    }

    // MARK: - Klipper error translation

    /// Translates a Klipper/Moonraker error into Arabic. Returns nil only when
    /// the backend is unreachable; an unmatched message still comes back with
    /// `matched == false` and the original text intact.
    @discardableResult
    func translate(_ message: String) async -> TranslatedError? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let cached = translationCache[trimmed] { return cached }

        if settings.demoMode {
            let demo = DemoSupport.translation(for: trimmed)
            translationCache[trimmed] = demo
            return demo
        }
        do {
            let translated = try await printer.backend.translateError(trimmed)
            translationCache[trimmed] = translated
            lastError = nil
            return translated
        } catch {
            lastError = APIError.from(error, host: settings.host)
            return nil
        }
    }

    /// Already-known translation, for synchronous use inside a view body.
    func cachedTranslation(_ message: String) -> TranslatedError? {
        translationCache[message.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    /// Translate whatever Klipper is currently unhappy about, if anything.
    func translateCurrentPrinterError() async -> TranslatedError? {
        let snapshot = printer.snapshot
        let candidates = [snapshot.errorMessage ?? "", snapshot.klippyMessage, snapshot.stateMessage]
        guard let message = candidates
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty && $0.lowercased() != "printer is ready" })
        else { return nil }
        return await translate(message)
    }

    // MARK: - Bed mesh

    func loadBedMesh() async {
        if settings.demoMode {
            bedMesh = DemoSupport.bedMesh
            return
        }
        do {
            bedMesh = try await printer.backend.bedMesh()
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    /// Runs a fresh probe, then reloads the mesh. Refuses while printing.
    func calibrateBedMesh() async {
        guard !printer.snapshot.isPrinting else {
            lastError = .unknown(L.t("bedmesh.blocked.printing"))
            return
        }
        isBusy = true
        defer { isBusy = false }
        guard await printer.send(gcode: "BED_MESH_CALIBRATE") else { return }
        // The probe run takes a while; the mesh is only meaningful afterwards.
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await loadBedMesh()
    }

    // MARK: - Backups

    func loadBackups() async {
        guard !settings.demoMode else {
            backups = DemoSupport.backups
            return
        }
        do {
            backups = try await printer.backend.backups()
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    /// Creates a config + database archive on the Pi. Secrets are redacted by
    /// the backend before anything is written into the archive.
    func createBackup() async {
        guard !settings.demoMode else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let backup = try await printer.backend.createBackup()
            backups.insert(backup, at: 0)
            lastMessage = L.t("backup.created")
            Haptics.success()
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
            Haptics.error()
        }
    }

    func deleteBackup(_ backup: BackupInfo) async {
        guard !settings.demoMode else {
            backups.removeAll { $0.filename == backup.filename }
            return
        }
        do {
            try await printer.backend.deleteBackup(filename: backup.filename)
            backups.removeAll { $0.filename == backup.filename }
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }
}

// MARK: - Demo data

enum DemoSupport {
    static let diagnostics = DiagnosticsReport(
        generatedAt: Date().timeIntervalSince1970,
        version: "2.0.0",
        overall: "warning",
        checks: [
            DiagnosticCheck(
                id: "moonraker", nameAR: "الاتصال بـ Moonraker", nameEN: "Moonraker connection",
                status: "ok", detail: "v0.9.3", hintKey: ""
            ),
            DiagnosticCheck(
                id: "klipper", nameAR: "حالة Klipper", nameEN: "Klipper state",
                status: "ok", detail: "ready", hintKey: ""
            ),
            DiagnosticCheck(
                id: "slicer", nameAR: "برنامج التقطيع", nameEN: "Slicer",
                status: "ok", detail: "PrusaSlicer 2.8.1", hintKey: ""
            ),
            DiagnosticCheck(
                id: "camera", nameAR: "الكاميرا", nameEN: "Camera",
                status: "ok", detail: "/dev/video0", hintKey: ""
            ),
            DiagnosticCheck(
                id: "disk", nameAR: "المساحة المتاحة", nameEN: "Free disk space",
                status: "warning", detail: "8.2 GB", hintKey: "diagnostics.hint.disk_low"
            ),
            DiagnosticCheck(
                id: "tailscale", nameAR: "Tailscale", nameEN: "Tailscale",
                status: "ok", detail: "100.78.2.66", hintKey: ""
            )
        ],
        summaryAR: "كل شيء يعمل، لكن المساحة المتاحة على الكارت بدأت تقل."
    )

    static let reportText = """
    Neptune 3 Plus Remote - diagnostics (demo)
    moonraker: ok
    klipper:   ok
    slicer:    PrusaSlicer 2.8.1
    camera:    /dev/video0
    disk:      8.2 GB free (warning)
    tailscale: 100.78.2.66
    """

    static let topics: [TroubleshootingTopic] = [
        TroubleshootingTopic(
            id: "adhesion",
            titleAR: "الطبعة مش لازقة في السطح",
            titleEN: "Print not sticking to the bed",
            icon: "square.stack.3d.down.right",
            summaryAR: "أشهر سبب هو ارتفاع الفوهة عن السطح أو سطح متسخ.",
            firstStep: "clean",
            steps: [
                TroubleshootingStep(
                    id: "clean",
                    questionAR: "هل نظفت السطح بكحول قبل الطباعة؟",
                    questionEN: "Did you clean the bed with alcohol first?",
                    yesNext: "zoffset", noNext: nil,
                    adviceAR: "نظف السطح بكحول ٩٩٪ وجرب تاني.",
                    adviceEN: "Clean the sheet with 99% IPA and try again."
                ),
                TroubleshootingStep(
                    id: "zoffset",
                    questionAR: "هل الخط الأول بيتفرد وبيلزق أم رفيع ومقطع؟",
                    questionEN: "Is the first line flattened or thin and broken?",
                    yesNext: nil, noNext: nil,
                    adviceAR: "قلل Z offset بمقدار 0.02 مم وأعد المعايرة.",
                    adviceEN: "Lower the Z offset by 0.02 mm and re-level."
                )
            ],
            quickFixesAR: [
                "ارفع حرارة السطح إلى 60 °م لخيوط PLA",
                "فعّل Brim للقطع الصغيرة",
                "أعد معايرة Z offset"
            ]
        ),
        TroubleshootingTopic(
            id: "stringing",
            titleAR: "خيوط رفيعة بين الأجزاء",
            titleEN: "Stringing between parts",
            icon: "scribble",
            summaryAR: "غالباً حرارة عالية أو Retraction قليل.",
            firstStep: "temp",
            steps: [
                TroubleshootingStep(
                    id: "temp",
                    questionAR: "هل حرارة الفوهة أعلى من 210 °م؟",
                    questionEN: "Is the nozzle above 210 °C?",
                    yesNext: nil, noNext: "retract",
                    adviceAR: "قلل الحرارة 5 °م وأعد الطباعة.",
                    adviceEN: "Drop the temperature by 5 °C and reprint."
                ),
                TroubleshootingStep(
                    id: "retract",
                    questionAR: "هل Retraction أقل من 1 مم؟",
                    questionEN: "Is retraction under 1 mm?",
                    yesNext: nil, noNext: nil,
                    adviceAR: "زوّد Retraction إلى 1.5 مم.",
                    adviceEN: "Increase retraction to 1.5 mm."
                )
            ],
            quickFixesAR: ["جفف الفلامنت", "قلل الحرارة تدريجياً", "زوّد سرعة الـ Travel"]
        )
    ]

    static let bedMesh = BedMeshReport(
        available: true,
        profileName: "default",
        matrix: [
            [-0.08, -0.04, 0.01, 0.03, 0.02],
            [-0.05, -0.01, 0.02, 0.05, 0.04],
            [-0.02, 0.01, 0.04, 0.06, 0.05],
            [0.00, 0.03, 0.05, 0.07, 0.06],
            [0.02, 0.04, 0.06, 0.09, 0.08]
        ],
        highest: 0.09, lowest: -0.08, range: 0.17,
        verdict: "good", verdictKey: "bedmesh.verdict.good", messageKey: nil
    )

    static let backups: [BackupInfo] = [
        BackupInfo(
            filename: "neptune-backup-2026-05-18.tar.gz",
            path: "backups/neptune-backup-2026-05-18.tar.gz",
            sizeBytes: 2_418_112,
            createdAt: Date().timeIntervalSince1970 - 172_800,
            contents: ["config.yaml (redacted)", "neptune.db", "profiles/"]
        )
    ]

    static func translation(for message: String) -> TranslatedError {
        if message.localizedCaseInsensitiveContains("thermistor")
            || message.localizedCaseInsensitiveContains("heating") {
            return TranslatedError(
                matched: true, code: "heater_fault",
                titleAR: "خلل في السخان أو الحساس",
                titleEN: "Heater or thermistor fault",
                explanationAR: "Klipper أوقف التسخين لأن الحرارة لم ترتفع كما هو متوقع.",
                explanationEN: "Klipper stopped heating because the temperature did not rise as expected.",
                causesAR: ["سلك الحساس مفكوك", "المروحة بتبرد الفوهة زيادة", "السخان تالف"],
                checksAR: ["افحص كابل الثرمستور", "تأكد من تركيب عازل السيليكون", "أعد التشغيل بـ FIRMWARE_RESTART"],
                severity: "error",
                original: message
            )
        }
        return TranslatedError(
            matched: false, code: "",
            titleAR: "رسالة غير معروفة",
            titleEN: "Unrecognised message",
            explanationAR: "لا توجد ترجمة محفوظة لهذه الرسالة. النص الأصلي معروض كما هو.",
            explanationEN: "No stored translation for this message. The original text is shown as-is.",
            causesAR: [], checksAR: [], severity: "info",
            original: message
        )
    }
}
