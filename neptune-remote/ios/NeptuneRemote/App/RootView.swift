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

    /// Five tabs, the same five in both modes.
    ///
    /// They used to change: Simple Mode had four, Advanced Mode grew two more
    /// in the middle, so Camera and More slid sideways the moment the toggle
    /// moved. A tab bar you cannot reach for without looking is worse than one
    /// with an extra item on it, and Advanced Mode is about what the screens
    /// offer, not about where they live.
    ///
    /// The order is the order of a print: look at the machine, pick a file,
    /// drive it, watch it. Files is a tab rather than the eighth row of a
    /// menu - it is where a print actually starts, and it was buried under
    /// "More" while a browsing screen had a tab of its own.
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

            NavigationStack {
                FilesView()
                    .withLibraryDestinations()
            }
            .tabItem { Label(L.t("tab.files"), systemImage: "doc.text.fill") }
            .tag(Tab.files)

            NavigationStack(path: $libraryPath) {
                LibraryView()
                    .withLibraryDestinations()
            }
            .tabItem { Label(L.t("library.title"), systemImage: "square.grid.2x2.fill") }
            .tag(Tab.library)

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
        // Above every tab, so no command can be refused in silence just
        // because it was sent from a screen that forgot to display errors.
        .printerFeedback()
        .onOpenURL { url in
            handle(url: url)
        }
    }

    /// `neptuneremote://home`, `neptuneremote://library`, ... used by App Intents,
    /// the widget and the Share Extension.
    private func handle(url: URL) {
        guard url.scheme == "neptuneremote" else { return }
        switch url.host {
        case "control": selectedTab = .more
        case "slice": selectedTab = .library
        case "files": selectedTab = .files
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

/// Everything that is not a primary tab.
///
/// It was five unlabelled sections and seventeen destinations - a drawer you
/// had to read end to end every time, because nothing said what any group was
/// for. The dividers were there; the meaning was not.
///
/// Now each group is named for the question it answers, and they are ordered
/// by how often that question comes up: what is the printer doing, what am I
/// printing with, is the machine well, and what is underneath.
struct MoreView: View {
    @Binding var showingSettings: Bool

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var inventory: InventoryStore

    var body: some View {
        List {
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
                NavigationLink { HistoryView() } label: {
                    Label(L.t("history.title"), systemImage: "clock.arrow.circlepath")
                }
                NavigationLink { VideosView() } label: {
                    Label(L.t("video.title"), systemImage: "film")
                }
                NavigationLink { VisionView() } label: {
                    Label(L.t("vision.title"), systemImage: "eye")
                }
            } header: {
                Text(localized: "more.section.printing")
            }

            Section {
                NavigationLink { ControlView() } label: {
                    Label(L.t("tab.control"), systemImage: "slider.horizontal.3")
                }
                NavigationLink { SliceView() } label: {
                    Label(L.t("tab.slice"), systemImage: "cube.transparent")
                }
                if settings.advancedMode {
                    NavigationLink { TerminalView() } label: {
                        Label(L.t("terminal.title"), systemImage: "terminal")
                    }
                }
            } header: {
                Text(localized: "more.section.machine")
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
            } header: {
                Text(localized: "more.section.materials")
            }

            Section {
                NavigationLink { FixMyPrinterView() } label: {
                    Label(L.t("doctor.title"), systemImage: "stethoscope")
                }
                NavigationLink { CalibrationHubView() } label: {
                    Label(L.t("calibration.title"), systemImage: "wand.and.stars")
                }
                NavigationLink { MaintenanceView() } label: {
                    Label(L.t("maintenance.title"), systemImage: "wrench.and.screwdriver")
                }
                NavigationLink { PrinterHealthView() } label: {
                    Label(L.t("health.title"), systemImage: "heart.text.square")
                }
            } header: {
                Text(localized: "more.section.health")
            }

            Section {
                NavigationLink { PrinterCapabilitiesView() } label: {
                    Label(L.t("capabilities.title"), systemImage: "list.bullet.clipboard")
                }
                NavigationLink { ConfigVersionsView() } label: {
                    Label(L.t("config.versions.title"), systemImage: "doc.on.doc")
                }
                NavigationLink { LibraryBackupView() } label: {
                    Label(L.t("library.backup.title"), systemImage: "externaldrive.badge.timemachine")
                }
                NavigationLink { SystemInfoView() } label: {
                    Label(L.t("system.title"), systemImage: "cpu")
                }
                NavigationLink { SupportView() } label: {
                    Label(L.t("support.title"), systemImage: "questionmark.circle")
                }
            } header: {
                Text(localized: "more.section.system")
            }

            Section {
                Toggle(isOn: $settings.advancedMode) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localized: "mode.advanced")
                        Text(localized: settings.advancedMode
                                ? "mode.advanced.description"
                                : "mode.simple.description")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    showingSettings = true
                } label: {
                    Label(L.t("settings.title"), systemImage: "gearshape")
                }
            } header: {
                Text(localized: "more.section.app")
            }
        }
        .navigationTitle(L.t("more.title"))
        .navigationBarTitleDisplayMode(.large)
        .task { await inventory.load() }
    }
}
