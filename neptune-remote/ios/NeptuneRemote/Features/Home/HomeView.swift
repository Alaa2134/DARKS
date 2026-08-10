import SwiftUI

struct HomeView: View {
    @Binding var showingSettings: Bool

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var printer: PrinterStore
    @EnvironmentObject private var files: FilesStore
    @EnvironmentObject private var alerts: AlertStore
    @EnvironmentObject private var calibration: CalibrationStore

    @State private var showingPowerOffWarning = false
    @State private var showingPreheatSheet = false

    private var snapshot: PrinterSnapshot { printer.snapshot }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Theme.spacing) {
                if settings.demoMode { demoBanner }

                // Above the printer state on purpose. If a print died while
                // nobody was home, that is the first thing to know - and it
                // outranks a state card that will happily read "standby",
                // because from Klipper's point of view nothing is wrong now.
                if let outage = alerts.unacknowledgedOutage {
                    OutageCard(record: outage) {
                        Task { await alerts.acknowledge(outage) }
                    }
                }

                PrinterStateCard(snapshot: snapshot, printerName: settings.printerName)

                // Anything that needs attention, worst first. Empty when the
                // printer is fine, so stale warnings clear themselves.
                ConditionList()

                // What the telemetry says, which the camera and Klipper both
                // miss: a clog forming as a slow drift in layer time, the
                // extruder slipping, a heater losing its grip. Placed here
                // because a clog is only actionable while the print is still
                // running - on a settings page it would be a post-mortem.
                AnomalyList()

                PowerCard(
                    power: printer.power,
                    safety: printer.powerOffSafety,
                    isBusy: printer.isBusy,
                    onPowerOn: { Task { await printer.powerOn() } },
                    onPowerOff: {
                        if printer.powerOffSafety.isSafe {
                            Task { await printer.powerOff(force: false) }
                        } else {
                            showingPowerOffWarning = true
                        }
                    }
                )

                if snapshot.isActive || snapshot.state == .complete {
                    PrintProgressCard(snapshot: snapshot, thumbnailURL: thumbnailURL)
                }

                TemperaturesCard(snapshot: snapshot)
                QuickActionsCard(
                    snapshot: snapshot,
                    isBusy: printer.isBusy,
                    onHome: { Task { await printer.home() } },
                    onPreheat: { showingPreheatSheet = true },
                    onCooldown: { Task { await printer.cooldown() } },
                    onPause: { Task { await printer.pausePrint() } },
                    onResume: { Task { await printer.resumePrint() } },
                    onCancel: { Task { await printer.cancelPrint() } }
                )

                // Both of these appear only when the printer's own config says
                // they can: a light section for one, an installed EJECT_PART
                // macro for the other.
                LightsCard()
                EjectPartCard()

                MachineStateCard(snapshot: snapshot)
                CameraPreviewCard()
                ConnectionCard(
                    moonrakerConnected: printer.moonrakerConnected,
                    backendConnected: printer.backendConnected,
                    health: printer.backendHealth,
                    host: settings.host
                )

                EmergencyStopButton {
                    Task { await printer.emergencyStop() }
                }
                .padding(.top, 4)
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("tab.home"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    NavigationLink(destination: SystemInfoView()) {
                        Label(L.t("system.title"), systemImage: "cpu")
                    }
                    NavigationLink(destination: HistoryView()) {
                        Label(L.t("history.title"), systemImage: "clock.arrow.circlepath")
                    }
                    NavigationLink(destination: TerminalView()) {
                        Label(L.t("terminal.title"), systemImage: "terminal")
                    }
                    Divider()
                    Button {
                        showingSettings = true
                    } label: {
                        Label(L.t("settings.title"), systemImage: "gearshape")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .refreshable {
            await printer.refreshNow()
            await printer.refreshPower()
            await printer.refreshBackendHealth()
        }
        .task {
            await printer.refreshBackendHealth()
        }
        .sheet(isPresented: $showingPreheatSheet) {
            PreheatSheet()
                .presentationDetents([.medium, .large])
        }
        .confirmationDialog(
            L.t("power.off.unsafe.title"),
            isPresented: $showingPowerOffWarning,
            titleVisibility: .visible
        ) {
            Button(L.t("power.off.force"), role: .destructive) {
                Task { await printer.powerOff(force: true) }
            }
            Button(L.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(printer.powerOffSafety.blockers.joined(separator: "\n\n"))
        }
    }

    private var thumbnailURL: URL? {
        guard let path = files.gcodes.first(where: { $0.filename == snapshot.filename })?.thumbnailPath
        else { return nil }
        return printer.thumbnailURL(for: path)
    }

    private var demoBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
            Text(localized: "demo.banner")
                .font(.subheadline.weight(.medium))
            Spacer()
            Button(L.t("demo.disable")) { settings.demoMode = false }
                .font(.caption.weight(.semibold))
        }
        .padding(12)
        .background(Theme.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
    }

}

// MARK: - Printer state card

struct PrinterStateCard: View {
    let snapshot: PrinterSnapshot
    let printerName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(printerName)
                        .font(.title3.weight(.bold))
                    Text(localized: snapshot.klippy.localizationKey)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(
                    text: L.t(snapshot.isOnline ? "status.online" : "status.offline"),
                    color: snapshot.isOnline ? Theme.printing : Theme.danger,
                    pulsing: snapshot.isOnline
                )
            }

            HStack(spacing: 12) {
                Image(systemName: snapshot.state.symbolName)
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.color(for: snapshot.state))
                    .frame(width: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(localized: snapshot.state.localizationKey)
                        .font(.headline)
                        .foregroundStyle(Theme.color(for: snapshot.state))
                    if !snapshot.filename.isEmpty {
                        Text(snapshot.filename)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else if !snapshot.stateMessage.isEmpty {
                        Text(snapshot.stateMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
            }

            // Conditions are rendered as their own cards below, so this one no
            // longer repeats the message - that repetition was how a single
            // Klipper state ended up described two or three times on screen.
        }
        .card(tint: Theme.color(for: snapshot.state))
    }
}

// MARK: - Power card

struct PowerCard: View {
    let power: PowerReading
    let safety: PowerSafetyReport
    let isBusy: Bool
    let onPowerOn: () -> Void
    let onPowerOff: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionHeader("power.title", systemImage: "bolt.fill")
                StatusPill(
                    text: L.t(power.state.localizationKey),
                    color: Theme.color(for: power.state)
                )
            }

            if !power.available, !power.message.isEmpty {
                Text(power.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                BigActionButton(
                    titleKey: "power.on",
                    systemImage: "power",
                    tint: Theme.printing,
                    isEnabled: power.available && power.state != .on,
                    isLoading: isBusy,
                    action: onPowerOn
                )
                BigActionButton(
                    titleKey: "power.off",
                    systemImage: "power.circle",
                    tint: Theme.danger,
                    isDestructive: true,
                    isEnabled: power.available && power.state != .off,
                    isLoading: isBusy,
                    action: onPowerOff
                )
            }

            if !safety.isSafe {
                Label(safety.blockers.first ?? "", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.paused)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
    }
}

// MARK: - Print progress

struct PrintProgressCard: View {
    let snapshot: PrinterSnapshot
    let thumbnailURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("print.progress", systemImage: "chart.pie.fill")

            HStack(spacing: 16) {
                ProgressRing(
                    progress: snapshot.progress,
                    tint: Theme.color(for: snapshot.state),
                    caption: layerCaption
                )
                .frame(width: 108, height: 108)

                VStack(alignment: .leading, spacing: 10) {
                    if let thumbnailURL {
                        AsyncImage(url: thumbnailURL) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFit()
                            default:
                                Image(systemName: "photo")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(height: 56)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    InfoRow(titleKey: "print.elapsed", value: Format.clock(snapshot.printDuration))
                    InfoRow(
                        titleKey: "print.remaining",
                        value: snapshot.estimatedTimeLeft == nil
                            ? L.t("print.remaining.unknown")
                            : Format.duration(snapshot.estimatedTimeLeft)
                    )
                    // Where the number came from. It legitimately changes
                    // during a print - the slicer's figure early, this print's
                    // measured rate late - and a number whose basis is stated
                    // is one the user can calibrate their own trust against.
                    if let method = snapshot.estimateMethodText {
                        Text(method)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let finish = snapshot.estimatedFinishDate {
                        InfoRow(titleKey: "print.eta", value: finish.formatted(date: .omitted, time: .shortened))
                    }
                    InfoRow(titleKey: "print.filament_used", value: Format.meters(snapshot.filamentUsedMM / 1000))
                }
            }
        }
        .card(tint: Theme.color(for: snapshot.state))
    }

    private var layerCaption: String? {
        guard let current = snapshot.currentLayer else { return nil }
        if let total = snapshot.totalLayer, total > 0 {
            return "\(current) / \(total)"
        }
        return "\(current)"
    }
}

// MARK: - Temperatures

struct TemperaturesCard: View {
    let snapshot: PrinterSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader("temperature.title", systemImage: "thermometer.medium")
            HStack(alignment: .top, spacing: 20) {
                TemperatureBadge(
                    titleKey: "temperature.nozzle",
                    actual: snapshot.nozzleActual,
                    target: snapshot.nozzleTarget,
                    tint: Theme.nozzle,
                    systemImage: "flame.fill"
                )
                TemperatureBadge(
                    titleKey: "temperature.bed",
                    actual: snapshot.bedActual,
                    target: snapshot.bedTarget,
                    tint: Theme.bed,
                    systemImage: "square.stack.3d.down.right.fill"
                )
            }
        }
        .card()
    }
}

// MARK: - Quick actions

struct QuickActionsCard: View {
    let snapshot: PrinterSnapshot
    let isBusy: Bool
    let onHome: () -> Void
    let onPreheat: () -> Void
    let onCooldown: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void

    @State private var confirmingCancel = false

    private let columns = [GridItem(.adaptive(minimum: 86), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("home.quick_actions", systemImage: "bolt.horizontal.fill")

            LazyVGrid(columns: columns, spacing: 10) {
                BigActionButton(
                    titleKey: "action.home_all",
                    systemImage: "house",
                    isEnabled: snapshot.isReady && !snapshot.isActive,
                    action: onHome
                )
                BigActionButton(
                    titleKey: "action.preheat",
                    systemImage: "flame",
                    tint: Theme.nozzle,
                    isEnabled: snapshot.isReady,
                    action: onPreheat
                )
                BigActionButton(
                    titleKey: "action.cooldown",
                    systemImage: "snowflake",
                    tint: Theme.bed,
                    isEnabled: snapshot.isReady,
                    action: onCooldown
                )

                if snapshot.state == .printing {
                    BigActionButton(
                        titleKey: "action.pause",
                        systemImage: "pause.fill",
                        tint: Theme.paused,
                        isEnabled: !isBusy,
                        action: onPause
                    )
                } else if snapshot.state == .paused {
                    BigActionButton(
                        titleKey: "action.resume",
                        systemImage: "play.fill",
                        tint: Theme.printing,
                        isEnabled: !isBusy,
                        action: onResume
                    )
                }

                if snapshot.isActive {
                    BigActionButton(
                        titleKey: "action.cancel_print",
                        systemImage: "stop.fill",
                        isDestructive: true,
                        isEnabled: !isBusy
                    ) {
                        confirmingCancel = true
                    }
                }
            }
        }
        .card()
        .confirmationDialog(
            L.t("action.cancel_print.confirm"),
            isPresented: $confirmingCancel,
            titleVisibility: .visible
        ) {
            Button(L.t("action.cancel_print"), role: .destructive, action: onCancel)
            Button(L.t("common.cancel"), role: .cancel) {}
        }
    }
}

// MARK: - Machine state

struct MachineStateCard: View {
    let snapshot: PrinterSnapshot

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("home.machine", systemImage: "gearshape.2.fill")

            LazyVGrid(columns: columns, spacing: 14) {
                StatTile(
                    titleKey: "machine.x",
                    value: Format.coordinate(snapshot.x),
                    systemImage: "arrow.left.and.right",
                    tint: snapshot.isHomed("x") ? Theme.printing : Theme.idle
                )
                StatTile(
                    titleKey: "machine.y",
                    value: Format.coordinate(snapshot.y),
                    systemImage: "arrow.up.and.down",
                    tint: snapshot.isHomed("y") ? Theme.printing : Theme.idle
                )
                StatTile(
                    titleKey: "machine.z",
                    value: Format.coordinate(snapshot.z),
                    systemImage: "arrow.up.to.line",
                    tint: snapshot.isHomed("z") ? Theme.printing : Theme.idle
                )
                StatTile(
                    titleKey: "machine.speed",
                    value: Format.speed(snapshot.speed),
                    systemImage: "speedometer"
                )
                StatTile(
                    titleKey: "machine.speed_factor",
                    value: Format.percent(snapshot.speedFactor),
                    systemImage: "gauge.with.dots.needle.67percent"
                )
                StatTile(
                    titleKey: "machine.flow",
                    value: Format.percent(snapshot.extrudeFactor),
                    systemImage: "drop.fill"
                )
                StatTile(
                    titleKey: "machine.fan",
                    value: Format.percent(snapshot.fanSpeed),
                    systemImage: "fanblades.fill"
                )
                StatTile(
                    titleKey: "machine.layer",
                    value: layerText,
                    systemImage: "square.3.layers.3d"
                )
                StatTile(
                    titleKey: "machine.homed",
                    value: snapshot.homedAxes.isEmpty ? "--" : snapshot.homedAxes.uppercased(),
                    systemImage: "house.fill",
                    tint: snapshot.hasHomedAll ? Theme.printing : Theme.paused
                )
            }
        }
        .card()
    }

    private var layerText: String {
        guard let current = snapshot.currentLayer else { return "--" }
        if let total = snapshot.totalLayer, total > 0 { return "\(current)/\(total)" }
        return "\(current)"
    }
}

// MARK: - Connection card

struct ConnectionCard: View {
    let moonrakerConnected: Bool
    let backendConnected: Bool
    let health: BackendHealth?
    let host: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("home.connection", systemImage: "network")
            InfoRow(titleKey: "settings.host", value: host)
            InfoRow(
                titleKey: "diagnostics.websocket",
                value: L.t(moonrakerConnected ? "status.connected" : "status.disconnected"),
                tint: moonrakerConnected ? Theme.printing : Theme.danger
            )
            InfoRow(
                titleKey: "diagnostics.backend",
                value: L.t(backendConnected ? "status.connected" : "status.disconnected"),
                tint: backendConnected ? Theme.printing : Theme.paused
            )
            if let health {
                InfoRow(titleKey: "diagnostics.power_provider", value: health.powerProvider)
                InfoRow(
                    titleKey: "diagnostics.slicer",
                    value: health.slicerAvailable ? health.slicerEngine : L.t("slicer.not_installed"),
                    tint: health.slicerAvailable ? Theme.printing : Theme.paused
                )
            }
            NavigationLink(destination: NetworkDiagnosticsView()) {
                Label(L.t("diagnostics.title"), systemImage: "stethoscope")
                    .font(.subheadline)
            }
            .padding(.top, 2)
        }
        .card()
    }
}
