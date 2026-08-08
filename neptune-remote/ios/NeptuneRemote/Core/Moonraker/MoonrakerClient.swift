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

    /// Whichever candidate answered last. Sticky, so the whole session does not
    /// pay the cost of probing the nginx vhost before every single request.
    private var resolvedBase: URL?

    func update(config: ConnectionConfig, apiKey: String) {
        self.config = config
        self.apiKey = apiKey
        resolvedBase = nil
    }

    /// The endpoint currently in use: the resolved one once something has
    /// answered, the configured one before that.
    var baseURL: URL? { resolvedBase ?? config.moonrakerBaseURL }

    /// `true` when requests are going to Moonraker's own port rather than
    /// through the nginx vhost. Surfaced in diagnostics so a broken proxy is
    /// visible rather than merely worked around.
    var isUsingDirectPort: Bool {
        guard let resolvedBase else { return false }
        return resolvedBase.port == ConnectionConfig.directMoonrakerPort
    }

    private var headers: [String: String] {
        apiKey.isEmpty ? [:] : ["X-Api-Key": apiKey]
    }

    private func url(_ path: String) throws -> URL {
        guard let base = baseURL else { throw APIError.notConfigured }
        return base.appendingPathComponent(path)
    }

    // MARK: - Endpoint resolution

    /// Probes the configured Moonraker endpoint and then the direct daemon port,
    /// returning the server info from whichever answers first.
    ///
    /// Only transport-level failures move on to the next candidate. An HTTP
    /// answer - including 401 - means we found Moonraker, and retrying on
    /// another port would just turn a precise error into a vague one.
    @discardableResult
    func resolveBase() async throws -> MoonrakerServerInfo {
        var firstError: Error?

        for candidate in config.moonrakerBaseURLCandidates {
            do {
                let info = try await http.decode(
                    MoonrakerEnvelope<MoonrakerServerInfo>.self,
                    from: HTTPClient.Request(
                        url: candidate.appendingPathComponent("server/info"),
                        headers: headers,
                        timeout: 8
                    )
                ).result
                resolvedBase = candidate
                return info
            } catch let error as APIError where error.isTransportFailure {
                firstError = firstError ?? error
                continue
            } catch {
                // Moonraker answered; this candidate is the right one.
                resolvedBase = candidate
                throw error
            }
        }

        resolvedBase = nil
        throw firstError ?? APIError.cannotConnect(config.host)
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
        // Before anything has answered, and again after a transport failure
        // cleared the cache, this also picks the endpoint for every later call.
        guard resolvedBase != nil else { return try await resolveBase() }
        do {
            return try await http.decode(
                MoonrakerEnvelope<MoonrakerServerInfo>.self,
                from: try request("server/info")
            ).result
        } catch let error as APIError where error.isTransportFailure {
            // The endpoint that used to work has gone away - nginx restarted,
            // the Pi rebooted. Re-probe rather than failing for the session.
            resolvedBase = nil
            return try await resolveBase()
        }
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

    // MARK: - Capability discovery

    /// Klipper's view of the loaded printer.cfg.
    ///
    /// `configfile.settings` is the parsed and normalised config - lowercased
    /// keys, numbers already typed - which is why it is preferred over reading
    /// the raw file. `save_config_pending` tells us there are tuning values
    /// Klipper has not written back yet.
    struct ConfigFile: Decodable {
        var settings: [String: ConfigValue] = [:]
        var config: [String: ConfigValue] = [:]
        var saveConfigPending: Bool = false

        enum CodingKeys: String, CodingKey {
            case settings, config
            case saveConfigPending = "save_config_pending"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            settings = try container.decodeIfPresent([String: ConfigValue].self, forKey: .settings) ?? [:]
            config = try container.decodeIfPresent([String: ConfigValue].self, forKey: .config) ?? [:]
            saveConfigPending = try container.decodeIfPresent(Bool.self, forKey: .saveConfigPending) ?? false
        }

        /// `settings` when Klipper provided it, falling back to the raw
        /// `config` section map on the older builds that only expose that.
        var effective: [String: ConfigValue] { settings.isEmpty ? config : settings }
    }

    func configFile() async throws -> ConfigFile {
        struct Status: Decodable { let configfile: ConfigFile }
        struct Payload: Decodable { let status: Status }
        return try await http.decode(
            MoonrakerEnvelope<Payload>.self,
            from: try request(
                "printer/objects/query",
                query: [URLQueryItem(name: "configfile", value: nil)],
                timeout: 20
            )
        ).result.status.configfile
    }

    /// Saved bed mesh profiles, which live in the runtime object rather than in
    /// the config sections.
    func bedMeshProfiles() async throws -> [String] {
        struct Mesh: Decodable {
            let profiles: [String: ConfigValue]?
            enum CodingKeys: String, CodingKey { case profiles }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                profiles = try container.decodeIfPresent([String: ConfigValue].self, forKey: .profiles)
            }
        }
        struct Status: Decodable {
            let bedMesh: Mesh?
            enum CodingKeys: String, CodingKey { case bedMesh = "bed_mesh" }
        }
        struct Payload: Decodable { let status: Status }
        let result = try await http.decode(
            MoonrakerEnvelope<Payload>.self,
            from: try request(
                "printer/objects/query",
                query: [URLQueryItem(name: "bed_mesh", value: nil)]
            )
        ).result
        guard let profiles = result.status.bedMesh?.profiles else { return [] }
        return Array(profiles.keys)
    }

    /// Reads everything needed to describe this printer and assembles it.
    func discoverCapabilities(homedAxes: String = "") async throws -> PrinterCapabilities {
        let objects = try await objectList()
        let configuration = try await configFile()
        // Only ask for mesh profiles when the module is actually loaded.
        let profiles = objects.contains("bed_mesh")
            ? ((try? await bedMeshProfiles()) ?? [])
            : []
        let version = (try? await printerInfo())?.softwareVersion ?? ""

        return CapabilityDiscovery.build(
            settings: configuration.effective,
            objects: objects,
            homedAxes: homedAxes,
            meshProfiles: profiles,
            klipperVersion: version
        )
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
