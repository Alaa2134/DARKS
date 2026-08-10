import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var printer: PrinterStore
    @EnvironmentObject private var notifications: NotificationManager
    @EnvironmentObject private var alerts: AlertStore
    @Environment(\.dismiss) private var dismiss

    @State private var showingResetConfirm = false
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            connectionSection
            appearanceSection
            powerSection
            safetySection
            autoPowerOffSection
            notificationsSection
            cameraSection
            modesSection
            aboutSection
        }
        .navigationTitle(L.t("settings.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L.t("common.done")) { dismiss() }
            }
        }
        .confirmationDialog(
            L.t("settings.reset.confirm"),
            isPresented: $showingResetConfirm,
            titleVisibility: .visible
        ) {
            Button(L.t("settings.reset"), role: .destructive) {
                settings.resetEverything()
                settings.hasCompletedSetup = false
                dismiss()
            }
            Button(L.t("common.cancel"), role: .cancel) {}
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section {
            LabeledContent(L.t("settings.host")) {
                TextField("100.78.2.66", text: $settings.host)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            }
            LabeledContent(L.t("settings.moonraker_port")) {
                TextField("80", value: $settings.moonrakerPort, format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
            }
            LabeledContent(L.t("settings.backend_port")) {
                TextField("8710", value: $settings.backendPort, format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
            }
            Toggle(L.t("settings.use_https"), isOn: $settings.useHTTPS)

            LabeledContent(L.t("settings.printer_name")) {
                TextField("Neptune 3 Plus", text: $settings.printerName)
                    .multilineTextAlignment(.trailing)
            }

            SecureField(L.t("settings.backend_token"), text: $settings.backendToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField(L.t("settings.moonraker_api_key"), text: $settings.moonrakerAPIKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button {
                Task { await testConnection() }
            } label: {
                HStack {
                    if isTesting { ProgressView().controlSize(.small) }
                    Text(localized: "settings.test_connection")
                }
            }
            if let testResult {
                Text(testResult)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            NavigationLink(destination: NetworkDiagnosticsView()) {
                Label(L.t("diagnostics.title"), systemImage: "stethoscope")
            }
        } header: {
            Text(localized: "settings.section.connection")
        } footer: {
            Text(localized: "settings.section.connection.footer")
        }
    }

    private func testConnection() async {
        isTesting = true
        defer { isTesting = false }
        let diagnostics = await printer.runDiagnostics()
        var lines: [String] = []
        lines.append("\(L.t("diagnostics.moonraker")): \(status(diagnostics.moonrakerReachable))")
        lines.append("\(L.t("diagnostics.backend")): \(status(diagnostics.backendReachable))")
        if let error = diagnostics.moonrakerError {
            lines.append("\(L.t("diagnostics.moonraker")): \(error.localizedDescription)")
            if let hint = error.troubleshootingKey { lines.append(L.t(hint)) }
        }
        if let error = diagnostics.backendError {
            lines.append("\(L.t("diagnostics.backend")): \(error.localizedDescription)")
            if let hint = error.troubleshootingKey { lines.append(L.t(hint)) }
        }
        testResult = lines.joined(separator: "\n")
        Haptics.impact(.light)
    }

    private func status(_ value: Bool?) -> String {
        guard let value else { return "…" }
        return L.t(value ? "status.ok" : "status.failed")
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section(L.t("settings.section.appearance")) {
            Picker(L.t("settings.appearance"), selection: $settings.appearance) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(localized: mode.localizationKey).tag(mode)
                }
            }
            Picker(L.t("settings.language"), selection: $settings.language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            Toggle(L.t("settings.haptics"), isOn: $settings.hapticsEnabled)
        }
    }

    // MARK: - Power

    private var powerSection: some View {
        Section {
            Picker(L.t("settings.power_provider"), selection: $settings.powerProvider) {
                ForEach(PowerProviderKind.allCases) { kind in
                    Text(localized: kind.localizationKey).tag(kind)
                }
            }

            switch settings.powerProvider {
            case .moonraker:
                LabeledContent(L.t("settings.moonraker_power_device")) {
                    TextField("printer", text: $settings.moonrakerPowerDevice)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                }
            case .webhook:
                LabeledContent(L.t("settings.webhook_on")) {
                    TextField("https://…", text: $settings.webhookOnURL)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                LabeledContent(L.t("settings.webhook_off")) {
                    TextField("https://…", text: $settings.webhookOffURL)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                LabeledContent(L.t("settings.webhook_status")) {
                    TextField("https://…", text: $settings.webhookStatusURL)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            case .backend:
                Text(localized: "settings.power.backend_hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .demo, .none:
                EmptyView()
            }

            LabeledContent(L.t("power.state")) {
                Text(localized: printer.power.state.localizationKey)
                    .foregroundStyle(Theme.color(for: printer.power.state))
            }
            Button(L.t("settings.refresh_power")) {
                Task { await printer.refreshPower() }
            }
        } header: {
            Text(localized: "settings.section.power")
        } footer: {
            Text(localized: "settings.section.power.footer")
        }
    }

    // MARK: - Safety

    private var safetySection: some View {
        Section {
            VStack(alignment: .leading) {
                HStack {
                    Text(localized: "settings.safe_nozzle_temp")
                    Spacer()
                    Text("\(Int(settings.safeNozzleTemp))°C").monospacedDigit()
                }
                Slider(value: $settings.safeNozzleTemp, in: 30...120, step: 5)
            }
            VStack(alignment: .leading) {
                HStack {
                    Text(localized: "settings.safe_bed_temp")
                    Spacer()
                    Text("\(Int(settings.safeBedTemp))°C").monospacedDigit()
                }
                Slider(value: $settings.safeBedTemp, in: 25...90, step: 5)
            }
            Toggle(L.t("settings.require_checklist"), isOn: $settings.requirePrintChecklist)
                .disabled(!settings.developerMode && !settings.requirePrintChecklist)

            Toggle(L.t("settings.allow_cold_extrusion"), isOn: $settings.allowColdExtrusion)
            VStack(alignment: .leading) {
                HStack {
                    Text(localized: "settings.min_extrusion_temp")
                    Spacer()
                    Text("\(Int(settings.minExtrusionTemp))°C").monospacedDigit()
                }
                Slider(value: $settings.minExtrusionTemp, in: 120...240, step: 5)
            }
        } header: {
            Text(localized: "settings.section.safety")
        } footer: {
            Text(localized: "settings.section.safety.footer")
        }
    }

    // MARK: - Auto power off

    private var autoPowerOffSection: some View {
        Section {
            Toggle(L.t("settings.auto_power_off"), isOn: $settings.autoPowerOffEnabled)
            if settings.autoPowerOffEnabled {
                VStack(alignment: .leading) {
                    HStack {
                        Text(localized: "settings.auto_power_off_nozzle")
                        Spacer()
                        Text("\(Int(settings.autoPowerOffNozzle))°C").monospacedDigit()
                    }
                    Slider(value: $settings.autoPowerOffNozzle, in: 30...120, step: 5)
                }
                VStack(alignment: .leading) {
                    HStack {
                        Text(localized: "settings.auto_power_off_bed")
                        Spacer()
                        Text("\(Int(settings.autoPowerOffBed))°C").monospacedDigit()
                    }
                    Slider(value: $settings.autoPowerOffBed, in: 25...90, step: 5)
                }
                VStack(alignment: .leading) {
                    HStack {
                        Text(localized: "settings.auto_power_off_delay")
                        Spacer()
                        Text(Format.duration(settings.autoPowerOffDelay)).monospacedDigit()
                    }
                    Slider(value: $settings.autoPowerOffDelay, in: 0...1800, step: 60)
                }
            }
        } header: {
            Text(localized: "settings.section.auto_power_off")
        } footer: {
            Text(localized: "settings.section.auto_power_off.footer")
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        Section {
            // Out-of-house alerting gets its own screen and its own line here,
            // because "notifications are on" in this app has meant local
            // notifications - which need the app running, and so are worth
            // nothing when the phone is in a pocket somewhere else.
            NavigationLink(destination: AlertSettingsView()) {
                LabeledContent(L.t("alerts.title")) {
                    Text(L.t(alerts.isReachableWhenClosed
                             ? "alerts.reachable.short.yes"
                             : "alerts.reachable.short.no"))
                        .foregroundStyle(alerts.isReachableWhenClosed ? Theme.printing : Theme.danger)
                }
            }

            Toggle(L.t("settings.notifications"), isOn: $settings.notificationsEnabled)
            if settings.notificationsEnabled {
                Toggle(L.t("settings.notify_state_changes"), isOn: $settings.notifyPrintStateChanges)
                Toggle(L.t("settings.notify_finished"), isOn: $settings.notifyPrintFinished)
                Toggle(L.t("settings.notify_failed"), isOn: $settings.notifyPrintFailed)
                Toggle(L.t("settings.notify_klipper"), isOn: $settings.notifyKlipperError)
                Toggle(L.t("settings.notify_disconnected"), isOn: $settings.notifyDisconnected)
                Toggle(L.t("settings.notify_target"), isOn: $settings.notifyTargetReached)

                if notifications.authorizationStatus == .denied {
                    Label(L.t("settings.notifications.denied"), systemImage: "bell.slash")
                        .font(.caption)
                        .foregroundStyle(Theme.paused)
                } else if notifications.authorizationStatus != .authorized {
                    Button(L.t("settings.notifications.request")) {
                        Task { await notifications.requestAuthorization() }
                    }
                }
            }
        } header: {
            Text(localized: "settings.section.notifications")
        } footer: {
            Text(localized: "settings.section.notifications.footer")
        }
    }

    // MARK: - Camera

    private var cameraSection: some View {
        Section(L.t("settings.section.camera")) {
            NavigationLink(destination: CameraSettingsView()) {
                LabeledContent(L.t("camera.settings")) {
                    Text(settings.cameraURL.isEmpty ? L.t("camera.not_configured") : settings.cameraURL)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Modes

    private var modesSection: some View {
        Section {
            Toggle(L.t("settings.demo_mode"), isOn: $settings.demoMode)
            Toggle(L.t("settings.advanced_mode"), isOn: $settings.advancedMode)
            Toggle(L.t("settings.developer_mode"), isOn: $settings.developerMode)
            if settings.developerMode {
                NavigationLink(destination: DeveloperSettingsView()) {
                    Label(L.t("settings.developer"), systemImage: "hammer")
                }
            }
        } header: {
            Text(localized: "settings.section.modes")
        } footer: {
            Text(localized: "settings.section.modes.footer")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section(L.t("settings.section.about")) {
            LabeledContent(L.t("settings.version")) {
                Text("\(Bundle.main.appVersion) (\(Bundle.main.buildNumber))")
            }
            if let health = printer.backendHealth {
                LabeledContent(L.t("settings.backend_version")) { Text(health.version) }
                LabeledContent(L.t("diagnostics.slicer")) { Text(health.slicerEngine) }
            }
            Button(L.t("settings.rerun_setup")) {
                settings.hasCompletedSetup = false
                dismiss()
            }
            Button(L.t("settings.reset"), role: .destructive) {
                showingResetConfirm = true
            }
        }
    }
}

// MARK: - Camera settings

struct CameraSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker(L.t("camera.kind"), selection: $settings.cameraKind) {
                    ForEach(CameraKind.allCases) { kind in
                        Text(localized: kind.localizationKey).tag(kind)
                    }
                }
                TextField(L.t("camera.url"), text: $settings.cameraURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            } header: {
                Text(localized: "camera.settings")
            } footer: {
                Text(localized: "camera.url.footer")
            }

            Section {
                // An IP camera does not appear in this list, and cannot: it
                // speaks RTSP, and no URL you could paste here would open on
                // a phone. This picks the Pi's relay instead, and the RTSP
                // address itself stays in config.yaml with its password.
                Button {
                    settings.cameraURL = ConnectionConfig.backendRelaySentinel
                    settings.cameraKind = .mjpeg
                } label: {
                    HStack {
                        Label(L.t("camera.ip_camera"), systemImage: "web.camera")
                        Spacer()
                        if settings.cameraURL == ConnectionConfig.backendRelaySentinel {
                            Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                        }
                    }
                }
                ForEach(presets, id: \.self) { preset in
                    Button(preset) { settings.cameraURL = preset }
                        .font(.system(.footnote, design: .monospaced))
                }
            } header: {
                Text(localized: "camera.presets")
            } footer: {
                Text(localized: "camera.ip_camera.hint")
            }

            Section(L.t("camera.image")) {
                Picker(L.t("camera.rotation"), selection: $settings.cameraRotation) {
                    Text("0°").tag(0)
                    Text("90°").tag(90)
                    Text("180°").tag(180)
                    Text("270°").tag(270)
                }
                Toggle(L.t("camera.mirror"), isOn: $settings.cameraMirrored)
            }
        }
        .navigationTitle(L.t("camera.settings"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var presets: [String] { settings.connection.cameraPresets }
}

// MARK: - Developer settings

struct DeveloperSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var printer: PrinterStore

    var body: some View {
        Form {
            Section {
                Toggle(L.t("settings.require_checklist"), isOn: $settings.requirePrintChecklist)
                Text(localized: "settings.developer.checklist_warning")
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
            } header: {
                Text(localized: "settings.developer.safety")
            }

            Section(L.t("settings.developer.actions")) {
                Button(L.t("action.restart_klipper")) {
                    Task { await printer.restartKlipper() }
                }
                Button(L.t("action.restart_firmware")) {
                    Task { await printer.restartFirmware() }
                }
                Button(L.t("action.restart_moonraker")) {
                    Task { await printer.restartMoonraker() }
                }
            }

            Section(L.t("settings.developer.state")) {
                LabeledContent("Klippy") { Text(printer.snapshot.klippy.rawValue) }
                LabeledContent("State") { Text(printer.snapshot.state.rawValue) }
                LabeledContent("WebSocket") {
                    Text(printer.moonrakerConnected ? "connected" : "disconnected")
                }
                LabeledContent("Backend WS") {
                    Text(printer.backendConnected ? "connected" : "disconnected")
                }
                LabeledContent("Samples") { Text("\(printer.temperatureHistory.count)") }
            }
        }
        .navigationTitle(L.t("settings.developer"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
