import Foundation

// Mirrors `/api/alerts/*` on the Pi.
//
// The split matters: `AlertPreferences` is what the phone may change, and it is
// what governs notifications sent *out of the house* - to ntfy or Telegram -
// which are the only ones that arrive when the app is closed. The per-event
// toggles in AppSettings are separate and only govern local notifications
// raised while the app is running. Two layers, two jobs; conflating them is why
// people end up with alerts they think are on.
//
// No credential ever appears in any of these. Tokens live in config.yaml on the
// Pi and the API reports only whether a channel is configured.

struct AlertStatus: Decodable, Equatable {
    var notifications: AlertNotificationStatus = .init()
    var heartbeat: HeartbeatStatus = .init()
    var reachableWhenAppIsClosed: Bool = false
    var advice: AlertAdvice = .init()

    enum CodingKeys: String, CodingKey {
        case notifications, heartbeat, advice
        case reachableWhenAppIsClosed = "reachable_when_app_is_closed"
    }
}

struct AlertNotificationStatus: Decodable, Equatable {
    var enabled: Bool = false
    var language: String = "ar"
    var channels: [AlertChannel] = []
    var configured: Bool = false
    /// Channels switched on but not usable - an enabled ntfy with no topic is
    /// the likeliest way to believe you have alerts when you do not.
    var warnings: [String] = []
    var preferences: AlertPreferences = .init()
    var availableEvents: [String] = []
    var criticalEvents: [String] = []
    var defaultEvents: [String] = []

    enum CodingKeys: String, CodingKey {
        case enabled, language, channels, configured, warnings, preferences
        case availableEvents = "available_events"
        case criticalEvents = "critical_events"
        case defaultEvents = "default_events"
    }
}

struct AlertChannel: Decodable, Equatable, Identifiable {
    var name: String = ""
    var sent: Int = 0
    var failed: Int = 0
    var lastError: String = ""
    var lastSuccessAt: Double = 0

    var id: String { name }

    var isHealthy: Bool { lastError.isEmpty }

    enum CodingKeys: String, CodingKey {
        case name, sent, failed
        case lastError = "last_error"
        case lastSuccessAt = "last_success_at"
    }
}

struct HeartbeatStatus: Decodable, Equatable {
    var enabled: Bool = false
    var intervalSeconds: Double = 0
    var lastPingAt: Double?
    var secondsSinceLastPing: Double?
    var successes: Int = 0
    var failures: Int = 0
    var lastError: String = ""

    enum CodingKeys: String, CodingKey {
        case enabled, successes, failures
        case intervalSeconds = "interval_seconds"
        case lastPingAt = "last_ping_at"
        case secondsSinceLastPing = "seconds_since_last_ping"
        case lastError = "last_error"
    }
}

struct AlertAdvice: Decodable, Equatable {
    var level: String = "info"   // ok | info | warning
    var ar: String = ""
    var en: String = ""

    var text: String { L.isArabic ? ar : en }
}

struct AlertPreferences: Codable, Equatable {
    var enabled: Bool = true
    var events: [String] = []
    var minPriority: String = "low"
    var quietHoursEnabled: Bool = false
    var quietStartHour: Int = 23
    var quietEndHour: Int = 8

    enum CodingKeys: String, CodingKey {
        case enabled, events
        case minPriority = "min_priority"
        case quietHoursEnabled = "quiet_hours_enabled"
        case quietStartHour = "quiet_start_hour"
        case quietEndHour = "quiet_end_hour"
    }
}

struct AlertPreferencesResponse: Decodable {
    var preferences: AlertPreferences
}

struct AlertTestResult: Decodable {
    var sent: Bool = false
    var reason: String = ""
    var channels: [AlertTestChannelResult] = []
}

struct AlertTestChannelResult: Decodable, Identifiable {
    var channel: String = ""
    var ok: Bool = false
    var error: String = ""

    var id: String { channel }
}

// MARK: - Outages

struct OutageStatus: Decodable, Equatable {
    var enabled: Bool = false
    var serialPath: String = ""
    /// nil when no MCU device path is known - the backend refuses to guess a
    /// cause without one rather than calling every shutdown a power cut.
    var serialPresent: Bool?
    var inOutage: Bool = false
    var tracking: OutageSnapshot?
    var last: OutageRecord?
    var records: [OutageRecord] = []

    enum CodingKeys: String, CodingKey {
        case enabled, tracking, last, records
        case serialPath = "serial_path"
        case serialPresent = "serial_present"
        case inOutage = "in_outage"
    }
}

struct OutageSnapshot: Decodable, Equatable {
    var filename: String = ""
    var startedAt: Double = 0
    var updatedAt: Double = 0
    var progress: Double = 0
    var currentLayer: Int?
    var totalLayer: Int?
    var zHeight: Double = 0
    var filamentUsedMm: Double = 0

    var layerText: String {
        guard let currentLayer else { return "" }
        guard let totalLayer, totalLayer > 0 else { return "\(currentLayer)" }
        return "\(currentLayer)/\(totalLayer)"
    }

    enum CodingKeys: String, CodingKey {
        case filename, progress
        case startedAt = "started_at"
        case updatedAt = "updated_at"
        case currentLayer = "current_layer"
        case totalLayer = "total_layer"
        case zHeight = "z_height"
        case filamentUsedMm = "filament_used_mm"
    }
}

struct OutageRecord: Decodable, Equatable, Identifiable {
    var id: String = ""
    var cause: String = ""
    var causeAr: String = ""
    var adviceAr: String = ""
    var detectedAt: Double = 0
    var wasPrinting: Bool = false
    var snapshot: OutageSnapshot?
    var detail: String = ""
    var restoredAt: Double?
    var acknowledged: Bool = false

    /// True for the causes that mean mains, not software.
    var isPowerRelated: Bool {
        cause == "printer_power" || cause == "pi_power"
    }

    var systemImage: String {
        switch cause {
        case "printer_power", "pi_power": return "bolt.slash.fill"
        case "mcu_lost": return "cable.connector.slash"
        case "service_restart": return "arrow.clockwise"
        default: return "exclamationmark.triangle.fill"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, cause, detail, snapshot, acknowledged
        case causeAr = "cause_ar"
        case adviceAr = "advice_ar"
        case detectedAt = "detected_at"
        case wasPrinting = "was_printing"
        case restoredAt = "restored_at"
    }
}
