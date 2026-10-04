#if DEBUG
import SwiftUI

/// Screenshot mode, for CI only.
///
/// There is no Mac in the loop where this app is written, so the only way to
/// *see* it is to have CI launch it on a simulator and photograph it. Each
/// screenshot is a fresh launch with an environment variable naming the screen,
/// which keeps every picture deterministic: no taps to replay, no state carried
/// over from the shot before.
///
/// Compiled into Debug builds only. The shipped app has no way to be put into
/// this mode, and demo data can never leak into a real printer's session.
///
///     SIMCTL_CHILD_NEPTUNE_SHOWCASE=home xcrun simctl launch booted <bundle>
enum Showcase {
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// The screen to open, or nil for a normal launch.
    static var screen: String? { environment["NEPTUNE_SHOWCASE"] }

    static var isActive: Bool { screen != nil }

    /// Put the app into a known state before anything reads it: demo data,
    /// setup done, and the language and appearance the shot asked for.
    @MainActor
    static func prepare(_ settings: AppSettings) {
        guard let screen else { return }
        settings.demoMode = true
        // The permission prompt would sit on top of every screenshot.
        settings.notificationsEnabled = false
        settings.hasCompletedSetup = screen != "setup"
        settings.advancedMode = screen != "home-simple"
        switch environment["NEPTUNE_SHOWCASE_LANG"] {
        case "en": settings.language = .english
        default: settings.language = .arabic
        }
        switch environment["NEPTUNE_SHOWCASE_APPEARANCE"] {
        case "light": settings.appearance = .light
        case "dark": settings.appearance = .dark
        default: break
        }
    }

    /// Where a screen lives: which tab, and what to push onto it.
    enum Destination {
        case tab(RootView.Tab)
        case pushed(Route)
        case settings
    }

    /// Screens that are not a tab of their own.
    enum Route: Hashable {
        case queue, alerts, slice
    }

    static func destination(for screen: String) -> Destination {
        switch screen {
        case "library": return .tab(.library)
        case "files": return .tab(.files)
        case "camera": return .tab(.camera)
        case "more": return .tab(.more)
        case "queue": return .pushed(.queue)
        case "alerts": return .pushed(.alerts)
        case "slice": return .pushed(.slice)
        case "settings": return .settings
        default: return .tab(.home)
        }
    }
}

extension View {
    /// The pushed screens screenshot mode can reach. Registered on the More
    /// stack so a pushed screen is photographed with its tab bar and back
    /// button, the way it actually looks.
    func withShowcaseDestinations() -> some View {
        navigationDestination(for: Showcase.Route.self) { route in
            switch route {
            case .queue: QueueView()
            case .alerts: AlertSettingsView()
            case .slice: SliceView()
            }
        }
    }
}
#endif
