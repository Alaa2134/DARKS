import Foundation

enum Format {
    /// "1h 24m" / "45s" - compact, locale independent, safe for RTL layouts.
    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "--" }
        let total = Int(seconds.rounded())
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60

        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(secs)s" }
        return "\(secs)s"
    }

    /// "01:24:13" for elapsed timers.
    static func clock(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    static func temperature(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--" }
        return String(format: "%.1f°", value)
    }

    static func temperatureShort(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--" }
        return String(format: "%.0f°", value)
    }

    static func percent(_ fraction: Double?) -> String {
        guard let fraction, fraction.isFinite else { return "--" }
        return String(format: "%.0f%%", fraction * 100)
    }

    static func percentValue(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--" }
        return String(format: "%.0f%%", value)
    }

    static func millimetres(_ value: Double?, decimals: Int = 1) -> String {
        guard let value, value.isFinite else { return "--" }
        return String(format: "%.\(decimals)f mm", value)
    }

    static func coordinate(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--" }
        return String(format: "%.2f", value)
    }

    static func grams(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--" }
        return String(format: "%.1f g", value)
    }

    static func meters(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--" }
        return String(format: "%.2f m", value)
    }

    static func fileSize(_ bytes: Int?) -> String {
        guard let bytes, bytes > 0 else { return "--" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    static func date(_ timestamp: TimeInterval?) -> String {
        guard let timestamp, timestamp > 0 else { return "--" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    static func relativeDate(_ timestamp: TimeInterval?) -> String {
        guard let timestamp, timestamp > 0 else { return "--" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: Date(timeIntervalSince1970: timestamp), relativeTo: Date())
    }

    static func speed(_ mmPerMinute: Double?) -> String {
        guard let mmPerMinute, mmPerMinute.isFinite else { return "--" }
        return String(format: "%.0f mm/s", mmPerMinute / 60.0)
    }
}
