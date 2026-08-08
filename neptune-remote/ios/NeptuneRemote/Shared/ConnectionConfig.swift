import Foundation

/// Network coordinates of the Raspberry Pi. Shared with the widget/App Intents
/// through the App Group so background actions can reach the printer too.
public struct ConnectionConfig: Codable, Equatable, Sendable {
    public var host: String
    public var moonrakerPort: Int
    public var backendPort: Int
    public var useHTTPS: Bool

    /// Default matches the documented Tailscale address of the user's Pi.
    public static let `default` = ConnectionConfig(
        host: "100.78.2.66",
        moonrakerPort: 80,
        backendPort: 8710,
        useHTTPS: false
    )

    public init(host: String, moonrakerPort: Int, backendPort: Int, useHTTPS: Bool) {
        self.host = host
        self.moonrakerPort = moonrakerPort
        self.backendPort = backendPort
        self.useHTTPS = useHTTPS
    }

    public var scheme: String { useHTTPS ? "https" : "http" }
    public var webSocketScheme: String { useHTTPS ? "wss" : "ws" }

    private func url(port: Int, scheme: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        // Omit the default port so nginx-based setups produce clean URLs.
        let isDefault = (scheme == "http" || scheme == "ws") ? port == 80 : port == 443
        components.port = isDefault ? nil : port
        return components.url
    }

    public var moonrakerBaseURL: URL? { url(port: moonrakerPort, scheme: scheme) }
    public var backendBaseURL: URL? { url(port: backendPort, scheme: scheme) }

    public var moonrakerWebSocketURL: URL? {
        url(port: moonrakerPort, scheme: webSocketScheme)?.appendingPathComponent("websocket")
    }

    public var backendWebSocketURL: URL? {
        url(port: backendPort, scheme: webSocketScheme)?.appendingPathComponent("ws")
    }

    public var isValid: Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard (1...65535).contains(moonrakerPort), (1...65535).contains(backendPort) else { return false }
        return moonrakerBaseURL != nil
    }
}

public extension SharedStore {
    private static var connectionKey: String { "connection.config" }

    static func save(_ config: ConnectionConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: connectionKey)
    }

    static func loadConnection() -> ConnectionConfig {
        guard let data = defaults.data(forKey: connectionKey),
              let config = try? JSONDecoder().decode(ConnectionConfig.self, from: data)
        else { return .default }
        return config
    }
}
