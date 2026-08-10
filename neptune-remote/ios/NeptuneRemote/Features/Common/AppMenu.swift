import SwiftUI

/// Every screen in the app, from wherever you are.
///
/// A tab bar holds five things. This app has forty screens, so four fifths of
/// it always lives somewhere you have to go looking - and moving one screen
/// closer means pushing another further away. That trade is what made the
/// last reshuffle feel like things had been deleted.
///
/// This menu ends the trade. It hangs in the toolbar of every main screen, so
/// nothing is more than two taps from anywhere: the tabs stay for the handful
/// of places you go constantly, and everything else is here, grouped and named
/// rather than listed.
///
/// Placement is deliberate too - the same button in the same corner on every
/// screen. A menu that moves is a menu you have to find.
struct AppMenu: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var inventory: InventoryStore

    var body: some View {
        Menu {
            Section(L.t("more.section.printing")) {
                NavigationLink { FilesView() } label: {
                    Label(L.t("tab.files"), systemImage: "doc.text")
                }
                NavigationLink { QueueView() } label: {
                    Label(L.t("queue.title"), systemImage: "list.number")
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
            }

            Section(L.t("more.section.machine")) {
                NavigationLink { ControlView() } label: {
                    Label(L.t("tab.control"), systemImage: "slider.horizontal.3")
                }
                NavigationLink { SliceView() } label: {
                    Label(L.t("tab.slice"), systemImage: "cube.transparent")
                }
                NavigationLink { TerminalView() } label: {
                    Label(L.t("terminal.title"), systemImage: "terminal")
                }
            }

            Section(L.t("more.section.health")) {
                NavigationLink { FixMyPrinterView() } label: {
                    Label(L.t("doctor.title"), systemImage: "stethoscope")
                }
                NavigationLink { CalibrationHubView() } label: {
                    Label(L.t("calibration.title"), systemImage: "wand.and.stars")
                }
                NavigationLink { MaintenanceView() } label: {
                    Label(L.t("maintenance.title"), systemImage: "wrench.and.screwdriver")
                }
                NavigationLink { InsightsView() } label: {
                    Label(L.t("insights.title"), systemImage: "lightbulb")
                }
            }

            Section(L.t("more.section.materials")) {
                NavigationLink { FilamentView() } label: {
                    Label(L.t("filament.title"), systemImage: "circle.hexagongrid")
                }
                NavigationLink { CostView() } label: {
                    Label(L.t("cost.title"), systemImage: "banknote")
                }
                NavigationLink { ProductsView() } label: {
                    Label(L.t("products.title"), systemImage: "tag")
                }
            }

            Section(L.t("more.section.system")) {
                NavigationLink { PrinterCapabilitiesView() } label: {
                    Label(L.t("capabilities.title"), systemImage: "list.bullet.clipboard")
                }
                NavigationLink { SystemInfoView() } label: {
                    Label(L.t("system.title"), systemImage: "cpu")
                }
                NavigationLink { SupportView() } label: {
                    Label(L.t("support.title"), systemImage: "questionmark.circle")
                }
                NavigationLink { SettingsView() } label: {
                    Label(L.t("settings.title"), systemImage: "gearshape")
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal")
                .accessibilityLabel(L.t("more.title"))
        }
    }
}
