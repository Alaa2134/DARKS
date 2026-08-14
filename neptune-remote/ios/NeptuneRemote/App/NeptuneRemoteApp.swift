import SwiftUI

@main
struct NeptuneRemoteApp: App {
    @StateObject private var environment = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase

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
                .task { environment.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            environment.handleScenePhase(phase)
        }
    }
}
