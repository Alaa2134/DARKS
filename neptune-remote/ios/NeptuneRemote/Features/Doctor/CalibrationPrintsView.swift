import SwiftUI

/// The calibrations that decide what the plastic looks like.
///
/// Everything the Doctor screen already offered was about the bed - Z offset,
/// screws, mesh. These four are about flow, pressure advance, temperature and
/// retraction, and they go unmeasured on most printers because measuring them
/// normally means finding a test model and slicing it exactly right. Here the
/// G-code is generated from printer.cfg, so there is nothing to get wrong.
struct CalibrationPrintsView: View {
    @EnvironmentObject private var calibration: CalibrationStore
    @EnvironmentObject private var printer: PrinterStore

    @State private var nozzleTemp: Double = 205
    @State private var bedTemp: Double = 60
    @State private var showingFirstLayer = false

    var body: some View {
        List {
            temperatureSection

            Section {
                ForEach(calibration.tests) { test in
                    testRow(test)
                }
            } header: {
                Text(localized: "calibration.section.tests")
            } footer: {
                Text(localized: "calibration.section.tests.footer")
            }

            if calibration.tests.contains(where: { $0.id == "first_layer" }) {
                Section {
                    Button {
                        showingFirstLayer = true
                    } label: {
                        Label(L.t("calibration.first_layer.open"), systemImage: "camera.viewfinder")
                    }
                } header: {
                    Text(localized: "calibration.section.first_layer")
                } footer: {
                    Text(localized: "calibration.section.first_layer.footer")
                }
            }
        }
        .navigationTitle(L.t("calibration.prints.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await calibration.load() }
        .sheet(item: Binding(
            get: { calibration.generated.map(GeneratedTest.init) },
            set: { if $0 == nil { calibration.clearGenerated() } }
        )) { wrapper in
            NavigationStack { CalibrationResultView(test: wrapper.test) }
        }
        .sheet(isPresented: $showingFirstLayer) {
            NavigationStack { FirstLayerCheckView() }
        }
    }

    private var temperatureSection: some View {
        Section {
            LabeledContent(L.t("calibration.nozzle_temp")) {
                Stepper("\(Int(nozzleTemp))°", value: $nozzleTemp, in: 170...260, step: 5)
            }
            LabeledContent(L.t("calibration.bed_temp")) {
                Stepper("\(Int(bedTemp))°", value: $bedTemp, in: 0...110, step: 5)
            }
        } header: {
            Text(localized: "calibration.section.temps")
        } footer: {
            Text(localized: "calibration.section.temps.footer")
        }
    }

    @ViewBuilder
    private func testRow(_ test: CalibrationTestSummary) -> some View {
        if test.ok {
            Button {
                Task {
                    await calibration.generate(
                        test.id, nozzleTemp: nozzleTemp, bedTemp: bedTemp
                    )
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(test.title)
                        Text(L.t("calibration.minutes", Int(test.estimatedMinutes)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if calibration.isGenerating {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .disabled(calibration.isGenerating)
        } else {
            // Shown greyed with the reason rather than hidden. A test missing
            // from the list looks like the app forgot it; a test that says
            // "needs [firmware_retraction]" is something the user can fix.
            VStack(alignment: .leading, spacing: 3) {
                Text(test.title)
                    .foregroundStyle(.secondary)
                ForEach(test.blockers, id: \.self) { blocker in
                    Text(blocker)
                        .font(.caption2)
                        .foregroundStyle(Theme.paused)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// `sheet(item:)` needs an Identifiable, and the test itself is decoded.
private struct GeneratedTest: Identifiable {
    let test: CalibrationTest
    var id: String { test.id }

    init(_ test: CalibrationTest) { self.test = test }
}

// MARK: - The generated print

struct CalibrationResultView: View {
    let test: CalibrationTest

    @EnvironmentObject private var calibration: CalibrationStore
    @EnvironmentObject private var files: FilesStore
    @Environment(\.dismiss) private var dismiss

    @State private var measured: String = ""
    @State private var flow: FlowResult?
    @State private var pressureAdvance: PressureAdvanceResult?

    var body: some View {
        List {
            Section {
                ForEach(Array(test.instructionsAR.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .frame(width: 20, height: 20)
                            .background(Theme.accent.opacity(0.18), in: Circle())
                        Text(step)
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text(localized: "calibration.steps")
            }

            if test.id == "flow" { flowSection }
            if test.id == "pressure_advance" { pressureAdvanceSection }

            Section {
                CopyableRow(
                    label: L.t("calibration.gcode"),
                    value: "\(test.gcode.split(separator: "\n").count) سطر"
                )
                ShareLink(item: test.gcode) {
                    Label(L.t("calibration.share"), systemImage: "square.and.arrow.up")
                }
            } footer: {
                Text(localized: "calibration.gcode.footer")
            }
        }
        .navigationTitle(test.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L.t("common.done")) { dismiss() }
            }
        }
    }

    // MARK: Flow

    private var flowSection: some View {
        Section {
            LabeledContent(L.t("calibration.flow.expected")) {
                Text(Format.millimetres(test.parameters["expected_wall_mm"], decimals: 3))
                    .monospacedDigit()
            }
            HStack {
                Text(localized: "calibration.flow.measured")
                Spacer()
                TextField("0.00", text: $measured)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .monospacedDigit()
            }
            Button(L.t("calibration.flow.compute")) {
                Task {
                    guard let value = Double(measured),
                          let expected = test.parameters["expected_wall_mm"]
                    else { return }
                    flow = await calibration.flowResult(
                        measured: value, expected: expected, currentFlow: 1.0
                    )
                }
            }
            .disabled(Double(measured) == nil)

            if let flow {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.t("calibration.flow.result", String(format: "%.3f", flow.flow)))
                        .font(.subheadline.weight(.semibold))
                    Text(flow.noteAR)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text(localized: "calibration.flow.title")
        } footer: {
            Text(localized: "calibration.flow.footer")
        }
    }

    // MARK: Pressure advance

    private var pressureAdvanceSection: some View {
        Section {
            HStack {
                Text(localized: "calibration.pa.height")
                Spacer()
                TextField("0.0", text: $measured)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .monospacedDigit()
            }
            Button(L.t("calibration.pa.compute")) {
                Task {
                    guard let height = Double(measured) else { return }
                    pressureAdvance = await calibration.pressureAdvanceResult(
                        heightMM: height,
                        start: test.parameters["start"] ?? 0,
                        step: test.parameters["step_per_layer"] ?? 0.005,
                        layerHeight: test.parameters["layer_height_mm"] ?? 0.2
                    )
                }
            }
            .disabled(Double(measured) == nil)

            if let pressureAdvance {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L.t("calibration.pa.result",
                             String(format: "%.4f", pressureAdvance.pressureAdvance)))
                        .font(.subheadline.weight(.semibold))
                    CopyableRow(
                        label: L.t("calibration.pa.command"), value: pressureAdvance.command
                    )
                    Text(pressureAdvance.configAR)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // Deliberately not a one-tap write. This edits printer.cfg,
                    // and nothing in this app rewrites that file without a
                    // separate confirmed step that snapshots it first.
                    Label(L.t("calibration.pa.manual"), systemImage: "hand.raised")
                        .font(.caption2)
                        .foregroundStyle(Theme.paused)
                }
            }
        } header: {
            Text(localized: "calibration.pa.title")
        } footer: {
            Text(localized: "calibration.pa.footer")
        }
    }
}
