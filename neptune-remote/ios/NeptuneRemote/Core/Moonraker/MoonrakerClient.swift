import Foundation

/// Direct Moonraker REST client.
///
/// Endpoints follow https://moonraker.readthedocs.io/en/latest/web_api/ exactly.
actor MoonrakerClient {
    private var config: ConnectionConfig
    private var apiKey: String
    private let http: HTTPClient

    init(config: ConnectionConfig, apiKey: String = "", http: HTTPClient = HTTPClient()) {
        self.config = config
        self.apiKey = apiKey
        self.http = http
    }

    func update(config: ConnectionConfig, apiKey: String) {
        self.config = config
        self.apiKey = apiKey
    }

    var baseURL: URL? { config.moonrakerBaseURL }

    private var headers: [String: String] {
        apiKey.isEmpty ? [:] : ["X-Api-Key": apiKey]
    }

    private func url(_ path: String) throws -> URL {
        guard let base = config.moonrakerBaseURL else { throw APIError.notConfigured }
        return base.appendingPathComponent(path)
    }

    private func request(
        _ path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = nil,
        timeout: TimeInterval? = nil
    ) throws -> HTTPClient.Request {
        HTTPClient.Request(
            url: try url(path),
            method: method,
            query: query,
            headers: headers,
            body: body,
            contentType: contentType,
            timeout: timeout
        )
    }

    // MARK: - Server / printer info

    func serverInfo() async throws -> MoonrakerServerInfo {
        try await http.decode(
            MoonrakerEnvelope<MoonrakerServerInfo>.self,
            from: try request("server/info")
        ).result
    }

    func printerInfo() async throws -> MoonrakerPrinterInfo {
        try await http.decode(
            MoonrakerEnvelope<MoonrakerPrinterInfo>.self,
            from: try request("printer/info")
        ).result
    }

    func objectList() async throws -> [String] {
        struct Payload: Decodable { let objects: [String] }
        return try await http.decode(
            MoonrakerEnvelope<Payload>.self,
            from: try request("printer/objects/list")
        ).result.objects
    }

    // MARK: - Status

    func queryObjects(_ objects: [String] = PrinterObjects.queryObjects) async throws -> PrinterObjects {
        // Moonraker's GET form: /printer/objects/query?print_stats&toolhead&...
        let query = objects.map { URLQueryItem(name: $0, value: nil) }
        return try await http.decode(
            MoonrakerEnvelope<PrinterObjectsQueryResult>.self,
            from: try request("printer/objects/query", query: query)
        ).result.status
    }

    /// Full snapshot: server info + objects, tolerant of a disconnected Klipper.
    func snapshot() async throws -> PrinterSnapshot {
        let info = try await serverInfo()
        guard info.klippyConnected else {
            var snapshot = PrinterSnapshot()
            snapshot.isOnline = true
            snapshot.klippy = KlippyState(raw: info.klippyState)
            snapshot.state = .error
            snapshot.errorMessage = L.t("error.klipper_not_ready")
            snapshot.lastUpdate = Date()
            return snapshot
        }
        let objects = try await queryObjects()
        return PrinterSnapshot.make(objects: objects, serverInfo: info)
    }

    func isReachable() async -> Bool {
        (try? await serverInfo()) != nil
    }

    // MARK: - Print control

    @discardableResult
    func runGCode(_ script: String) async throws -> Bool {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw APIError.unknown(L.t("terminal.empty_command")) }
        _ = try await http.data(
            try request(
                "printer/gcode/script",
                method: "POST",
                query: [URLQueryItem(name: "script", value: trimmed)],
                timeout: 60
            )
        )
        return true
    }

    func startPrint(filename: String) async throws {
        _ = try await http.data(
            try request(
                "printer/print/start",
                method: "POST",
                query: [URLQueryItem(name: "filename", value: filename)],
                timeout: 60
            )
        )
    }

    func pausePrint() async throws {
        _ = try await http.data(try request("printer/print/pause", method: "POST", timeout: 30))
    }

    func resumePrint() async throws {
        _ = try await http.data(try request("printer/print/resume", method: "POST", timeout: 30))
    }

    func cancelPrint() async throws {
        _ = try await http.data(try request("printer/print/cancel", method: "POST", timeout: 30))
    }

    func emergencyStop() async throws {
        _ = try await http.data(try request("printer/emergency_stop", method: "POST", timeout: 10))
    }

    func restartKlipper() async throws {
        _ = try await http.data(try request("printer/restart", method: "POST", timeout: 30))
    }

    func restartFirmware() async throws {
        _ = try await http.data(try request("printer/firmware_restart", method: "POST", timeout: 30))
    }

    func restartService(_ service: String) async throws {
        _ = try await http.data(
            try request(
                "machine/services/restart",
                method: "POST",
                query: [URLQueryItem(name: "service", value: service)],
                timeout: 30
            )
        )
    }

    // MARK: - Files

    func listGCodes() async throws -> [MoonrakerFile] {
        try await http.decode(
            MoonrakerEnvelope<[MoonrakerFile]>.self,
            from: try request(
                "server/files/list",
                query: [URLQueryItem(name: "root", value: "gcodes")],
                timeout: 30
            )
        ).result
    }

    func metadata(filename: String) async throws -> MoonrakerFile {
        try await http.decode(
            MoonrakerEnvelope<MoonrakerFile>.self,
            from: try request(
                "server/files/metadata",
                query: [URLQueryItem(name: "filename", value: filename)]
            )
        ).result
    }

    func deleteGCode(path: String) async throws {
        let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
        _ = try await http.data(
            try request("server/files/gcodes/\(clean)", method: "DELETE", timeout: 30)
        )
    }

    func uploadGCode(filename: String, data: Data, startPrint: Bool = false) async throws -> String {
        guard let base = config.moonrakerBaseURL else { throw APIError.notConfigured }
        let (responseData, _) = try await http.upload(
            url: base.appendingPathComponent("server/files/upload"),
            fieldName: "file",
            filename: filename,
            fileData: data,
            fields: ["root": "gcodes", "print": startPrint ? "true" : "false"],
            headers: headers
        )
        let result = try? JSONDecoder().decode(MoonrakerUploadResult.self, from: responseData)
        return result?.item?.path ?? filename
    }

    func downloadGCode(path: String) async throws -> Data {
        let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let (data, _) = try await http.data(
            try request("server/files/gcodes/\(clean)", timeout: 600)
        )
        return data
    }

    /// URL of an embedded thumbnail so SwiftUI's AsyncImage can load it directly.
    nonisolated func thumbnailURL(for relativePath: String, config: ConnectionConfig) -> URL? {
        guard let base = config.moonrakerBaseURL else { return nil }
        let encoded = relativePath
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relativePath
        return URL(string: "\(base.absoluteString)/server/files/gcodes/\(encoded)")
    }

    func thumbnailURL(for relativePath: String) -> URL? {
        thumbnailURL(for: relativePath, config: config)
    }

    // MARK: - Power devices

    func powerDevices() async throws -> [MoonrakerPowerDevice] {
        try await http.decode(
            MoonrakerEnvelope<MoonrakerPowerDevices>.self,
            from: try request("machine/device_power/devices")
        ).result.devices
    }

    func powerDeviceStatus(_ device: String) async throws -> String? {
        let (data, _) = try await http.data(
            try request(
                "machine/device_power/device",
                query: [URLQueryItem(name: "device", value: device)]
            )
        )
        return Self.extractDeviceState(data: data, device: device)
    }

    func setPowerDevice(_ device: String, action: String) async throws -> String? {
        let (data, _) = try await http.data(
            try request(
                "machine/device_power/device",
                method: "POST",
                query: [
                    URLQueryItem(name: "device", value: device),
                    URLQueryItem(name: "action", value: action)
                ],
                timeout: 30
            )
        )
        return Self.extractDeviceState(data: data, device: device)
    }

    nonisolated static func extractDeviceState(data: Data, device: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? [String: Any]
        else { return nil }
        return result[device] as? String
    }

    // MARK: - Machine

    func machineAction(_ action: String) async throws {
        guard ["shutdown", "reboot"].contains(action) else {
            throw APIError.unknown("Unsupported machine action")
        }
        _ = try await http.data(try request("machine/\(action)", method: "POST", timeout: 20))
    }
}
