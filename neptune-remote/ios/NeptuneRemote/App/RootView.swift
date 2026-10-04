import SwiftUI

struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var printer: PrinterStore
    @EnvironmentObject private var library: LibraryStore

    @State private var selectedTab: Tab = .home
    @State private var showingSettings = false
    @State private var homePath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @State private var morePath = NavigationPath()

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

            NavigationStack(path: $morePath) {
                MoreView(showingSettings: $showingSettings)
                    .withLibraryDestinations()
                    #if DEBUG
                    .withShowcaseDestinations()
                    #endif
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
        #if DEBUG
        .task { openShowcaseScreen() }
        #endif
    }

    #if DEBUG
    /// Screenshot mode: open the screen CI asked for. See `Showcase`.
    private func openShowcaseScreen() {
        guard let screen = Showcase.screen else { return }
        printer.demoShowcaseHomed()
        if Showcase.wantsPrinting {
            printer.demoShowcaseMidPrint(filename: "trident_wave_vase.gcode", progress: 0.62)
        }
        switch Showcase.destination(for: screen) {
        case .tab(let tab):
            selectedTab = tab
        case .pushed(let route):
            selectedTab = .more
            morePath = NavigationPath([route])
        case .settings:
            showingSettings = true
        }
    }
    #endif

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
                        MenuRow(titleKey: "queue.title", systemImage: "list.number", color: Theme.tideDeep)
                        Spacer()
                        if inventory.queue.waiting.count > 0 {
                            Text("\(inventory.queue.waiting.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                NavigationLink { HistoryView() } label: {
                    MenuRow(titleKey: "history.title", systemImage: "clock.arrow.circlepath", color: Color(rgb: 0x6366F1))
                }
                NavigationLink { VideosView() } label: {
                    MenuRow(titleKey: "video.title", systemImage: "film", color: Color(rgb: 0xEC4899))
                }
                NavigationLink { VisionView() } label: {
                    MenuRow(titleKey: "vision.title", systemImage: "eye", color: Color(rgb: 0x8B5CF6))
                }
            } header: {
                Text(localized: "more.section.printing")
            }

            Section {
                NavigationLink { ControlView() } label: {
                    MenuRow(titleKey: "tab.control", systemImage: "slider.horizontal.3", color: Color(rgb: 0x0EA5E9))
                }
                NavigationLink { SliceView() } label: {
                    MenuRow(titleKey: "tab.slice", systemImage: "cube.transparent", color: Color(rgb: 0x14B8A6))
                }
                if settings.advancedMode {
                    NavigationLink { TerminalView() } label: {
                        MenuRow(titleKey: "terminal.title", systemImage: "terminal", color: Color(rgb: 0x334155))
                    }
                }
            } header: {
                Text(localized: "more.section.machine")
            }

            Section {
                NavigationLink { FilamentView() } label: {
                    MenuRow(titleKey: "filament.title", systemImage: "circle.hexagongrid", color: Theme.emberHot)
                }
                NavigationLink { CostView() } label: {
                    MenuRow(titleKey: "cost.title", systemImage: "banknote", color: Color(rgb: 0x22C55E))
                }
                NavigationLink { ProductsView() } label: {
                    MenuRow(titleKey: "products.title", systemImage: "tag", color: Color(rgb: 0xF59E0B))
                }
            } header: {
                Text(localized: "more.section.materials")
            }

            Section {
                NavigationLink { FixMyPrinterView() } label: {
                    MenuRow(titleKey: "doctor.title", systemImage: "stethoscope", color: Color(rgb: 0xEF4444))
                }
                NavigationLink { CalibrationHubView() } label: {
                    MenuRow(titleKey: "calibration.title", systemImage: "wand.and.stars", color: Color(rgb: 0xA855F7))
                }
                NavigationLink { MaintenanceView() } label: {
                    MenuRow(titleKey: "maintenance.title", systemImage: "wrench.and.screwdriver", color: Color(rgb: 0x64748B))
                }
                NavigationLink { PrinterHealthView() } label: {
                    MenuRow(titleKey: "health.title", systemImage: "heart.text.square", color: Color(rgb: 0xF43F5E))
                }
            } header: {
                Text(localized: "more.section.health")
            }

            Section {
                NavigationLink { PrinterCapabilitiesView() } label: {
                    MenuRow(titleKey: "capabilities.title", systemImage: "list.bullet.clipboard", color: Color(rgb: 0x0284C7))
                }
                NavigationLink { ConfigVersionsView() } label: {
                    MenuRow(titleKey: "config.versions.title", systemImage: "doc.on.doc", color: Color(rgb: 0x475569))
                }
                NavigationLink { LibraryBackupView() } label: {
                    MenuRow(titleKey: "library.backup.title", systemImage: "externaldrive.badge.timemachine", color: Color(rgb: 0x059669))
                }
                NavigationLink { SystemInfoView() } label: {
                    MenuRow(titleKey: "system.title", systemImage: "cpu", color: Color(rgb: 0x52525B))
                }
                NavigationLink { SupportView() } label: {
                    MenuRow(titleKey: "support.title", systemImage: "questionmark.circle", color: Color(rgb: 0x3B82F6))
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
                    MenuRow(titleKey: "settings.title", systemImage: "gearshape", color: Color(rgb: 0x6B7280))
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
