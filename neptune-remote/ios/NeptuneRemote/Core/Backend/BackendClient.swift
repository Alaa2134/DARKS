import Foundation

/// Client for the Raspberry Pi FastAPI backend.
///
/// Used for everything that cannot run on the phone: slicing, Tuya power,
/// Raspberry Pi metrics and print history.
actor BackendClient {
    private(set) var config: ConnectionConfig
    private(set) var token: String
    /// Shared with the endpoint extensions in BackendClient+Library.swift.
    let http: HTTPClient

    init(config: ConnectionConfig, token: String = "", http: HTTPClient = HTTPClient()) {
        self.config = config
        self.token = token
        self.http = http
    }

    func update(config: ConnectionConfig, token: String) {
        self.config = config
        self.token = token
    }

    nonisolated static let apiKeyHeader = "X-API-Key"

    private var headers: [String: String] {
        token.isEmpty ? [:] : [Self.apiKeyHeader: token]
    }

    /// Auth headers for the endpoint extensions (multipart uploads need them).
    func authHeaders() -> [String: String] { headers }

    /// Backend root, or nil when the address has not been configured yet.
    func baseURL() throws -> URL? { config.backendBaseURL }

    private func url(_ path: String) throws -> URL {
        guard let base = config.backendBaseURL else { throw APIError.notConfigured }
        return base.appendingPathComponent("api").appendingPathComponent(path)
    }

    // MARK: - Generic helpers used by the endpoint extensions

    func decode<T: Decodable>(
        _ type: T.Type,
        path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: Data? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> T {
        try await http.decode(
            T.self,
            from: try request(path, method: method, query: query, body: body, timeout: timeout)
        )
    }

    @discardableResult
    func raw(
        path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: Data? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> Data {
        let (data, _) = try await http.data(
            try request(path, method: method, query: query, body: body, timeout: timeout)
        )
        return data
    }

    private func request(
        _ path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: Data? = nil,
        timeout: TimeInterval? = nil
    ) throws -> HTTPClient.Request {
        HTTPClient.Request(
            url: try url(path),
            method: method,
            query: query,
            headers: headers,
            body: body,
            contentType: body == nil ? nil : "application/json",
            timeout: timeout
        )
    }

    private func jsonBody<T: Encodable>(_ value: T) async throws -> Data {
        try await http.encodeBody(value)
    }

    // MARK: - Core

    func health() async throws -> BackendHealth {
        try await http.decode(BackendHealth.self, from: try request("health", timeout: 8))
    }

    func isReachable() async -> Bool {
        (try? await health()) != nil
    }

    func system() async throws -> BackendSystem {
        try await http.decode(BackendSystem.self, from: try request("system"))
    }

    func profiles() async throws -> BackendProfiles {
        try await http.decode(BackendProfiles.self, from: try request("profiles"))
    }

    func slicerInfo() async throws -> BackendSlicerInfo {
        try await http.decode(BackendSlicerInfo.self, from: try request("slicer/info", timeout: 40))
    }

    func printerStatus() async throws -> BackendPrinterStatus {
        try await http.decode(BackendPrinterStatus.self, from: try request("printer/status"))
    }

    func events(limit: Int = 50) async throws -> [BackendPrinterEvent] {
        struct Payload: Decodable { let events: [BackendPrinterEvent] }
        return try await http.decode(
            Payload.self,
            from: try request("printer/events", query: [URLQueryItem(name: "limit", value: "\(limit)")])
        ).events
    }

    // MARK: - Print modes and calibration

    func printModes(printerProfile: String, filamentProfile: String) async throws -> PrintModeList {
        try await http.decode(
            PrintModeList.self,
            from: try request("slice/modes", query: [
                URLQueryItem(name: "printer_profile", value: printerProfile),
                URLQueryItem(name: "filament_profile", value: filamentProfile),
            ], timeout: 20)
        )
    }

    func calibrationTests() async throws -> [CalibrationTestSummary] {
        struct Payload: Decodable { let tests: [CalibrationTestSummary] }
        return try await http.decode(
            Payload.self, from: try request("calibration/tests", timeout: 20)
        ).tests
    }

    func calibrationTest(
        _ id: String, nozzleTemp: Double, bedTemp: Double
    ) async throws -> CalibrationTest {
        try await http.decode(
            CalibrationTest.self,
            from: try request("calibration/tests/\(id)", query: [
                URLQueryItem(name: "nozzle_temp", value: String(format: "%.0f", nozzleTemp)),
                URLQueryItem(name: "bed_temp", value: String(format: "%.0f", bedTemp)),
            ], timeout: 30)
        )
    }

    func flowResult(measured: Double, expected: Double, currentFlow: Double) async throws -> FlowResult {
        try await http.decode(
            FlowResult.self,
            from: try request("calibration/flow/result", method: "POST", query: [
                URLQueryItem(name: "measured_mm", value: String(format: "%.4f", measured)),
                URLQueryItem(name: "expected_mm", value: String(format: "%.4f", expected)),
                URLQueryItem(name: "current_flow", value: String(format: "%.4f", currentFlow)),
            ])
        )
    }

    func pressureAdvanceResult(
        heightMM: Double, start: Double, step: Double, layerHeight: Double
    ) async throws -> PressureAdvanceResult {
        try await http.decode(
            PressureAdvanceResult.self,
            from: try request("calibration/pressure_advance/result", method: "POST", query: [
                URLQueryItem(name: "height_mm", value: String(format: "%.3f", heightMM)),
                URLQueryItem(name: "start", value: String(format: "%.4f", start)),
                URLQueryItem(name: "step", value: String(format: "%.4f", step)),
                URLQueryItem(name: "layer_height", value: String(format: "%.3f", layerHeight)),
            ])
        )
    }

    /// Photographs the printed patch and measures it. Slow: it takes a
    /// snapshot, so the timeout allows for a camera waking up.
    func inspectFirstLayer() async throws -> FirstLayerReading {
        try await http.decode(
            FirstLayerReading.self,
            from: try request("calibration/first_layer/inspect", method: "POST", timeout: 45)
        )
    }

    func learningReport() async throws -> LearningReport {
        try await http.decode(LearningReport.self, from: try request("history/learning", timeout: 20))
    }

    /// Macros generated from the live printer.cfg. Read-only: the backend
    /// returns text and its reasoning, and installing it stays the user's own
    /// deliberate act.
    func suggestedMacros() async throws -> MacroSuggestions {
        try await http.decode(
            MacroSuggestions.self, from: try request("config/macros/suggest", timeout: 30)
        )
    }

    // MARK: - Camera pan and tilt

    func ptzStatus() async throws -> PTZStatus {
        try await http.decode(PTZStatus.self, from: try request("camera/ptz", timeout: 10))
    }

    /// Starts or stops a movement. Two calls per gesture: the camera keeps
    /// turning until it is told to stop.
    @discardableResult
    func movePTZ(direction: String, action: String, speed: Int = 4) async throws -> Bool {
        _ = try await http.data(
            try request(
                "camera/ptz",
                method: "POST",
                query: [
                    URLQueryItem(name: "direction", value: direction),
                    URLQueryItem(name: "action", value: action),
                    URLQueryItem(name: "speed", value: "\(speed)")
                ],
                timeout: 8
            )
        )
        return true
    }

    func anomalies() async throws -> AnomalyStatus {
        try await http.decode(AnomalyStatus.self, from: try request("printer/anomalies"))
    }

    // MARK: - Alerts

    func alertStatus() async throws -> AlertStatus {
        try await http.decode(AlertStatus.self, from: try request("alerts/status", timeout: 15))
    }

    func alertPreferences() async throws -> AlertPreferences {
        try await http.decode(
            AlertPreferencesResponse.self, from: try request("alerts/preferences")
        ).preferences
    }

    func updateAlertPreferences(_ preferences: AlertPreferences) async throws -> AlertPreferences {
        try await http.decode(
            AlertPreferencesResponse.self,
            from: try request(
                "alerts/preferences",
                method: "PUT",
                body: try await jsonBody(preferences)
            )
        ).preferences
    }

    /// Sends a real message through every configured channel, bypassing quiet
    /// hours and the rate limit - a test a filter could swallow would report
    /// success for something nobody received.
    func sendAlertTest() async throws -> AlertTestResult {
        try await http.decode(
            AlertTestResult.self,
            from: try request("alerts/test", method: "POST", timeout: 40)
        )
    }

    func testHeartbeat() async throws -> HeartbeatStatus {
        try await http.decode(
            HeartbeatStatus.self,
            from: try request("alerts/heartbeat/test", method: "POST", timeout: 30)
        )
    }

    func outageStatus() async throws -> OutageStatus {
        try await http.decode(OutageStatus.self, from: try request("alerts/outage"))
    }

    func acknowledgeOutage(_ id: String) async throws -> OutageStatus {
        struct Payload: Decodable { let outage: OutageStatus }
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return try await http.decode(
            Payload.self,
            from: try request("alerts/outage/\(encoded)/acknowledge", method: "POST")
        ).outage
    }

    // MARK: - Power

    func powerStatus() async throws -> BackendPowerStatus {
        try await http.decode(BackendPowerStatus.self, from: try request("power/status", timeout: 20))
    }

    func powerSafety() async throws -> BackendPowerSafety {
        try await http.decode(BackendPowerSafety.self, from: try request("power/safety"))
    }

    func powerOn() async throws -> BackendPowerAction {
        try await http.decode(
            BackendPowerAction.self,
            from: try request("power/on", method: "POST", timeout: 30)
        )
    }

    func powerOff(force: Bool) async throws -> BackendPowerAction {
        struct Payload: Encodable { let force: Bool }
        return try await http.decode(
            BackendPowerAction.self,
            from: try request(
                "power/off",
                method: "POST",
                body: try await jsonBody(Payload(force: force)),
                timeout: 30
            )
        )
    }

    // MARK: - Models

    func models() async throws -> [BackendModelFile] {
        try await http.decode([BackendModelFile].self, from: try request("models", timeout: 30))
    }

    func uploadModel(filename: String, data: Data) async throws -> BackendUploadResult {
        guard let base = config.backendBaseURL else { throw APIError.notConfigured }
        let (responseData, _) = try await http.upload(
            url: base.appendingPathComponent("api/models/upload"),
            fieldName: "file",
            filename: filename,
            fileData: data,
            headers: headers
        )
        do {
            return try JSONDecoder().decode(BackendUploadResult.self, from: responseData)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }

    func deleteModel(id: String) async throws {
        _ = try await http.data(try request("models/\(id)", method: "DELETE", timeout: 20))
    }

    func downloadModel(id: String) async throws -> Data {
        let (data, _) = try await http.data(try request("models/\(id)/download", timeout: 300))
        return data
    }

    // MARK: - G-code

    func gcodes(includeLocal: Bool = true) async throws -> [BackendGCodeFile] {
        try await http.decode(
            [BackendGCodeFile].self,
            from: try request(
                "gcodes",
                query: [URLQueryItem(name: "include_local", value: includeLocal ? "true" : "false")],
                timeout: 40
            )
        )
    }

    /// One file's metadata, including the colour-change plan.
    ///
    /// Separate from `gcodes()` on purpose: reading the plan means opening the
    /// file, and doing that for every row would make the file list slow on a
    /// Raspberry Pi in exactly the way a file list must not be.
    func gcodeMetadata(path: String) async throws -> BackendGCodeFile {
        try await http.decode(
            BackendGCodeFile.self,
            from: try request(
                "gcodes/metadata",
                query: [URLQueryItem(name: "path", value: path)],
                timeout: 30
            )
        )
    }

    func deleteGCode(path: String) async throws {
        _ = try await http.data(
            try request(
                "gcodes",
                method: "DELETE",
                query: [URLQueryItem(name: "path", value: path)],
                timeout: 30
            )
        )
    }

    func deleteLocalGCode(name: String) async throws {
        _ = try await http.data(try request("gcodes/local/\(name)", method: "DELETE", timeout: 30))
    }

    func sendLocalGCodeToPrinter(name: String, startPrint: Bool) async throws -> BackendUploadResult {
        try await http.decode(
            BackendUploadResult.self,
            from: try request(
                "gcodes/send/\(name)",
                method: "POST",
                query: [URLQueryItem(name: "start_print", value: startPrint ? "true" : "false")],
                timeout: 300
            )
        )
    }

    func downloadLocalGCode(name: String) async throws -> Data {
        let (data, _) = try await http.data(
            try request("gcodes/local/\(name)/download", timeout: 600)
        )
        return data
    }

    // MARK: - Slicing

    func startSlice(_ payload: SliceRequestPayload) async throws -> SliceJob {
        try await http.decode(
            SliceJob.self,
            from: try request("slice", method: "POST", body: try await jsonBody(payload), timeout: 60)
        )
    }

    func sliceJob(id: String) async throws -> SliceJob {
        try await http.decode(SliceJob.self, from: try request("slice/\(id)", timeout: 20))
    }

    func cancelSlice(id: String) async throws {
        _ = try await http.data(try request("slice/\(id)", method: "DELETE", timeout: 20))
    }

    func printSliceOutput(id: String) async throws {
        _ = try await http.data(try request("slice/\(id)/print", method: "POST", timeout: 300))
    }

    func downloadSliceOutput(id: String) async throws -> Data {
        let (data, _) = try await http.data(try request("slice/\(id)/download", timeout: 600))
        return data
    }

    // MARK: - History

    func history(limit: Int = 100) async throws -> HistoryResponse {
        try await http.decode(
            HistoryResponse.self,
            from: try request("history", query: [URLQueryItem(name: "limit", value: "\(limit)")], timeout: 30)
        )
    }

    func deleteHistory(id: Int) async throws {
        _ = try await http.data(try request("history/\(id)", method: "DELETE", timeout: 20))
    }
}
