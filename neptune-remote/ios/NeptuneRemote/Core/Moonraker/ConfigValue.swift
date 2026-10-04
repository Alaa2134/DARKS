import Foundation

/// A decoded JSON value of unknown shape.
///
/// Klipper's `configfile.settings` is the parsed printer.cfg: an arbitrary
/// nested dictionary whose keys depend entirely on what the user has in their
/// config. It cannot be modelled as a fixed Swift struct, because the whole
/// point is that we do not know in advance which sections exist.
enum ConfigValue: Decodable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([ConfigValue])
    case object([String: ConfigValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ConfigValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: ConfigValue].self) {
            self = .object(value)
        } else {
            self = .null
        }
    }

    // MARK: - Typed access

    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .number(let value): return Self.format(value)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
    }

    /// Klipper reports numbers as JSON numbers, but a value a user wrote as
    /// `"245"` in a template can come back as a string, so both are accepted.
    var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value.trimmingCharacters(in: .whitespaces))
        case .bool(let value): return value ? 1 : 0
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .number(let value): return value != 0
        case .string(let value):
            switch value.lowercased().trimmingCharacters(in: .whitespaces) {
            case "true", "1", "yes", "on": return true
            case "false", "0", "no", "off": return false
            default: return nil
            }
        default: return nil
        }
    }

    var objectValue: [String: ConfigValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [ConfigValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// Klipper writes coordinate pairs both as `[x, y]` and as the string
    /// `"x, y"`, depending on the section. Normalise both.
    var numberList: [Double]? {
        switch self {
        case .array(let values):
            let numbers = values.compactMap(\.doubleValue)
            return numbers.count == values.count ? numbers : nil
        case .string(let value):
            let parts = value.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            let numbers = parts.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            return numbers.isEmpty ? nil : numbers
        case .number(let value):
            return [value]
        default:
            return nil
        }
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15
            ? String(Int(value))
            : String(value)
    }
}

extension Dictionary where Key == String, Value == ConfigValue {
    /// Case-insensitive lookup. Klipper lowercases section and option names in
    /// `configfile.settings`, but not everywhere and not in every version, so
    /// reading is tolerant of either.
    func value(_ key: String) -> ConfigValue? {
        if let exact = self[key] { return exact }
        let wanted = key.lowercased()
        return first { $0.key.lowercased() == wanted }?.value
    }

    func double(_ key: String) -> Double? { value(key)?.doubleValue }
    func string(_ key: String) -> String? { value(key)?.stringValue }
    func bool(_ key: String) -> Bool? { value(key)?.boolValue }
    func numbers(_ key: String) -> [Double]? { value(key)?.numberList }
    func section(_ key: String) -> [String: ConfigValue]? { value(key)?.objectValue }
}
