import SwiftUI

struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var printer: PrinterStore

    @State private var selectedTab: Tab = .home
    @State private var showingSettings = false

    enum Tab: Hashable {
        case home, control, slice, files, camera
    }

    var body: some View {
        Group {
            if settings.hasCompletedSetup {
                mainTabs
            } else {
                SetupWizardView()
            }
        }
        .animation(.easeInOut, value: settings.hasCompletedSetup)
    }

    private var mainTabs: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HomeView(showingSettings: $showingSettings)
            }
            .tabItem { Label(L.t("tab.home"), systemImage: "house.fill") }
            .tag(Tab.home)

            NavigationStack {
                ControlView()
            }
            .tabItem { Label(L.t("tab.control"), systemImage: "slider.horizontal.3") }
            .tag(Tab.control)

            NavigationStack {
                SliceView()
            }
            .tabItem { Label(L.t("tab.slice"), systemImage: "cube.transparent") }
            .tag(Tab.slice)

            NavigationStack {
                FilesView()
            }
            .tabItem { Label(L.t("tab.files"), systemImage: "folder.fill") }
            .tag(Tab.files)

            NavigationStack {
                CameraView()
            }
            .tabItem { Label(L.t("tab.camera"), systemImage: "video.fill") }
            .tag(Tab.camera)
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack { SettingsView() }
        }
        .onOpenURL { url in
            handle(url: url)
        }
    }

    /// `neptuneremote://home`, `neptuneremote://control`, ... used by App Intents.
    private func handle(url: URL) {
        guard url.scheme == "neptuneremote" else { return }
        switch url.host {
        case "control": selectedTab = .control
        case "slice": selectedTab = .slice
        case "files": selectedTab = .files
        case "camera": selectedTab = .camera
        case "settings": showingSettings = true
        default: selectedTab = .home
        }
    }
}
