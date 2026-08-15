import Foundation
import SwiftUI

/// Runtime localisation with an in-app language override.
///
/// `Bundle.main` follows the system language. When the user picks Arabic or
/// English explicitly we resolve the matching `.lproj` bundle and read strings
/// from it, so the whole UI switches without restarting the app.
enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case system
    case english = "en"
    case arabic = "ar"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return L.t("settings.language.system")
        case .english: return "English"
        case .arabic: return "العربية"
        }
    }

    var localeIdentifier: String? {
        switch self {
        case .system: return nil
        case .english: return "en"
        case .arabic: return "ar"
        }
    }

    var layoutDirection: LayoutDirection? {
        switch self {
        case .arabic: return .rightToLeft
        case .english: return .leftToRight
        case .system: return nil
        }
    }
}

final class LocalizationManager {
    static let shared = LocalizationManager()

    private(set) var bundle: Bundle = .main
    private(set) var language: AppLanguage = .system

    private init() {}

    func apply(_ language: AppLanguage) {
        self.language = language
        guard let code = language.localeIdentifier,
              let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let localized = Bundle(path: path)
        else {
            bundle = .main
            return
        }
        bundle = localized
    }

    func string(_ key: String) -> String {
        let value = bundle.localizedString(forKey: key, value: nil, table: nil)
        if value == key, bundle !== Bundle.main {
            return Bundle.main.localizedString(forKey: key, value: key, table: nil)
        }
        return value
    }
}

/// Short accessor used across the app: `L.t("home.title")`.
enum L {
    static func t(_ key: String) -> String {
        LocalizationManager.shared.string(key)
    }

    static func t(_ key: String, _ arguments: CVarArg...) -> String {
        let format = LocalizationManager.shared.string(key)
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale.current, arguments: arguments)
    }

    /// Whether the UI is currently Arabic.
    ///
    /// Used only for text the *backend* sends pre-translated - outage advice,
    /// Klipper explanations - where there is no key to look up, just an `ar`
    /// and an `en` field to choose between. Everything with a string key should
    /// go through `L.t` instead.
    static var isArabic: Bool {
        switch LocalizationManager.shared.language {
        case .arabic: return true
        case .english: return false
        case .system:
            return Locale.preferredLanguages.first?.hasPrefix("ar") ?? false
        }
    }
}

extension Text {
    /// `Text(localized: "home.title")`
    init(localized key: String) {
        self.init(L.t(key))
    }
}
