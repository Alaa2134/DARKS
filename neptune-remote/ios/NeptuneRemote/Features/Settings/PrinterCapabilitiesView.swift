import SwiftUI

/// Shows exactly what the app read out of this printer's configuration.
///
/// The point is auditability: if a control is missing or a limit looks wrong,
/// this page says what Klipper reported and the answer is either "your config
/// says so" or "the app misread it". Nothing here is typed in by the app.
struct PrinterCapabilitiesView: View {
    @EnvironmentObject private var printer: PrinterStore

    @State private var showingObjects = false
    @State private var macroToRun: PrinterCapabilities.MacroSpec?
    @State private var macroArguments = ""

    private var capabilities: PrinterCapabilities { printer.capabilities }

    var body: some View {
        List {
            if capabilities.isEmpty {
                Section {
                    Text(localized: "capabilities.none")
                        .foregroundStyle(.secondary)
                }
            } else {
                summarySection
                axesSection
                heatersSection
                fansSection
                sensorsSection
                filamentSection
                probeSection
                motionSection
                modulesSection
                macrosSection
                objectsSection
            }

            Section {
                Button {
                    printer.refreshCapabilities(force: true)
                } label: {
                    Label(L.t("capabilities.refresh"), systemImage: "arrow.clockwise")
                }
                if let error = printer.capabilityError {
                    FailureNote(labelKey: "capabilities.title", error: error)
                }
            }
        }
        .navigationTitle(L.t("capabilities.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if capabilities.isEmpty { printer.refreshCapabilities() }
        }
        .sheet(item: $macroToRun) { macro in
            NavigationStack { macroSheet(macro) }
        }
    }

    // MARK: - Sections

    private var summarySection: some View {
        Section {
            InfoRow(titleKey: "capabilities.klipper_version", value: capabilities.klipperVersion)
            if let kinematics = capabilities.kinematics {
                InfoRow(titleKey: "capabilities.kinematics", value: kinematics)
            }
            if let date = capabilities.discoveredAt {
                InfoRow(
                    titleKey: "capabilities.discovered_at",
                    value: date.formatted(date: .omitted, time: .standard)
                )
            }
            InfoRow(titleKey: "capabilities.signature", value: capabilities.configSignature)
        } header: {
            Text(localized: "capabilities.subtitle")
        }
    }

    private var axesSection: some View {
        Section {
            ForEach(["x", "y", "z"], id: \.self) { axis in
                if let limit = capabilities.axisLimits[axis] {
                    InfoRow(
                        titleKey: "machine.\(axis)",
                        value: String(format: "%.1f … %.1f mm  (%.0f)", limit.min, limit.max, limit.span)
                    )
                }
            }
            if let home = capabilities.safeZHome {
                InfoRow(
                    titleKey: "capabilities.safe_z_home",
                    value: String(
                        format: "X%.1f Y%.1f%@",
                        home.x ?? 0, home.y ?? 0,
                        home.zHop.map { String(format: "  z_hop %.1f", $0) } ?? ""
                    )
                )
            }
        } header: {
            Text(localized: "capabilities.axes")
        } footer: {
            Text(verbatim: "stepper_x/y/z position_min, position_max")
        }
    }

    @ViewBuilder
    private var heatersSection: some View {
        if !capabilities.heaters.isEmpty {
            Section {
                ForEach(capabilities.heaters) { heater in
                    VStack(alignment: .leading, spacing: 2) {
                        InfoRow(
                            titleKey: "",
                            value: String(format: "%.0f … %.0f °C", heater.minTemp, heater.maxTemp)
                        )
                        .overlay(alignment: .leading) {
                            Text(heater.object)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if let sensor = heater.sensorType {
                            Text(sensor).font(.caption2).foregroundStyle(.secondary)
                        }
                        if let minimum = heater.minExtrudeTemp {
                            Text(verbatim: String(format: "min_extrude_temp %.0f °C", minimum))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text(localized: "capabilities.heaters")
            }
        }
    }

    @ViewBuilder
    private var fansSection: some View {
        if !capabilities.fans.isEmpty {
            Section {
                ForEach(capabilities.fans) { fan in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(fan.displayName)
                            Text(fan.object).font(.caption2).monospaced().foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !fan.isControllable {
                            Text(localized: "fan.read_only")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text(localized: "fan.section")
            }
        }
    }

    @ViewBuilder
    private var sensorsSection: some View {
        if !capabilities.temperatureSensors.isEmpty {
            Section {
                ForEach(capabilities.temperatureSensors) { sensor in
                    HStack {
                        Text(sensor.displayName)
                        Spacer()
                        Text(sensor.object).font(.caption2).monospaced().foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(localized: "capabilities.sensors")
            }
        }
    }

    @ViewBuilder
    private var filamentSection: some View {
        if !capabilities.filamentSensors.isEmpty {
            Section {
                ForEach(capabilities.filamentSensors) { sensor in
                    HStack {
                        Text(sensor.name)
                        Spacer()
                        Text(sensor.kind).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(localized: "capabilities.filament_sensors")
            }
        }
    }

    @ViewBuilder
    private var probeSection: some View {
        Section {
            if let probe = capabilities.probe {
                InfoRow(titleKey: "capabilities.probe", value: probe.kind)
                if let z = probe.zOffset {
                    InfoRow(titleKey: "", value: String(format: "z_offset %.3f", z))
                }
                if let x = probe.xOffset, let y = probe.yOffset {
                    InfoRow(titleKey: "", value: String(format: "offset X%.2f Y%.2f", x, y))
                }
            } else {
                Text(localized: "capabilities.no_probe")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let mesh = capabilities.bedMesh {
                InfoRow(
                    titleKey: "capabilities.bed_mesh",
                    value: mesh.algorithm ?? L.t("capabilities.present")
                )
                if let min = mesh.meshMin, let max = mesh.meshMax, min.count >= 2, max.count >= 2 {
                    InfoRow(
                        titleKey: "",
                        value: String(
                            format: "%.0f,%.0f → %.0f,%.0f", min[0], min[1], max[0], max[1]
                        )
                    )
                }
                if let count = mesh.probeCount, count.count >= 2 {
                    InfoRow(titleKey: "", value: String(format: "probe_count %.0f×%.0f", count[0], count[1]))
                }
                if !mesh.profiles.isEmpty {
                    InfoRow(titleKey: "", value: mesh.profiles.joined(separator: ", "))
                }
            }
        } header: {
            Text(localized: "capabilities.probe")
        }
    }

    @ViewBuilder
    private var motionSection: some View {
        Section {
            if let value = capabilities.maxVelocity {
                InfoRow(titleKey: "speed.max_velocity", value: String(format: "%.0f mm/s", value))
            }
            if let value = capabilities.maxAccel {
                InfoRow(titleKey: "speed.max_acceleration", value: String(format: "%.0f mm/s²", value))
            }
            if let value = capabilities.maxZVelocity {
                InfoRow(titleKey: "", value: String(format: "max_z_velocity %.0f mm/s", value))
            }
            if let value = capabilities.maxZAccel {
                InfoRow(titleKey: "", value: String(format: "max_z_accel %.0f mm/s²", value))
            }
            if let value = capabilities.squareCornerVelocity {
                InfoRow(
                    titleKey: "speed.square_corner_velocity",
                    value: String(format: "%.1f mm/s", value)
                )
            }
        } header: {
            Text(localized: "capabilities.motion")
        } footer: {
            Text(localized: "speed.advanced.note")
        }
    }

    private var modulesSection: some View {
        Section {
            moduleRow("bed_mesh", capabilities.hasBedMesh)
            moduleRow("pause_resume", capabilities.hasPauseResume)
            moduleRow("virtual_sdcard", capabilities.hasVirtualSDCard)
            moduleRow("display_status", capabilities.hasDisplayStatus)
            moduleRow("exclude_object", capabilities.hasExcludeObject)
            moduleRow("input_shaper", capabilities.hasInputShaper)
            moduleRow("resonance_tester", capabilities.hasResonanceTester)
            moduleRow("skew_correction", capabilities.hasSkewCorrection)
            moduleRow("firmware_retraction", capabilities.hasFirmwareRetraction)
            moduleRow("save_variables", capabilities.hasSaveVariables)
            moduleRow("idle_timeout", capabilities.hasIdleTimeout)
            moduleRow("screws_tilt_adjust", capabilities.hasScrewsTiltAdjust)
            moduleRow("z_tilt", capabilities.hasZTiltAdjust)
            moduleRow("quad_gantry_level", capabilities.hasQuadGantryLevel)
            ForEach(capabilities.accelerometers, id: \.self) { name in
                moduleRow(name, true)
            }
        } header: {
            Text(localized: "capabilities.modules")
        }
    }

    private func moduleRow(_ name: String, _ present: Bool) -> some View {
        HStack {
            Text(name).font(.subheadline).monospaced()
            Spacer()
            Image(systemName: present ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(present ? Theme.printing : Color.secondary)
        }
    }

    @ViewBuilder
    private var macrosSection: some View {
        if !capabilities.macros.isEmpty {
            Section {
                ForEach(capabilities.macros) { macro in
                    Button {
                        macroArguments = ""
                        macroToRun = macro
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(macro.name).monospaced()
                                if let description = macro.description, !description.isEmpty {
                                    Text(description)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if macro.needsConfirmation {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(Theme.paused)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("\(L.t("capabilities.macros")) · \(L.t("capabilities.macro_count", capabilities.macros.count))")
            }
        }
    }

    private var objectsSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showingObjects) {
                ForEach(capabilities.objects, id: \.self) { object in
                    Text(object).font(.caption2).monospaced().textSelection(.enabled)
                }
            } label: {
                Text(L.t("capabilities.object_count", capabilities.objects.count))
            }
        } header: {
            Text(localized: "capabilities.objects")
        }
    }

    // MARK: - Macro confirmation

    /// Running a macro always goes through this sheet. The body is the user's
    /// own G-code and the app cannot know what it does, so it says which macro
    /// is about to run and makes them tap again.
    private func macroSheet(_ macro: PrinterCapabilities.MacroSpec) -> some View {
        Form {
            Section {
                Text(macro.name).font(.title3.monospaced().weight(.semibold))
                if let description = macro.description, !description.isEmpty {
                    Text(description).font(.callout).foregroundStyle(.secondary)
                }
                Text(localized: "capabilities.macro_confirm_body")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if macro.hasParameters {
                Section {
                    TextField(L.t("capabilities.macro_arguments"), text: $macroArguments)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                }
            }

            Section {
                Button {
                    let arguments = macroArguments
                    macroToRun = nil
                    Task { await printer.runMacro(macro, arguments: arguments) }
                } label: {
                    Text(localized: "capabilities.run")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(macro.needsConfirmation ? Theme.paused : Theme.accent)
            }
        }
        .navigationTitle(L.t("capabilities.macro_confirm", macro.name))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L.t("common.cancel")) { macroToRun = nil }
            }
        }
    }
}
