import SwiftUI

/// Carry on from a layer, or print only a piece.
///
/// A print stops - power cut, filament out, a cancel a day ago - and the part is
/// still stuck to the bed exactly where it was left. Klipper has no memory of
/// it: the file starts at layer one and there is no way to say "start at 340".
/// The Pi rewrites the file instead.
///
/// Reached from the preview, because the preview is where you find the layer.
/// You look at the picture, find the last one that printed, and carry on from
/// the one after it.
struct ResumePrintView: View {
    let filename: String
    /// Where the preview was when this was opened - the layer the user was
    /// looking at, which is almost always the one they mean.
    let startingLayer: Int
    let layerCount: Int

    @EnvironmentObject private var printer: PrinterStore
    @EnvironmentObject private var settings: AppSettings

    @State private var startLayer: Int
    @State private var printsRange = false
    @State private var endLayer: Int
    @State private var plan: ResumePlan?
    @State private var isChecking = false
    @State private var isBuilding = false
    @State private var result: ResumeResult?
    @State private var error: APIError?

    @State private var overrideTemperatures = false
    @State private var nozzleTemp: Double = 215
    @State private var bedTemp: Double = 60
    @State private var primeMM: Double = 8

    init(filename: String, startingLayer: Int, layerCount: Int) {
        self.filename = filename
        self.startingLayer = startingLayer
        self.layerCount = layerCount
        _startLayer = State(initialValue: startingLayer)
        _endLayer = State(initialValue: max(startingLayer, layerCount - 1))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                if let error {
                    ErrorBanner(
                        message: error.localizedDescription,
                        onDismiss: { self.error = nil }
                    )
                }

                explainer
                layerCard

                if isChecking {
                    BusyLine(textKey: "resume.checking").card()
                } else if let plan {
                    verdictCard(plan)
                    if plan.isPossible {
                        temperatureCard(plan)
                        buildCard
                    }
                }

                if let result { resultCard(result) }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
            .animation(.neptuneContent, value: plan)
            .animation(.neptuneContent, value: result)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("resume.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: startLayer) { await check() }
    }

    // MARK: - What this is

    private var explainer: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("resume.title", systemImage: "arrow.trianglehead.clockwise")
            Text(localized: "resume.explain")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    // MARK: - Which layers

    private var layerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("resume.layers", systemImage: "square.3.layers.3d")

            stepper(
                titleKey: "resume.start_layer",
                value: $startLayer,
                range: 0...max(0, layerCount - 1)
            )

            Toggle(isOn: $printsRange.animation(.neptune)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(localized: "resume.only_a_piece")
                        .font(.subheadline)
                    Text(localized: "resume.only_a_piece.hint")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if printsRange {
                stepper(
                    titleKey: "resume.end_layer",
                    value: $endLayer,
                    range: startLayer...max(startLayer, layerCount - 1)
                )
                .transition(.neptuneContent)
            }
        }
        .card()
    }

    private func stepper(titleKey: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        Stepper(value: value, in: range) {
            HStack {
                Text(localized: titleKey)
                    .font(.subheadline)
                Spacer(minLength: 8)
                // Shown one-based, the way the preview counts them, so the
                // number here is the number the user was just looking at.
                Text(L.t("resume.layer_number", value.wrappedValue + 1, layerCount))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.neptune, value: value.wrappedValue)
            }
        }
    }

    // MARK: - Can it be done

    @ViewBuilder
    private func verdictCard(_ plan: ResumePlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                L.t(plan.isPossible ? "resume.possible" : "resume.blocked"),
                systemImage: plan.isPossible ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(plan.isPossible ? Theme.printing : Theme.danger)

            if let z = plan.z {
                InfoRow(titleKey: "resume.height", value: String(format: "%.2f mm", z))
            }

            ForEach(plan.blockersAr, id: \.self) { blocker in
                bullet(blocker, tint: Theme.danger)
            }
            ForEach(plan.warningsAr, id: \.self) { warning in
                bullet(warning, tint: Theme.paused)
            }

            // The single most consequential fact, said plainly: whether the
            // machine will measure its height or be told it.
            if plan.isPossible {
                Label(
                    L.t(plan.canHomeZ ? "resume.z_measured" : "resume.z_asserted"),
                    systemImage: plan.canHomeZ ? "ruler" : "hand.raised"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
    }

    private func bullet(_ text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(tint).frame(width: 5, height: 5).padding(.top, 6)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Temperatures

    private func temperatureCard(_ plan: ResumePlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("resume.temperatures", systemImage: "thermometer.medium")

            if let nozzle = plan.nozzleTemp, let bed = plan.bedTemp {
                Text(L.t("resume.temperatures.found", Int(nozzle), Int(bed)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(isOn: $overrideTemperatures.animation(.neptune)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(localized: "resume.changed_filament")
                        .font(.subheadline)
                    Text(localized: "resume.changed_filament.hint")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if overrideTemperatures {
                LabelledSlider(
                    titleKey: "temperature.nozzle",
                    value: $nozzleTemp,
                    range: 150...(printer.capabilities.primaryExtruder?.maxTemp ?? 260),
                    step: 5,
                    unit: "°"
                )
                LabelledSlider(
                    titleKey: "temperature.bed",
                    value: $bedTemp,
                    range: 0...(printer.capabilities.bedHeater?.maxTemp ?? 110),
                    step: 5,
                    unit: "°"
                )
                .transition(.neptuneContent)
            }

            LabelledSlider(
                titleKey: "resume.prime",
                value: $primeMM,
                range: 0...30,
                step: 1,
                unit: " mm"
            )
            Text(localized: "resume.prime.hint")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
        .onAppear {
            if let nozzle = plan.nozzleTemp { nozzleTemp = nozzle }
            if let bed = plan.bedTemp { bedTemp = bed }
        }
    }

    // MARK: - Build it

    private var buildCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Said before the button, not after: the file is written and handed
            // over, and starting it is a separate, deliberate act.
            Text(localized: "resume.will_not_start")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task { await build() }
            } label: {
                if isBuilding {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(localized: "resume.building")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Label(L.t("resume.build"), systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isBuilding)
        }
        .card()
    }

    private func resultCard(_ result: ResumeResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(result.filename, systemImage: "doc.text.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.printing)

            Text(result.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !result.uploaded {
                Label(L.t("resume.not_uploaded"), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Theme.paused)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(localized: "resume.next_step")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
        .transition(.neptuneContent)
    }

    // MARK: - Work

    private func check() async {
        guard layerCount > 0 else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            plan = try await printer.backend.resumePlan(name: filename, layer: startLayer)
            error = nil
        } catch {
            self.error = APIError.from(error, host: settings.host)
            plan = nil
        }
    }

    private func build() async {
        isBuilding = true
        defer { isBuilding = false }
        do {
            let payload = ResumeRequestPayload(
                startLayer: startLayer,
                endLayer: printsRange ? endLayer : nil,
                nozzleTemp: overrideTemperatures ? nozzleTemp : nil,
                bedTemp: overrideTemperatures ? bedTemp : nil,
                primeMM: primeMM
            )
            result = try await printer.backend.buildResume(name: filename, payload: payload)
            error = nil
            Haptics.success()
        } catch {
            self.error = APIError.from(error, host: settings.host)
            Haptics.error()
        }
    }
}
