import SwiftUI

struct ControlView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var printer: PrinterStore

    @State private var section: Section = .move

    enum Section: String, CaseIterable, Identifiable {
        case move, temperature, speed, terminal
        var id: String { rawValue }
        var titleKey: String { "control.section.\(rawValue)" }
        var systemImage: String {
            switch self {
            case .move: return "move.3d"
            case .temperature: return "thermometer.medium"
            case .speed: return "speedometer"
            case .terminal: return "terminal"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $section) {
                ForEach(Section.allCases) { item in
                    Label(L.t(item.titleKey), systemImage: item.systemImage).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            switch section {
            case .move: JogView()
            case .temperature: TemperatureView()
            case .speed: SpeedView()
            case .terminal: TerminalView()
            }
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("tab.control"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
