import SwiftUI
import UIKit

@main
struct NeptuneRemoteApp: App {
    @StateObject private var environment = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Self.styleNavigationBars()
    }

    /// Rounded, heavy navigation titles to match the rounded numerals inside.
    ///
    /// `.fontDesign` reaches SwiftUI text only; the navigation bar is UIKit
    /// and keeps the default face unless it is told otherwise - which left
    /// every screen with a title in one typeface and content in another.
    private static func styleNavigationBars() {
        func rounded(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
            return UIFont(descriptor: descriptor, size: size)
        }
        let appearance = UINavigationBar.appearance()
        appearance.largeTitleTextAttributes = [.font: rounded(34, .heavy)]
        appearance.titleTextAttributes = [.font: rounded(17, .bold)]
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
                .environmentObject(environment.settings)
                .environmentObject(environment.printer)
                .environmentObject(environment.files)
                .environmentObject(environment.slicing)
                .environmentObject(environment.history)
                .environmentObject(environment.system)
                .environmentObject(environment.library)
                .environmentObject(environment.media)
                .environmentObject(environment.inventory)
                .environmentObject(environment.support)
                .environmentObject(environment.doctor)
                .environmentObject(environment.alerts)
                .environmentObject(environment.calibration)
                .environmentObject(environment.placement)
                .environmentObject(environment.notifications)
                .environmentObject(environment.errors)
                .preferredColorScheme(environment.settings.colorScheme)
                .environment(\.locale, environment.settings.locale)
                .environment(\.layoutDirection, environment.settings.layoutDirection)
                .tint(Theme.accent)
                // Rounded numerals: temperatures, percentages and times are
                // most of what this app shows, and the rounded design reads
                // friendlier and more legible at a glance. Arabic text keeps
                // its own face; this only changes the Latin and the digits.
                .fontDesign(.rounded)
                .task { environment.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            environment.handleScenePhase(phase)
        }
        // The half of notifications that works without a push server: iOS wakes
        // the app now and then, it asks the Pi one question, and anything that
        // changed becomes a local notification. Registered here rather than in
        // an AppDelegate - SwiftUI does the BGTaskScheduler registration for
        // this identifier itself, and a task registered twice traps at launch.
        .backgroundTask(.appRefresh(BackgroundWatch.refreshIdentifier)) {
            await BackgroundWatch.run()
        }
    }
}
