import SwiftUI

struct JogView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var printer: PrinterStore

    @State private var showingColdExtrusionAlert = false
    @State private var showingAssumePositionConfirm = false

    private let steps: [Double] = [0.1, 1, 5, 10, 50]
    private let feedrates: [Double] = [600, 1500, 3000, 6000, 9000]
    private let extrudeLengths: [Double] = [1, 5, 10, 25, 50]

    private var snapshot: PrinterSnapshot { printer.snapshot }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                if !snapshot.isReady { notReadyBanner }

                positionCard
                jogPad
                homingCard
                // Only when homing has not happened, which is the only time it
                // is any use and the only time it is defensible.
                if !unhomedAxes.isEmpty { unhomedEscapeCard }
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
                    Task { await printer.home(axes: "X Y") }
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
                                isEnabled: canMove) { Task { await printer.home(axes: "X") } }
                BigActionButton(titleKey: "control.home_y", systemImage: "arrow.up.and.down",
                                isEnabled: canMove) { Task { await printer.home(axes: "Y") } }
                BigActionButton(titleKey: "control.home_z", systemImage: "arrow.up.to.line",
                                isEnabled: canMove) { Task { await printer.home(axes: "Z") } }
                BigActionButton(titleKey: "control.home_all", systemImage: "house.fill",
                                isEnabled: canMove) { Task { await printer.home() } }
            }
        }
        .card()
    }

    // MARK: - When homing will not work

    private var unhomedAxes: [String] {
        guard snapshot.isReady, !snapshot.isActive else { return [] }
        return ["x", "y", "z"].filter { !snapshot.isHomed($0) }
    }

    /// The way out of a printer that cannot home.
    ///
    /// When the probe is dead, `G28` fails, and after that Klipper refuses every
    /// move - so the nozzle cannot be raised off the bed to go and look at the
    /// probe that caused it. The app inherited that deadlock and made it worse
    /// by greying its own buttons out on top of it: a machine you cannot touch
    /// because the part that says where it is has broken.
    ///
    /// `SET_KINEMATIC_POSITION` asserts a position instead of measuring one.
    /// That is not homing and is not presented as homing - the number is a
    /// claim, and a wrong claim will drive the toolhead somewhere that does not
    /// exist. What makes it safe enough to offer is the direction: each axis is
    /// declared at the bottom of its own travel, so the only way left to go is
    /// away from the bed.
    private var unhomedEscapeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("control.unhomed.title", systemImage: "exclamationmark.arrow.circlepath")

            Text(localized: "control.unhomed.explain")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label(
                L.t("control.unhomed.axes", unhomedAxes.map { $0.uppercased() }.joined(separator: "، ")),
                systemImage: "location.slash"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.paused)

            if printer.capabilities.canSetKinematicPosition {
                Text(localized: "control.unhomed.warning")
                    .font(.caption2)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    showingAssumePositionConfirm = true
                } label: {
                    Label(L.t("control.unhomed.assume"), systemImage: "hand.raised")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(printer.isBusy)
            } else {
                // The command is not registered on this printer, so the button
                // would come back "Unknown command" - which is how a print on
                // this machine has already been lost once. Say what to add
                // instead; the app does not write printer.cfg.
                Text(localized: "control.unhomed.needs_force_move")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)

                Text(verbatim: "[force_move]\nenable_force_move: True")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .card()
        .confirmationDialog(
            L.t("control.unhomed.confirm.title"),
            isPresented: $showingAssumePositionConfirm,
            titleVisibility: .visible
        ) {
            Button(L.t("control.unhomed.assume"), role: .destructive) {
                Task { await assumeBottomOfTravel() }
            }
            Button(L.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(localized: "control.unhomed.confirm.message")
        }
    }

    /// Declares every unhomed axis to be at the bottom of its configured travel.
    ///
    /// The bottom rather than the middle or the current reading, because it is
    /// the one claim that cannot send the toolhead further down: whatever the
    /// truth is, the printer now believes it has no room left in the direction
    /// that breaks things.
    private func assumeBottomOfTravel() async {
        func floor(_ axis: String) -> Double? {
            guard unhomedAxes.contains(axis) else { return nil }
            return printer.capabilities.axisLimits[axis]?.min ?? 0
        }
        await printer.assumePosition(x: floor("x"), y: floor("y"), z: floor("z"))
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
