import Foundation

/// Types shared between the main app and the widget extension.
/// This file is compiled into BOTH targets - keep it dependency free.

public enum PrinterState: String, Codable, CaseIterable, Sendable {
    case standby
    case printing
    case paused
    case complete
    case cancelled
    case error
    case unknown

    public init(moonraker raw: String?) {
        guard let raw, let value = PrinterState(rawValue: raw.lowercased()) else {
            self = .unknown
            return
        }
        self = value
    }

    public var isActive: Bool { self == .printing || self == .paused }

    /// Localisation key describing the state.
    public var localizationKey: String { "printer.state.\(rawValue)" }

    public var symbolName: String {
        switch self {
        case .standby: return "checkmark.circle"
        case .printing: return "printer.fill"
        case .paused: return "pause.circle.fill"
        case .complete: return "checkmark.seal.fill"
        case .cancelled: return "xmark.circle"
        case .error: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        }
    }
}

public enum KlippyState: String, Codable, Sendable {
    case ready
    case startup
    case shutdown
    case error
    case disconnected
    case unknown

    public init(raw: String?) {
        guard let raw, let value = KlippyState(rawValue: raw.lowercased()) else {
            self = .unknown
            return
        }
        self = value
    }

    public var isReady: Bool { self == .ready }
    public var localizationKey: String { "klippy.state.\(rawValue)" }
}

public enum PowerState: String, Codable, Sendable {
    case on
    case off
    case unknown
    case error

    public init(raw: String?) {
        guard let raw, let value = PowerState(rawValue: raw.lowercased()) else {
            self = .unknown
            return
        }
        self = value
    }

    public var localizationKey: String { "power.state.\(rawValue)" }
}

/// A compact, Codable snapshot that the app writes into the shared App Group so
/// the widget can render without any networking of its own.
public struct PrinterWidgetSnapshot: Codable, Equatable, Sendable {
    public var printerName: String
    public var isOnline: Bool
    public var state: PrinterState
    public var klippy: KlippyState
    public var power: PowerState
    public var filename: String
    public var progress: Double
    public var nozzleActual: Double
    public var nozzleTarget: Double
    public var bedActual: Double
    public var bedTarget: Double
    public var estimatedRemaining: TimeInterval?
    public var updatedAt: Date

    public init(
        printerName: String = "Neptune 3 Plus",
        isOnline: Bool = false,
        state: PrinterState = .unknown,
        klippy: KlippyState = .unknown,
        power: PowerState = .unknown,
        filename: String = "",
        progress: Double = 0,
        nozzleActual: Double = 0,
        nozzleTarget: Double = 0,
        bedActual: Double = 0,
        bedTarget: Double = 0,
        estimatedRemaining: TimeInterval? = nil,
        updatedAt: Date = Date()
    ) {
        self.printerName = printerName
        self.isOnline = isOnline
        self.state = state
        self.klippy = klippy
        self.power = power
        self.filename = filename
        self.progress = progress
        self.nozzleActual = nozzleActual
        self.nozzleTarget = nozzleTarget
        self.bedActual = bedActual
        self.bedTarget = bedTarget
        self.estimatedRemaining = estimatedRemaining
        self.updatedAt = updatedAt
    }

    public static let placeholder = PrinterWidgetSnapshot(
        isOnline: true,
        state: .printing,
        klippy: .ready,
        power: .on,
        filename: "benchy.gcode",
        progress: 0.42,
        nozzleActual: 209.4,
        nozzleTarget: 210,
        bedActual: 59.8,
        bedTarget: 60,
        estimatedRemaining: 3_120
    )
}

/// Shared container used by the app, the widget and App Intents.
public enum SharedStore {
    /// Must match the App Group capability configured on both targets.
    public static let appGroupIdentifier = "group.com.neptune.remote"
    private static let snapshotKey = "printer.snapshot"

    public static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    public static func save(_ snapshot: PrinterWidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    public static func loadSnapshot() -> PrinterWidgetSnapshot? {
        guard let data = defaults.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(PrinterWidgetSnapshot.self, from: data)
    }
}
