import SwiftUI

struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var printer: PrinterStore
    @EnvironmentObject private var library: LibraryStore

    @State private var selectedTab: Tab = .home
    @State private var showingSettings = false
    @State private var homePath = NavigationPath()
    @State private var libraryPath = NavigationPath()

    enum Tab: Hashable {
        case home, library, control, slice, files, camera, more
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

    /// Simple Mode keeps four tabs; Advanced Mode adds the machine-level ones.
    /// Nothing is removed from the app - the extra screens stay reachable from
    /// "More" either way.
    private var mainTabs: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $homePath) {
                Group {
                    if settings.advancedMode {
                        HomeView(showingSettings: $showingSettings)
                    } else {
                        SimpleHomeView(showingSettings: $showingSettings)
                    }
                }
                .withLibraryDestinations()
            }
            .tabItem { Label(L.t("tab.home"), systemImage: "house.fill") }
            .tag(Tab.home)

            NavigationStack(path: $libraryPath) {
                LibraryView()
                    .withLibraryDestinations()
            }
            .tabItem { Label(L.t("library.title"), systemImage: "square.grid.2x2.fill") }
            .tag(Tab.library)

            if settings.advancedMode {
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
            }

            NavigationStack {
                CameraView()
            }
            .tabItem { Label(L.t("tab.camera"), systemImage: "video.fill") }
            .tag(Tab.camera)

            NavigationStack {
                MoreView(showingSettings: $showingSettings)
                    .withLibraryDestinations()
            }
            .tabItem { Label(L.t("more.title"), systemImage: "ellipsis.circle.fill") }
            .tag(Tab.more)
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack { SettingsView() }
        }
        .onOpenURL { url in
            handle(url: url)
        }
    }

    /// `neptuneremote://home`, `neptuneremote://library`, ... used by App Intents,
    /// the widget and the Share Extension.
    private func handle(url: URL) {
        guard url.scheme == "neptuneremote" else { return }
        switch url.host {
        case "control": selectedTab = settings.advancedMode ? .control : .more
        case "slice": selectedTab = settings.advancedMode ? .slice : .more
        case "files": selectedTab = .more
        case "camera": selectedTab = .camera
        case "library": selectedTab = .library
        case "settings": showingSettings = true
        case "model":
            // neptuneremote://model/<id>
            let identifier = url.pathComponents.dropFirst().first ?? ""
            if !identifier.isEmpty {
                selectedTab = .library
                libraryPath = NavigationPath([identifier])
            }
        default: selectedTab = .home
        }
    }
}

/// Everything that is not one of the primary tabs, in one list.
struct MoreView: View {
    @Binding var showingSettings: Bool

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var inventory: InventoryStore

    var body: some View {
        List {
            Section {
                Toggle(isOn: $settings.advancedMode) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localized: "mode.advanced")
                        Text(localized: settings.advancedMode ? "mode.advanced.description" : "mode.simple.description")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(localized: "mode.switch")
            }

            Section {
                NavigationLink { QueueView() } label: {
                    HStack {
                        Label(L.t("queue.title"), systemImage: "list.number")
                        Spacer()
                        if inventory.queue.waiting.count > 0 {
                            Text("\(inventory.queue.waiting.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                NavigationLink { VideosView() } label: {
                    Label(L.t("video.title"), systemImage: "film")
                }
                NavigationLink { VisionView() } label: {
                    Label(L.t("vision.title"), systemImage: "eye")
                }
                NavigationLink { HistoryView() } label: {
                    Label(L.t("history.title"), systemImage: "clock.arrow.circlepath")
                }
            }

            Section {
                NavigationLink { FilamentView() } label: {
                    Label(L.t("filament.title"), systemImage: "circle.hexagongrid")
                }
                NavigationLink { CostView() } label: {
                    Label(L.t("cost.title"), systemImage: "banknote")
                }
                NavigationLink { ProductsView() } label: {
                    Label(L.t("products.title"), systemImage: "tag")
                }
                NavigationLink { MaintenanceView() } label: {
                    Label(L.t("maintenance.title"), systemImage: "wrench.and.screwdriver")
                }
            }

            Section {
                NavigationLink { SupportView() } label: {
                    Label(L.t("support.title"), systemImage: "questionmark.circle")
                }
                NavigationLink { FilesView() } label: {
                    Label(L.t("tab.files"), systemImage: "folder")
                }
                NavigationLink { SystemInfoView() } label: {
                    Label(L.t("system.title"), systemImage: "cpu")
                }
                if settings.advancedMode {
                    NavigationLink { TerminalView() } label: {
                        Label(L.t("terminal.title"), systemImage: "terminal")
                    }
                } else {
                    NavigationLink { ControlView() } label: {
                        Label(L.t("tab.control"), systemImage: "slider.horizontal.3")
                    }
                    NavigationLink { SliceView() } label: {
                        Label(L.t("tab.slice"), systemImage: "cube.transparent")
                    }
                }
            }

            Section {
                Button {
                    showingSettings = true
                } label: {
                    Label(L.t("settings.title"), systemImage: "gearshape")
                }
            }
        }
        .navigationTitle(L.t("more.title"))
        .navigationBarTitleDisplayMode(.large)
        .task { await inventory.load() }
    }
}

