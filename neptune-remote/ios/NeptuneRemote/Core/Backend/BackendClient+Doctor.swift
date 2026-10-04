import Foundation

/// Endpoints for Fix My Printer, the guided calibration workflows, printer.cfg
/// versioning, G-code inspection and the pre-print check.
///
/// Note what is absent: there is no method here that sends a raw movement
/// command straight to Klipper. `runCommand` posts to the backend's safety
/// engine, which decides what actually reaches the printer.
extension BackendClient {

    // MARK: - Diagnosis

    func diagnose(deep: Bool = false) async throws -> DiagnosisReport {
        try await decode(
            DiagnosisReport.self,
            path: "doctor/diagnose",
            query: [URLQueryItem(name: "deep", value: deep ? "true" : "false")],
            timeout: deep ? 60 : 30
        )
    }

    func healthCards() async throws -> [HealthCard] {
        struct Payload: Decodable { let cards: [HealthCard] }
        return try await decode(Payload.self, path: "doctor/health", timeout: 30).cards
    }

    func queryProbe() async throws -> (triggered: Bool?, known: Bool) {
        struct Payload: Decodable { let triggered: Bool?; let known: Bool }
        let result = try await decode(
            Payload.self, path: "doctor/probe/query", method: "POST", timeout: 20
        )
        return (result.triggered, result.known)
    }

    func queryEndstops() async throws -> [String: String] {
        struct Payload: Decodable { let endstops: [String: String] }
        return try await decode(
            Payload.self, path: "doctor/endstops/query", method: "POST", timeout: 20
        ).endstops
    }

    // MARK: - Safe commands

    /// What *would* happen. Nothing is sent to the printer.
    func evaluateCommand(_ command: String) async throws -> CommandDecision {
        struct Payload: Encodable { let command: String; let force: Bool }
        return try await decode(
            CommandDecision.self,
            path: "doctor/command/evaluate",
            method: "POST",
            body: try await http.encodeBody(Payload(command: command, force: false)),
            timeout: 20
        )
    }

    /// Run a command through the safety engine.
    ///
    /// A refusal arrives as HTTP 409 and surfaces as `APIError` - the command is
    /// never sent to the printer in that case.
    func runCommand(_ command: String, force: Bool = false) async throws -> CommandDecision {
        struct Payload: Encodable { let command: String; let force: Bool }
        return try await decode(
            CommandDecision.self,
            path: "doctor/command/execute",
            method: "POST",
            body: try await http.encodeBody(Payload(command: command, force: force)),
            timeout: 120
        )
    }

    // MARK: - Workflows

    func workflowOptions() async throws -> (available: [WorkflowOption], active: WorkflowRun?) {
        struct Payload: Decodable {
            let available: [WorkflowOption]
            let active: WorkflowRun?
        }
        let result = try await decode(Payload.self, path: "doctor/workflows", timeout: 20)
        return (result.available, result.active)
    }

    func startWorkflow(_ kind: String) async throws -> WorkflowRun {
        struct Payload: Encodable { let kind: String }
        return try await decode(
            WorkflowRun.self,
            path: "doctor/workflows/start",
            method: "POST",
            body: try await http.encodeBody(Payload(kind: kind)),
            timeout: 30
        )
    }

    /// Bed meshing and resonance tests take minutes, hence the long timeout.
    func advanceWorkflow(force: Bool = false) async throws -> WorkflowRun {
        try await decode(
            WorkflowRun.self,
            path: "doctor/workflows/advance",
            method: "POST",
            query: [URLQueryItem(name: "force", value: force ? "true" : "false")],
            timeout: 900
        )
    }

    func confirmWorkflowStep(_ payload: [String: String] = [:]) async throws -> WorkflowRun {
        try await decode(
            WorkflowRun.self,
            path: "doctor/workflows/confirm",
            method: "POST",
            body: try await http.encodeBody(payload),
            timeout: 30
        )
    }

    func repeatWorkflowStep() async throws -> WorkflowRun {
        try await decode(
            WorkflowRun.self, path: "doctor/workflows/repeat", method: "POST", timeout: 900
        )
    }

    func goToWorkflowStep(_ stepID: String) async throws -> WorkflowRun {
        try await decode(
            WorkflowRun.self, path: "doctor/workflows/goto/\(stepID)", method: "POST", timeout: 30
        )
    }

    @discardableResult
    func cancelWorkflow() async throws -> Data {
        try await raw(path: "doctor/workflows/cancel", method: "POST", timeout: 20)
    }

    /// One step of the Z Offset wizard. Negative moves the nozzle down.
    func testZ(delta: Double) async throws -> CommandDecision {
        struct Payload: Encodable { let delta: Double }
        struct Response: Decodable { let decision: CommandDecision; let totalDownMM: Double
            enum CodingKeys: String, CodingKey {
                case decision
                case totalDownMM = "total_down_mm"
            }
        }
        return try await decode(
            Response.self,
            path: "doctor/calibrate/testz",
            method: "POST",
            body: try await http.encodeBody(Payload(delta: delta)),
            timeout: 60
        ).decision
    }

    // MARK: - printer.cfg

    func liveConfig() async throws -> LiveConfig {
        try await decode(LiveConfig.self, path: "config/live", timeout: 40)
    }

    func configVersions() async throws -> (versions: [ConfigVersion], golden: ConfigVersion?) {
        struct Payload: Decodable {
            let versions: [ConfigVersion]
            let golden: ConfigVersion?
        }
        let result = try await decode(Payload.self, path: "config/versions", timeout: 30)
        return (result.versions, result.golden)
    }

    func snapshotConfig(label: String, note: String = "") async throws -> ConfigVersion {
        try await decode(
            ConfigVersion.self,
            path: "config/versions",
            method: "POST",
            body: try await http.encodeBody(["label": label, "note": note]),
            timeout: 40
        )
    }

    func configVersionText(_ versionID: String) async throws -> String {
        struct Payload: Decodable { let text: String }
        return try await decode(
            Payload.self, path: "config/versions/\(versionID)", timeout: 30
        ).text
    }

    func labelConfigVersion(_ versionID: String, label: String, note: String = "") async throws -> ConfigVersion {
        try await decode(
            ConfigVersion.self,
            path: "config/versions/\(versionID)/label",
            method: "POST",
            body: try await http.encodeBody(["label": label, "note": note]),
            timeout: 20
        )
    }

    func markConfigGolden(_ versionID: String) async throws -> ConfigVersion {
        try await decode(
            ConfigVersion.self,
            path: "config/versions/\(versionID)/golden",
            method: "POST",
            timeout: 20
        )
    }

    func deleteConfigVersion(_ versionID: String) async throws {
        _ = try await raw(path: "config/versions/\(versionID)", method: "DELETE", timeout: 20)
    }

    func configDiff(from: String, to: String? = nil) async throws -> ConfigDiff {
        var query = [URLQueryItem(name: "from_id", value: from)]
        if let to { query.append(URLQueryItem(name: "to_id", value: to)) }
        return try await decode(ConfigDiff.self, path: "config/diff", query: query, timeout: 30)
    }

    /// Two-phase on purpose: the first call returns the diff for review, and
    /// only a call with `confirm: true` writes anything.
    func restoreConfig(versionID: String?, confirm: Bool) async throws -> ConfigRestoreResult {
        struct Payload: Encodable {
            let versionID: String?
            let confirm: Bool
            enum CodingKeys: String, CodingKey {
                case versionID = "version_id"
                case confirm
            }
        }
        return try await decode(
            ConfigRestoreResult.self,
            path: "config/restore",
            method: "POST",
            body: try await http.encodeBody(Payload(versionID: versionID, confirm: confirm)),
            timeout: 60
        )
    }

    // MARK: - G-code

    func inspectGCode(filename: String) async throws -> GCodeReport {
        try await decode(
            GCodeReport.self,
            path: "gcode/inspect",
            query: [URLQueryItem(name: "filename", value: filename)],
            timeout: 120
        )
    }

    func preflight(filename: String, strict: Bool) async throws -> PreflightReport {
        try await decode(
            PreflightReport.self,
            path: "gcode/preflight",
            query: [
                URLQueryItem(name: "filename", value: filename),
                URLQueryItem(name: "strict", value: strict ? "true" : "false")
            ],
            timeout: 120
        )
    }

    // MARK: - Golden slicer profiles

    func slicerProfiles() async throws -> (profiles: [SlicerProfile], goldenNames: [String]) {
        struct Payload: Decodable {
            let profiles: [SlicerProfile]
            let goldenNames: [String]
            enum CodingKeys: String, CodingKey {
                case profiles
                case goldenNames = "golden_names"
            }
        }
        let result = try await decode(Payload.self, path: "slicer/profiles", timeout: 30)
        return (result.profiles, result.goldenNames)
    }

    func saveSlicerProfile(
        name: String,
        settings: [String: String],
        note: String = ""
    ) async throws -> SlicerProfile {
        struct Payload: Encodable {
            let name: String
            let settings: [String: String]
            let note: String
        }
        return try await decode(
            SlicerProfile.self,
            path: "slicer/profiles",
            method: "POST",
            body: try await http.encodeBody(Payload(name: name, settings: settings, note: note)),
            timeout: 30
        )
    }

    func markSlicerProfileGolden(_ profileID: String) async throws -> SlicerProfile {
        try await decode(
            SlicerProfile.self, path: "slicer/profiles/\(profileID)/golden",
            method: "POST", timeout: 20
        )
    }

    func deleteSlicerProfile(_ profileID: String) async throws {
        _ = try await raw(path: "slicer/profiles/\(profileID)", method: "DELETE", timeout: 20)
    }
}

/// Either "here is what would change" or "it is done".
struct ConfigRestoreResult: Decodable, Equatable {
    let requiresConfirmation: Bool?
    let restored: Bool?
    let version: ConfigVersion?
    let diff: ConfigDiff?

    var needsConfirmation: Bool { requiresConfirmation == true }
    var didRestore: Bool { restored == true }

    enum CodingKeys: String, CodingKey {
        case restored, version, diff
        case requiresConfirmation = "requires_confirmation"
    }
}
