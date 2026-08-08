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
