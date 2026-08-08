import Charts
import SwiftUI

struct TemperatureView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var printer: PrinterStore

    @State private var nozzleTarget: Double = 0
    @State private var bedTarget: Double = 0
    @State private var editingPreset: TemperaturePreset?
    @State private var showingPresetEditor = false

    private var snapshot: PrinterSnapshot { printer.snapshot }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                chartCard
                heaterCard(
                    titleKey: "temperature.nozzle",
                    systemImage: "flame.fill",
                    tint: Theme.nozzle,
                    actual: snapshot.nozzleActual,
                    current: snapshot.nozzleTarget,
                    target: $nozzleTarget,
                    range: 0...300
                ) { value in
                    Task { await printer.setNozzleTarget(value) }
                }
                heaterCard(
                    titleKey: "temperature.bed",
                    systemImage: "square.stack.3d.down.right.fill",
                    tint: Theme.bed,
                    actual: snapshot.bedActual,
                    current: snapshot.bedTarget,
                    target: $bedTarget,
                    range: 0...120
                ) { value in
                    Task { await printer.setBedTarget(value) }
                }
                presetsCard
                actionsCard
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .onAppear {
            nozzleTarget = snapshot.nozzleTarget
            bedTarget = snapshot.bedTarget
        }
        .sheet(isPresented: $showingPresetEditor) {
            PresetEditorView(preset: editingPreset)
                .presentationDetents([.medium])
        }
    }

    // MARK: - Chart

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("temperature.graph", systemImage: "chart.xyaxis.line")

            if printer.temperatureHistory.count < 2 {
                Text(localized: "temperature.graph.collecting")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                Chart {
                    ForEach(printer.temperatureHistory) { sample in
                        LineMark(
                            x: .value("t", sample.date),
                            y: .value("°C", sample.nozzle),
                            series: .value("s", "nozzle")
                        )
                        .foregroundStyle(Theme.nozzle)
                        .interpolationMethod(.monotone)

                        LineMark(
                            x: .value("t", sample.date),
                            y: .value("°C", sample.bed),
                            series: .value("s", "bed")
                        )
                        .foregroundStyle(Theme.bed)
                        .interpolationMethod(.monotone)

                        if sample.nozzleTarget > 0 {
                            LineMark(
                                x: .value("t", sample.date),
                                y: .value("°C", sample.nozzleTarget),
                                series: .value("s", "nozzleTarget")
                            )
                            .foregroundStyle(Theme.nozzle.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                        if sample.bedTarget > 0 {
                            LineMark(
                                x: .value("t", sample.date),
                                y: .value("°C", sample.bedTarget),
                                series: .value("s", "bedTarget")
                            )
                            .foregroundStyle(Theme.bed.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                    }
                }
                .chartYScale(domain: 0...chartUpperBound)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour().minute())
                    }
                }
                .frame(height: 180)

                HStack(spacing: 16) {
                    legend(color: Theme.nozzle, key: "temperature.nozzle")
                    legend(color: Theme.bed, key: "temperature.bed")
                    Spacer()
                }
            }
        }
        .card()
    }

    /// Keep the y-axis stable but always tall enough for the hottest value.
    private var chartUpperBound: Double {
        let peak = max(snapshot.nozzleActual, snapshot.nozzleTarget)
        return max(80, (peak + 30).rounded(.up))
    }

    private func legend(color: Color, key: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(localized: key)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Heater card

    @ViewBuilder
    private func heaterCard(
        titleKey: String,
        systemImage: String,
        tint: Color,
        actual: Double,
        current: Double,
        target: Binding<Double>,
        range: ClosedRange<Double>,
        apply: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionHeader(titleKey, systemImage: systemImage)
                Text(Format.temperature(actual))
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }

            InfoRow(titleKey: "temperature.current_target", value: Format.temperatureShort(current))

            HStack {
                Slider(value: target, in: range, step: 1)
                    .tint(tint)
                TextField("", value: target, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .frame(width: 62)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 10) {
                Button {
                    apply(target.wrappedValue)
                    Haptics.impact(.medium)
                } label: {
                    Label(L.t("temperature.set"), systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)

                Button {
                    target.wrappedValue = 0
                    apply(0)
                    Haptics.impact(.light)
                } label: {
                    Label(L.t("temperature.off"), systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .card()
    }

    // MARK: - Presets

    private var presetsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader("temperature.presets", systemImage: "square.grid.2x2.fill")
                Button {
                    editingPreset = nil
                    showingPresetEditor = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
            }

            ForEach(settings.temperaturePresets) { preset in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset.name)
                            .font(.subheadline.weight(.semibold))
                        Text("\(Int(preset.nozzle))° / \(Int(preset.bed))°")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer()
                    Button(L.t("temperature.preheat_both")) {
                        nozzleTarget = preset.nozzle
                        bedTarget = preset.bed
                        Task { await printer.preheat(preset) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        editingPreset = preset
                        showingPresetEditor = true
                    } label: {
                        Image(systemName: "pencil.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 4)

                if preset.id != settings.temperaturePresets.last?.id {
                    Divider()
                }
            }
        }
        .card()
    }

    private var actionsCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                BigActionButton(titleKey: "temperature.preheat_nozzle", systemImage: "flame",
                                tint: Theme.nozzle, isEnabled: snapshot.isReady) {
                    let preset = settings.temperaturePresets.first ?? TemperaturePreset(name: "PLA", nozzle: 205, bed: 60)
                    nozzleTarget = preset.nozzle
                    Task { await printer.preheat(preset, nozzle: true, bed: false) }
                }
                BigActionButton(titleKey: "temperature.preheat_bed", systemImage: "square.stack.3d.down.right",
                                tint: Theme.bed, isEnabled: snapshot.isReady) {
                    let preset = settings.temperaturePresets.first ?? TemperaturePreset(name: "PLA", nozzle: 205, bed: 60)
                    bedTarget = preset.bed
                    Task { await printer.preheat(preset, nozzle: false, bed: true) }
                }
                BigActionButton(titleKey: "action.cooldown", systemImage: "snowflake",
                                tint: Theme.bed, isEnabled: snapshot.isReady) {
                    nozzleTarget = 0
                    bedTarget = 0
                    Task { await printer.cooldown() }
                }
            }
        }
        .card()
    }
}

// MARK: - Preset editor

struct PresetEditorView: View {
    let preset: TemperaturePreset?

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var nozzle: Double = 205
    @State private var bed: Double = 60

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L.t("temperature.preset_name"), text: $name)
                    Stepper(value: $nozzle, in: 0...300, step: 5) {
                        HStack {
                            Text(localized: "temperature.nozzle")
                            Spacer()
                            Text("\(Int(nozzle))°").monospacedDigit()
                        }
                    }
                    Stepper(value: $bed, in: 0...120, step: 5) {
                        HStack {
                            Text(localized: "temperature.bed")
                            Spacer()
                            Text("\(Int(bed))°").monospacedDigit()
                        }
                    }
                }

                if let preset, !preset.isBuiltIn {
                    Section {
                        Button(L.t("common.delete"), role: .destructive) {
                            settings.temperaturePresets.removeAll { $0.id == preset.id }
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(L.t(preset == nil ? "temperature.new_preset" : "temperature.edit_preset"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L.t("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L.t("common.save"), action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let preset {
                    name = preset.name
                    nozzle = preset.nozzle
                    bed = preset.bed
                }
            }
        }
    }

    private func save() {
        if let preset, let index = settings.temperaturePresets.firstIndex(where: { $0.id == preset.id }) {
            settings.temperaturePresets[index].name = name
            settings.temperaturePresets[index].nozzle = nozzle
            settings.temperaturePresets[index].bed = bed
        } else {
            settings.temperaturePresets.append(
                TemperaturePreset(name: name, nozzle: nozzle, bed: bed)
            )
        }
        dismiss()
    }
}

// MARK: - Preheat sheet (used from Home)

struct PreheatSheet: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var printer: PrinterStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(settings.temperaturePresets) { preset in
                    Button {
                        Task {
                            await printer.preheat(preset)
                            dismiss()
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name).font(.headline)
                                Text("\(L.t("temperature.nozzle")) \(Int(preset.nozzle))°  ·  \(L.t("temperature.bed")) \(Int(preset.bed))°")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "flame.fill")
                                .foregroundStyle(Theme.nozzle)
                        }
                    }
                }
            }
            .navigationTitle(L.t("action.preheat"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L.t("common.cancel")) { dismiss() }
                }
            }
        }
    }
}
