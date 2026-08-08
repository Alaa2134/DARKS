import SwiftUI

/// First-launch configuration wizard. Pre-filled with the documented Tailscale
/// address of the user's Raspberry Pi.
struct SetupWizardView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var printer: PrinterStore
    @EnvironmentObject private var notifications: NotificationManager

    @State private var step: Int = 0
    @State private var isTesting = false
    @State private var diagnostics: PrinterStore.Diagnostics?

    private var moonrakerOK: Bool? { diagnostics?.moonrakerReachable }
    private var backendOK: Bool? { diagnostics?.backendReachable }

    private let lastStep = 7

    var body: some View {
        VStack(spacing: 0) {
            ProgressView(value: Double(step), total: Double(lastStep))
                .padding(.horizontal)
                .padding(.top, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacing) {
                    switch step {
                    case 0: welcomeStep
                    case 1: addressStep
                    case 2: testStep
                    case 3: moonrakerStep
                    case 4: backendStep
                    case 5: powerStep
                    case 6: cameraStep
                    default: finishStep
                    }
                }
                .padding()
            }

            navigationBar
        }
        .background(Theme.pageFill)
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "printer.fill")
                .font(.system(size: 56))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity)

            Text(localized: "setup.welcome.title")
                .font(.largeTitle.weight(.bold))
            Text(localized: "setup.welcome.message")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                bullet("setup.welcome.point1", systemImage: "bolt.fill")
                bullet("setup.welcome.point2", systemImage: "thermometer.medium")
                bullet("setup.welcome.point3", systemImage: "cube.transparent")
                bullet("setup.welcome.point4", systemImage: "lock.shield")
            }
            .card()

            Button {
                settings.demoMode = true
                complete()
            } label: {
                Label(L.t("setup.try_demo"), systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private func bullet(_ key: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
            Text(localized: key)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var addressStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepTitle("setup.address.title", "setup.address.message")

            VStack(alignment: .leading, spacing: 12) {
                LabeledContent(L.t("settings.host")) {
                    TextField("100.78.2.66", text: $settings.host)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                Divider()
                LabeledContent(L.t("settings.moonraker_port")) {
                    TextField("80", value: $settings.moonrakerPort, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                }
                Divider()
                LabeledContent(L.t("settings.backend_port")) {
                    TextField("8710", value: $settings.backendPort, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                }
                Divider()
                Toggle(L.t("settings.use_https"), isOn: $settings.useHTTPS)
            }
            .card()

            Text(localized: "setup.address.hint")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var testStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepTitle("setup.test.title", "setup.test.message")

            ConnectionTestPanel(diagnostics: diagnostics, isTesting: isTesting)

            Button {
                Task { await runTest() }
            } label: {
                HStack {
                    if isTesting { ProgressView().controlSize(.small) }
                    Text(localized: "setup.run_test")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .task { await runTest() }
    }

    private var moonrakerStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepTitle("setup.moonraker.title", "setup.moonraker.message")

            VStack(alignment: .leading, spacing: 10) {
                InfoRow(
                    titleKey: "diagnostics.moonraker_url",
                    value: settings.connection.moonrakerBaseURL?.absoluteString ?? "--"
                )
                InfoRow(
                    titleKey: "diagnostics.moonraker",
                    value: L.t(moonrakerOK == true ? "status.ok" : "status.failed"),
                    tint: moonrakerOK == true ? Theme.printing : Theme.danger
                )
                Divider()
                SecureField(L.t("settings.moonraker_api_key"), text: $settings.moonrakerAPIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text(localized: "setup.moonraker.apikey_hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .card()
        }
    }

    private var backendStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepTitle("setup.backend.title", "setup.backend.message")

            VStack(alignment: .leading, spacing: 10) {
                InfoRow(
                    titleKey: "diagnostics.backend_url",
                    value: settings.connection.backendBaseURL?.absoluteString ?? "--"
                )
                InfoRow(
                    titleKey: "diagnostics.backend",
                    value: L.t(backendOK == true ? "status.ok" : "status.failed"),
                    tint: backendOK == true ? Theme.printing : Theme.paused
                )
                Divider()
                SecureField(L.t("settings.backend_token"), text: $settings.backendToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .card()

            Text(localized: "setup.backend.install_hint")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(verbatim: "cd neptune-remote/raspberry-pi && ./install.sh")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var powerStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepTitle("setup.power.title", "setup.power.message")

            VStack(alignment: .leading, spacing: 10) {
                Picker(L.t("settings.power_provider"), selection: $settings.powerProvider) {
                    ForEach(PowerProviderKind.allCases) { kind in
                        Text(localized: kind.localizationKey).tag(kind)
                    }
                }
                .pickerStyle(.menu)

                Text(localized: "setup.power.tuya_hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if settings.powerProvider == .moonraker {
                    LabeledContent(L.t("settings.moonraker_power_device")) {
                        TextField("printer", text: $settings.moonrakerPowerDevice)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .card()

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("settings.section.safety", systemImage: "shield.lefthalf.filled")
                HStack {
                    Text(localized: "settings.safe_nozzle_temp")
                    Spacer()
                    Text("\(Int(settings.safeNozzleTemp))°C").monospacedDigit()
                }
                Slider(value: $settings.safeNozzleTemp, in: 30...120, step: 5)
                HStack {
                    Text(localized: "settings.safe_bed_temp")
                    Spacer()
                    Text("\(Int(settings.safeBedTemp))°C").monospacedDigit()
                }
                Slider(value: $settings.safeBedTemp, in: 25...90, step: 5)
            }
            .card()
        }
    }

    private var cameraStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepTitle("setup.camera.title", "setup.camera.message")

            VStack(alignment: .leading, spacing: 10) {
                Picker(L.t("camera.kind"), selection: $settings.cameraKind) {
                    ForEach(CameraKind.allCases) { kind in
                        Text(localized: kind.localizationKey).tag(kind)
                    }
                }
                TextField(L.t("camera.url"), text: $settings.cameraURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button(L.t("setup.camera.use_default")) {
                    settings.cameraURL = settings.connection.defaultCameraStreamURL
                }
                .font(.caption)
            }
            .card()

            Text(localized: "setup.camera.optional")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(Theme.printing)
                .frame(maxWidth: .infinity)

            Text(localized: "setup.finish.title")
                .font(.largeTitle.weight(.bold))
            Text(localized: "setup.finish.message")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                InfoRow(titleKey: "settings.host", value: settings.host)
                InfoRow(
                    titleKey: "diagnostics.moonraker",
                    value: L.t(moonrakerOK == true ? "status.ok" : "status.failed"),
                    tint: moonrakerOK == true ? Theme.printing : Theme.danger
                )
                InfoRow(
                    titleKey: "diagnostics.backend",
                    value: L.t(backendOK == true ? "status.ok" : "status.failed"),
                    tint: backendOK == true ? Theme.printing : Theme.paused
                )
                InfoRow(titleKey: "settings.power_provider", value: L.t(settings.powerProvider.localizationKey))
            }
            .card()

            Button {
                Task { await notifications.requestAuthorization() }
            } label: {
                Label(L.t("setup.enable_notifications"), systemImage: "bell.badge")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private func stepTitle(_ titleKey: String, _ messageKey: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(localized: titleKey)
                .font(.title2.weight(.bold))
            Text(localized: messageKey)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Navigation

    private var navigationBar: some View {
        HStack(spacing: 12) {
            if step > 0 {
                Button(L.t("common.back")) {
                    withAnimation { step -= 1 }
                }
                .buttonStyle(.bordered)
            }
            Spacer()
            Button(step == lastStep ? L.t("setup.finish") : L.t("common.next")) {
                if step == lastStep {
                    complete()
                } else {
                    withAnimation { step += 1 }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(step == 1 && !settings.connection.isValid)
        }
        .padding()
        .background(.bar)
    }

    private func complete() {
        settings.hasCompletedSetup = true
        printer.start()
        Haptics.success()
    }

    private func runTest() async {
        isTesting = true
        diagnostics = nil
        defer { isTesting = false }
        diagnostics = await printer.runDiagnostics()
    }
}
