import SwiftUI

struct SpeedView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var printer: PrinterStore

    @State private var speedFactor: Double = 100
    @State private var flowFactor: Double = 100
    @State private var fanPercent: Double = 0
    /// Speeds for fan_generic fans, which have no live feed to track.
    @State private var extraFanPercent: [String: Double] = [:]

    // Seeded from the printer's own configured maximums once discovery has run,
    // rather than from constants. The values below are only what the sliders
    // show before the first read.
    @State private var maxVelocity: Double = 300
    @State private var maxAcceleration: Double = 3_000
    @State private var squareCornerVelocity: Double = 5

    private let speedPresets: [Double] = [50, 75, 100, 125, 150, 175, 200]
    private var snapshot: PrinterSnapshot { printer.snapshot }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                liveCard
                speedCard
                flowCard
                fanCard
                if settings.advancedMode { advancedCard } else { advancedHint }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .onAppear(perform: syncFromPrinter)
        .onChange(of: snapshot.speedFactor) { _, value in
            if abs(value * 100 - speedFactor) > 1 { speedFactor = value * 100 }
        }
        .onChange(of: snapshot.extrudeFactor) { _, value in
            if abs(value * 100 - flowFactor) > 1 { flowFactor = value * 100 }
        }
    }

    private func syncFromPrinter() {
        speedFactor = snapshot.speedFactor * 100
        flowFactor = snapshot.extrudeFactor * 100
        fanPercent = snapshot.fanSpeed * 100
        // Live toolhead values first - they reflect any runtime SET_VELOCITY_LIMIT.
        // Failing that, the configured maximums from printer.cfg.
        let capabilities = printer.capabilities
        if snapshot.maxVelocity > 0 {
            maxVelocity = snapshot.maxVelocity
        } else if let value = capabilities.maxVelocity {
            maxVelocity = value
        }
        if snapshot.maxAcceleration > 0 {
            maxAcceleration = snapshot.maxAcceleration
        } else if let value = capabilities.maxAccel {
            maxAcceleration = value
        }
        if snapshot.squareCornerVelocity > 0 {
            squareCornerVelocity = snapshot.squareCornerVelocity
        } else if let value = capabilities.squareCornerVelocity {
            squareCornerVelocity = value
        }
    }

    // MARK: - Cards

    private var liveCard: some View {
        HStack(spacing: 12) {
            StatTile(titleKey: "machine.speed", value: Format.speed(snapshot.speed), systemImage: "speedometer")
            StatTile(titleKey: "machine.speed_factor", value: Format.percent(snapshot.speedFactor),
                     systemImage: "gauge.with.dots.needle.67percent", tint: Theme.printing)
            StatTile(titleKey: "machine.flow", value: Format.percent(snapshot.extrudeFactor),
                     systemImage: "drop.fill", tint: Theme.bed)
        }
        .card()
    }

    private var speedCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("speed.factor", systemImage: "gauge.with.dots.needle.67percent")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
                ForEach(speedPresets, id: \.self) { value in
                    Button {
                        speedFactor = value
                        Task { await printer.setSpeedFactor(value) }
                        Haptics.selection()
                    } label: {
                        Text("\(Int(value))%")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                abs(speedFactor - value) < 1 ? Theme.accent.opacity(0.25) : Theme.accent.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            LabelledSlider(
                titleKey: "speed.factor",
                value: $speedFactor,
                range: 25...300,
                step: 5,
                unit: "%",
                tint: Theme.printing
            ) { value in
                Task { await printer.setSpeedFactor(value) }
            }

            if speedFactor > 150 {
                warning("speed.warning.aggressive")
            }
        }
        .card()
    }

    private var flowCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("speed.flow", systemImage: "drop.fill")
            LabelledSlider(
                titleKey: "speed.flow",
                value: $flowFactor,
                range: 80...120,
                step: 1,
                unit: "%",
                tint: Theme.bed
            ) { value in
                Task { await printer.setExtrusionFactor(value) }
            }
        }
        .card()
    }

    /// One control per fan Klipper reported, addressed by its exact object name.
    ///
    /// A printer with a cooling upgrade has several fans, and the ones Klipper
    /// drives itself (heater_fan, controller_fan, temperature_fan) must be shown
    /// as read-only rather than given a slider that would have to guess at a
    /// pin. Before discovery has run, the part-cooling fan is the safe default
    /// because M106 is universal.
    private var fanCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader("fan.section", systemImage: "fanblades.fill")

            if printer.capabilities.fans.isEmpty {
                LabelledSlider(
                    titleKey: "speed.fan",
                    value: $fanPercent,
                    range: 0...100,
                    step: 5,
                    unit: "%"
                ) { value in
                    Task { await printer.setFanSpeed(value) }
                }
                presetRow { value in
                    fanPercent = value
                    Task { await printer.setFanSpeed(value) }
                }
            } else {
                ForEach(printer.capabilities.fans) { fan in
                    fanRow(fan)
                    if fan.id != printer.capabilities.fans.last?.id { Divider() }
                }
            }
        }
        .card()
    }

    @ViewBuilder
    private func fanRow(_ fan: PrinterCapabilities.FanSpec) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(fan.displayName).font(.subheadline.weight(.medium))
                Spacer()
                Text(fan.object).font(.caption2).monospaced().foregroundStyle(.secondary)
            }

            if fan.isControllable {
                // The part-cooling fan is the one the snapshot reports, so its
                // slider tracks live state; a fan_generic has no such feed and
                // stays where the user put it.
                let binding = fan.kind == "fan"
                    ? $fanPercent
                    : Binding(
                        get: { extraFanPercent[fan.object] ?? 0 },
                        set: { extraFanPercent[fan.object] = $0 }
                    )
                LabelledSlider(
                    titleKey: "speed.fan",
                    value: binding,
                    range: 0...100,
                    step: 5,
                    unit: "%"
                ) { value in
                    Task { await printer.setFan(fan, percent: value) }
                }
                presetRow { value in
                    binding.wrappedValue = value
                    Task { await printer.setFan(fan, percent: value) }
                }
            } else {
                Text(localized: "fan.read_only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func presetRow(_ action: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 10) {
            ForEach([0.0, 50.0, 100.0], id: \.self) { value in
                Button("\(Int(value))%") { action(value) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var advancedHint: some View {
        Button {
            settings.advancedMode = true
        } label: {
            HStack {
                Image(systemName: "lock.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text(localized: "speed.advanced.locked")
                        .font(.subheadline.weight(.semibold))
                    Text(localized: "speed.advanced.locked.hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .card()
    }

    private var advancedCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("speed.advanced", systemImage: "wrench.and.screwdriver.fill")
            warning("speed.warning.advanced")

            LabelledSlider(titleKey: "speed.max_velocity", value: $maxVelocity,
                           range: 50...600, step: 10, unit: " mm/s")
            LabelledSlider(titleKey: "speed.max_acceleration", value: $maxAcceleration,
                           range: 500...20_000, step: 100, unit: " mm/s²")
            LabelledSlider(titleKey: "speed.square_corner_velocity", value: $squareCornerVelocity,
                           range: 1...20, step: 0.5, unit: " mm/s")

            Button {
                Task {
                    await printer.setVelocityLimits(
                        velocity: maxVelocity,
                        acceleration: maxAcceleration,
                        squareCornerVelocity: squareCornerVelocity
                    )
                }
            } label: {
                Label(L.t("speed.apply_limits"), systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button(L.t("speed.reset_limits")) {
                Task { await printer.send(gcode: "SET_VELOCITY_LIMIT") }
                syncFromPrinter()
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)

            Text(localized: "speed.advanced.note")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    private func warning(_ key: String) -> some View {
        Label(L.t(key), systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(Theme.paused)
            .fixedSize(horizontal: false, vertical: true)
    }
}
