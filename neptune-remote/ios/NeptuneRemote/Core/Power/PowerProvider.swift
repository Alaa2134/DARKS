import Foundation

struct PowerReading: Equatable {
    var state: PowerState = .unknown
    var available: Bool = false
    var provider: PowerProviderKind = .none
    var device: String = ""
    var message: String = ""

    static let unavailable = PowerReading(
        state: .unknown, available: false, provider: .none, message: L.t("power.not_configured")
    )
}

/// Anything that can switch the printer's mains power.
protocol PowerProviding: Sendable {
    var kind: PowerProviderKind { get }
    func status() async throws -> PowerReading
    func turnOn() async throws -> PowerReading
    func turnOff(force: Bool) async throws -> PowerReading
}

// MARK: - Backend (owns the Tuya / Smart Life credentials)

struct BackendPowerProvider: PowerProviding {
    let kind: PowerProviderKind = .backend
    let client: BackendClient

    func status() async throws -> PowerReading {
        let result = try await client.powerStatus()
        return PowerReading(
            state: PowerState(raw: result.state),
            available: result.available,
            provider: .backend,
            device: result.device,
            message: result.message
        )
    }

    func turnOn() async throws -> PowerReading {
        let result = try await client.powerOn()
        return PowerReading(
            state: PowerState(raw: result.state),
            available: true,
            provider: .backend,
            message: result.message
        )
    }

    func turnOff(force: Bool) async throws -> PowerReading {
        let result = try await client.powerOff(force: force)
        return PowerReading(
            state: PowerState(raw: result.state),
            available: true,
            provider: .backend,
            message: result.message
        )
    }
}

// MARK: - Moonraker [power ...] device

struct MoonrakerPowerProvider: PowerProviding {
    let kind: PowerProviderKind = .moonraker
    let client: MoonrakerClient
    let device: String

    func status() async throws -> PowerReading {
        let devices = try await client.powerDevices()
        guard let match = devices.first(where: { $0.device == device }) else {
            let names = devices.map(\.device).joined(separator: ", ")
            return PowerReading(
                state: .unknown,
                available: false,
                provider: .moonraker,
                device: device,
                message: L.t("power.moonraker_missing_device") + (names.isEmpty ? "" : " (\(names))")
            )
        }
        return PowerReading(
            state: PowerState(raw: match.status),
            available: true,
            provider: .moonraker,
            device: device
        )
    }

    func turnOn() async throws -> PowerReading {
        let state = try await client.setPowerDevice(device, action: "on")
        return PowerReading(state: PowerState(raw: state), available: true, provider: .moonraker, device: device)
    }

    func turnOff(force: Bool) async throws -> PowerReading {
        let state = try await client.setPowerDevice(device, action: "off")
        return PowerReading(state: PowerState(raw: state), available: true, provider: .moonraker, device: device)
    }
}

// MARK: - Generic HTTP webhook

struct WebhookPowerProvider: PowerProviding {
    let kind: PowerProviderKind = .webhook
    let onURL: String
    let offURL: String
    let statusURL: String
    let http: HTTPClient

    private func call(_ urlString: String, method: String) async throws -> Data {
        guard let url = URL(string: urlString), url.scheme != nil else { throw APIError.invalidURL }
        let (data, _) = try await http.data(
            HTTPClient.Request(url: url, method: method, timeout: 20)
        )
        return data
    }

    func status() async throws -> PowerReading {
        guard !statusURL.isEmpty else {
            return PowerReading(
                state: .unknown,
                available: !onURL.isEmpty && !offURL.isEmpty,
                provider: .webhook,
                message: L.t("power.webhook_no_status")
            )
        }
        let data = try await call(statusURL, method: "GET")
        let text = (String(data: data, encoding: .utf8) ?? "").lowercased()
        let state: PowerState
        if text.contains("\"on\"") || text.contains(":true") || text.trimmingCharacters(in: .whitespacesAndNewlines) == "on" {
            state = .on
        } else if text.contains("\"off\"") || text.contains(":false") || text.trimmingCharacters(in: .whitespacesAndNewlines) == "off" {
            state = .off
        } else {
            state = .unknown
        }
        return PowerReading(state: state, available: true, provider: .webhook, device: "webhook")
    }

    func turnOn() async throws -> PowerReading {
        _ = try await call(onURL, method: "POST")
        return PowerReading(state: .on, available: true, provider: .webhook, device: "webhook")
    }

    func turnOff(force: Bool) async throws -> PowerReading {
        _ = try await call(offURL, method: "POST")
        return PowerReading(state: .off, available: true, provider: .webhook, device: "webhook")
    }
}

// MARK: - Demo

actor DemoPowerProvider: PowerProviding {
    nonisolated var kind: PowerProviderKind { .demo }
    private var isOn = true

    init(initial: Bool = true) { isOn = initial }

    func status() async throws -> PowerReading {
        PowerReading(state: isOn ? .on : .off, available: true, provider: .demo, device: "demo-switch")
    }

    func turnOn() async throws -> PowerReading {
        isOn = true
        return try await status()
    }

    func turnOff(force: Bool) async throws -> PowerReading {
        isOn = false
        return try await status()
    }
}

// MARK: - Disabled

struct NoPowerProvider: PowerProviding {
    let kind: PowerProviderKind = .none

    func status() async throws -> PowerReading { .unavailable }
    func turnOn() async throws -> PowerReading { throw APIError.unknown(L.t("power.not_configured")) }
    func turnOff(force: Bool) async throws -> PowerReading { throw APIError.unknown(L.t("power.not_configured")) }
}
