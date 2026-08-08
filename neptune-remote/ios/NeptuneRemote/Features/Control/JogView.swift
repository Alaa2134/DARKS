import SwiftUI

struct JogView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var printer: PrinterStore

    @State private var showingColdExtrusionAlert = false

    private let steps: [Double] = [0.1, 1, 5, 10, 50]
    private let feedrates: [Double] = [600, 1500, 3000, 6000, 9000]
    private let extrudeLengths: [Double] = [1, 5, 10, 25, 50]

    private var snapshot: PrinterSnapshot { printer.snapshot }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                if !snapshot.isReady { notReadyBanner }
                if let error = printer.lastError { errorBanner(error) }

                positionCard
                jogPad
                homingCard
                extruderCard
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .alert(L.t("control.cold_extrusion_title"), isPresented: $showingColdExtrusionAlert) {
            Button(L.t("common.ok"), role: .cancel) {}
            Button(L.t("control.cold_extrusion_override")) {
                settings.allowColdExtrusion = true
            }
        } message: {
            Text(L.t("control.cold_extrusion_blocked", settings.minExtrusionTemp))
        }
    }

    // MARK: - Cards

    private var notReadyBanner: some View {
        Label(L.t("error.klipper_not_ready"), systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline)
            .foregroundStyle(Theme.paused)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.paused.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
    }

    private func errorBanner(_ error: APIError) -> some View {
        ErrorBanner(message: error.localizedDescription, onDismiss: { printer.lastError = nil })
    }

    private var positionCard: some View {
        HStack(spacing: 12) {
            StatTile(titleKey: "machine.x", value: Format.coordinate(snapshot.x),
                     systemImage: "arrow.left.and.right",
                     tint: snapshot.isHomed("x") ? Theme.printing : Theme.idle)
            StatTile(titleKey: "machine.y", value: Format.coordinate(snapshot.y),
                     systemImage: "arrow.up.and.down",
                     tint: snapshot.isHomed("y") ? Theme.printing : Theme.idle)
            StatTile(titleKey: "machine.z", value: Format.coordinate(snapshot.z),
                     systemImage: "arrow.up.to.line",
                     tint: snapshot.isHomed("z") ? Theme.printing : Theme.idle)
        }
        .card()
    }

    private var jogPad: some View {
        VStack(spacing: 16) {
            SectionHeader("control.move", systemImage: "move.3d")

            stepPicker
            feedratePicker

            HStack(alignment: .center, spacing: 24) {
                xyPad
                zPad
            }

            Button {
                Task { await printer.disableSteppers() }
            } label: {
                Label(L.t("control.disable_steppers"), systemImage: "poweroff")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(snapshot.isActive)
        }
        .card()
    }

    private var stepPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localized: "control.step_size")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("", selection: $settings.jogStep) {
                ForEach(steps, id: \.self) { step in
                    Text(step < 1 ? String(format: "%.1f", step) : "\(Int(step))").tag(step)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var feedratePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localized: "control.feedrate")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("", selection: $settings.jogFeedrate) {
                ForEach(feedrates, id: \.self) { rate in
                    Text("\(Int(rate / 60))").tag(rate)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var xyPad: some View {
        VStack(spacing: 8) {
            jogButton(axis: "Y", sign: 1, systemImage: "chevron.up", label: "Y+")
            HStack(spacing: 8) {
                jogButton(axis: "X", sign: -1, systemImage: "chevron.left", label: "X-")
                Button {
                    Task { await printer.home("X Y") }
                } label: {
                    Image(systemName: "house.fill")
                        .frame(width: 52, height: 52)
                        .background(Theme.accent.opacity(0.15), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canMove)
                jogButton(axis: "X", sign: 1, systemImage: "chevron.right", label: "X+")
            }
            jogButton(axis: "Y", sign: -1, systemImage: "chevron.down", label: "Y-")
        }
    }

    private var zPad: some View {
        VStack(spacing: 8) {
            jogButton(axis: "Z", sign: 1, systemImage: "chevron.up", label: "Z+")
            Text("Z")
                .font(.headline)
                .frame(width: 52, height: 52)
            jogButton(axis: "Z", sign: -1, systemImage: "chevron.down", label: "Z-")
        }
    }

    private func jogButton(axis: String, sign: Double, systemImage: String, label: String) -> some View {
        Button {
            Task { await printer.jog(axis: axis, distance: sign * settings.jogStep, feedrate: settings.jogFeedrate) }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.headline)
                Text(label)
                    .font(.caption2.weight(.semibold))
            }
            .frame(width: 52, height: 52)
            .background(Theme.accent.opacity(canMove ? 0.15 : 0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .foregroundStyle(canMove ? Theme.accent : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!canMove)
        .accessibilityLabel(label)
    }

    private var canMove: Bool { snapshot.isReady && !snapshot.isActive }

    private var homingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("control.homing", systemImage: "house")
            HStack(spacing: 10) {
                BigActionButton(titleKey: "control.home_x", systemImage: "arrow.left.and.right",
                                isEnabled: canMove) { Task { await printer.home("X") } }
                BigActionButton(titleKey: "control.home_y", systemImage: "arrow.up.and.down",
                                isEnabled: canMove) { Task { await printer.home("Y") } }
                BigActionButton(titleKey: "control.home_z", systemImage: "arrow.up.to.line",
                                isEnabled: canMove) { Task { await printer.home("Z") } }
                BigActionButton(titleKey: "control.home_all", systemImage: "house.fill",
                                isEnabled: canMove) { Task { await printer.home() } }
            }
        }
        .card()
    }

    private var extruderCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("control.extruder", systemImage: "arrow.down.to.line")

            HStack {
                Text(localized: "temperature.nozzle")
                    .font(.subheadline)
                Spacer()
                Text(Format.temperature(snapshot.nozzleActual))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(canExtrude ? Theme.printing : Theme.paused)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(localized: "control.length")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $settings.extrudeLength) {
                    ForEach(extrudeLengths, id: \.self) { value in
                        Text("\(Int(value))").tag(value)
                    }
                }
                .pickerStyle(.segmented)
            }

            LabelledSlider(
                titleKey: "control.extrusion_speed",
                value: $settings.extrudeSpeed,
                range: 1...20,
                step: 1,
                unit: " mm/s"
            )

            HStack(spacing: 12) {
                BigActionButton(
                    titleKey: "control.extrude",
                    systemImage: "arrow.down",
                    tint: Theme.nozzle,
                    isEnabled: snapshot.isReady
                ) {
                    Task {
                        let ok = await printer.extrude(length: settings.extrudeLength, speedMMPerSecond: settings.extrudeSpeed)
                        if !ok { showingColdExtrusionAlert = true }
                    }
                }
                BigActionButton(
                    titleKey: "control.retract",
                    systemImage: "arrow.up",
                    tint: Theme.bed,
                    isEnabled: snapshot.isReady
                ) {
                    Task {
                        let ok = await printer.extrude(length: -settings.extrudeLength, speedMMPerSecond: settings.extrudeSpeed)
                        if !ok { showingColdExtrusionAlert = true }
                    }
                }
            }

            if !canExtrude && !settings.allowColdExtrusion {
                Label(L.t("control.cold_extrusion_hint", settings.minExtrusionTemp),
                      systemImage: "thermometer.snowflake")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if settings.allowColdExtrusion {
                Label(L.t("control.cold_extrusion_enabled"), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.paused)
            }
        }
        .card()
    }

    private var canExtrude: Bool {
        snapshot.canExtrude(minimumTemperature: settings.minExtrusionTemp) || settings.allowColdExtrusion
    }
}
