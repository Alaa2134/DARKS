import SwiftUI

/// The five states the printer can be in, from the user's point of view.
/// Simple Mode shows exactly one of them at a time with one obvious action.
enum PrinterPhase: String {
    case off, starting, ready, printing, complete, error

    var localizationKey: String { "home.state.\(rawValue)" }
    var hintKey: String { "home.state.\(rawValue).hint" }

    var color: Color {
        switch self {
        case .off: return Theme.idle
        case .starting: return Theme.paused
        case .ready: return Theme.accent
        case .printing: return Theme.printing
        case .complete: return Theme.printing
        case .error: return Theme.danger
        }
    }

    /// The colour the hero glows with. Ready is the brand's own tide rather
    /// than the accent, because on deep water the accent's light-mode shade
    /// would be too dark to glow.
    var heroColor: Color {
        self == .ready ? Theme.tide : color
    }

    var systemImage: String {
        switch self {
        case .off: return "power"
        case .starting: return "hourglass"
        case .ready: return "checkmark.circle.fill"
        case .printing: return "printer.fill"
        case .complete: return "party.popper.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    /// Only `off` and `starting` have hints that are always true; the others
    /// are contextual and handled by the view.
    var hasHint: Bool { self != .error }

    static func resolve(snapshot: PrinterSnapshot, power: PowerReading) -> PrinterPhase {
        if snapshot.state == .error || snapshot.klippy == .error { return .error }
        if power.state == .off { return .off }
        if !snapshot.isOnline || snapshot.klippy == .startup { return .starting }
        switch snapshot.state {
        case .printing: return .printing
        case .paused: return .printing
        case .complete: return .complete
        default: return snapshot.isReady ? .ready : .starting
        }
    }
}

/// Simple Mode home: one big state card, one obvious next step.
struct SimpleHomeView: View {
    @Binding var showingSettings: Bool

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var printer: PrinterStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var inventory: InventoryStore
    @EnvironmentObject private var media: MediaStore
    @EnvironmentObject private var doctor: DoctorStore

    @State private var showingPowerOffWarning = false
    @State private var showingIdeas = false

    private var snapshot: PrinterSnapshot { printer.snapshot }
    private var phase: PrinterPhase { PrinterPhase.resolve(snapshot: snapshot, power: printer.power) }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Theme.spacing) {
                if showsDemoBanner { demoBanner }

                // Replaces the old offline banner. That one could only say
                // "not connected"; this says which of the four steps between
                // opening the app and seeing the printer is the one stuck.
                StartupCard()
                stateCard
                // Classified Klipper conditions, each with its own remedy. An
                // unhomed axis appears here as a calm "needs Home" card rather
                // than as a red error.
                ConditionList()
                primaryAction
                attentionCards
                if phase == .printing { livePeek }
                shortcuts
                totals
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .background(Theme.pageFill)
        .navigationTitle(settings.printerName.isEmpty ? L.t("tab.home") : settings.printerName)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            // The same menu as every other screen. Simple Mode used to get a
            // shorter one of its own, which meant the two modes disagreed
            // about where things live - and a screen you found yesterday was
            // missing today.
            ToolbarItem(placement: .topBarTrailing) { AppMenu() }
        }
        .sheet(isPresented: $showingIdeas) {
            NavigationStack { IdeaFinderView().withLibraryDestinations() }
        }
        .refreshable {
            await printer.refreshNow()
            await printer.refreshPower()
            await printer.refreshSummary()
        }
        .task {
            await printer.refreshBackendHealth()
            await printer.refreshSummary()
            // Read-only, and cheap: it never moves the printer.
            if doctor.diagnosis == nil { await doctor.diagnose(deep: false) }
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

    // MARK: - State

    private var stateCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    StatusChip(
                        text: L.t(phase.localizationKey),
                        color: phase.heroColor,
                        pulsing: phase == .printing || phase == .ready
                    )
                    Text(settings.printerName.isEmpty ? "Neptune 3 Plus" : settings.printerName)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(hintText)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                // The machine itself while there is no print to show; the
                // print takes its place the moment there is one.
                if phase != .printing {
                    PrinterIllustration()
                        .frame(width: 118, height: 118)
                        .padding(.top, -6)
                } else {
                    PrintRise(
                        progress: snapshot.progress,
                        seed: snapshot.filename,
                        paused: snapshot.isPaused
                    )
                    .frame(width: 118, height: 118)
                    .padding(.top, -6)
                }
            }

            if phase == .printing {
                NavigationLink {
                    PrintingView()
                } label: {
                    printingSummary
                }
                .buttonStyle(.plain)
            }
        }
        .heroCard(glow: phase.heroColor)
    }

    private var hintText: String {
        switch phase {
        case .error:
            // The condition cards carry the detail and the remedy; the hint
            // line stays short rather than repeating a raw Klipper message.
            if let condition = printer.primaryCondition {
                return L.t(condition.titleKey)
            }
            return L.t("home.state.error")
        case .printing:
            // The model's own name when the library knows it; otherwise the
            // filename made readable. `trident_wave_vase.gcode` is a file;
            // "trident wave vase" is the thing on the bed.
            return printer.summary?.item?.displayName ?? Format.printName(snapshot.filename)
        default:
            return L.t(phase.hintKey)
        }
    }

    private var printingSummary: some View {
        HStack(spacing: 16) {
            ProgressRing(
                progress: snapshot.progress,
                lineWidth: 9,
                tint: Theme.tide,
                label: Format.percent(snapshot.progress)
            )
            .frame(width: 92, height: 92)

            VStack(alignment: .leading, spacing: 8) {
                if let layer = snapshot.currentLayer, let total = snapshot.totalLayer, total > 0 {
                    Label(L.t("printing.layer", layer, total), systemImage: "square.stack.3d.up.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                Label(
                    L.t("printing.remaining", Format.duration(snapshot.estimatedTimeLeft)),
                    systemImage: "clock"
                )
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.emberWarm)
                .monospacedDigit()
                if let finish = snapshot.estimatedFinishDate {
                    Label(finish.formatted(date: .omitted, time: .shortened), systemImage: "flag.checkered")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.5))
                .flipsForRightToLeftLayoutDirection(true)
        }
        .padding(14)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - Primary action

    @ViewBuilder
    private var primaryAction: some View {
        switch phase {
        case .off:
            bigButton(titleKey: "home.action.power_on", systemImage: "power", tint: Theme.printing) {
                Task { await printer.powerOn() }
            }
        case .starting:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(localized: "home.state.starting.hint")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .card()
        case .ready:
            VStack(spacing: 10) {
                NavigationLink {
                    LibraryView()
                } label: {
                    bigButtonLabel(titleKey: "home.action.choose_model", systemImage: "square.grid.2x2.fill", tint: Theme.accent)
                }
                .buttonStyle(.plain)

                Button {
                    showingIdeas = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                        Text(localized: "home.action.surprise")
                    }
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        case .printing:
            HStack(spacing: 10) {
                BigActionButton(
                    titleKey: snapshot.isPaused ? "action.resume" : "action.pause",
                    systemImage: snapshot.isPaused ? "play.fill" : "pause.fill",
                    tint: Theme.paused
                ) {
                    Task {
                        if snapshot.isPaused { await printer.resumePrint() } else { await printer.pausePrint() }
                    }
                }
                BigActionButton(titleKey: "action.cancel_print", systemImage: "stop.fill", isDestructive: true) {
                    Task { await printer.cancelPrint() }
                }
            }
        case .complete:
            VStack(spacing: 10) {
                NavigationLink {
                    QueueView()
                } label: {
                    bigButtonLabel(titleKey: "queue.title", systemImage: "list.number", tint: Theme.accent)
                }
                .buttonStyle(.plain)

                if printer.power.state == .on {
                    Button {
                        if printer.powerOffSafety.isSafe {
                            Task { await printer.powerOff(force: false) }
                        } else {
                            showingPowerOffWarning = true
                        }
                    } label: {
                        Label(L.t("power.off"), systemImage: "power")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        case .error:
            NavigationLink {
                SupportView()
            } label: {
                bigButtonLabel(titleKey: "support.title", systemImage: "questionmark.circle", tint: Theme.danger)
            }
            .buttonStyle(.plain)
        }
    }

    private func bigButton(
        titleKey: String, systemImage: String, tint: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            bigButtonLabel(titleKey: titleKey, systemImage: systemImage, tint: tint)
        }
        .buttonStyle(.plain)
        .disabled(printer.isBusy)
    }

    private func bigButtonLabel(titleKey: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
            Text(localized: titleKey)
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background {
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint, tint.opacity(0.78)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                }
        }
        .shadow(color: tint.opacity(0.35), radius: 14, x: 0, y: 6)
        .foregroundStyle(.white)
    }

    // MARK: - Things that need attention

    @ViewBuilder
    private var attentionCards: some View {
        // Anything the doctor found critical is the most important thing on
        // screen, ahead of a monitor alert or a maintenance reminder.
        if let finding = doctor.criticalFindings.first {
            NavigationLink {
                FixMyPrinterView()
            } label: {
                attentionRow(
                    icon: "stethoscope",
                    tint: Theme.danger,
                    title: finding.title,
                    subtitle: L.t("doctor.tap_to_fix")
                )
            }
            .buttonStyle(.plain)
        }

        if let event = media.unacknowledgedVisionEvents.first {
            NavigationLink {
                VisionView()
            } label: {
                attentionRow(
                    icon: "eye.trianglebadge.exclamationmark",
                    tint: Theme.paused,
                    title: L.t(event.localizationKey),
                    subtitle: L.t("vision.action.\(event.action.isEmpty ? "none" : event.action)")
                )
            }
            .buttonStyle(.plain)
        }

        if inventory.maintenance.dueCount > 0 {
            NavigationLink {
                MaintenanceView()
            } label: {
                attentionRow(
                    icon: "wrench.and.screwdriver.fill",
                    tint: Theme.paused,
                    title: L.t("maintenance.due"),
                    subtitle: L.t("notification.maintenance_due.body", inventory.maintenance.dueCount)
                )
            }
            .buttonStyle(.plain)
        }

        if let spool = inventory.lowSpools.first {
            NavigationLink {
                FilamentView()
            } label: {
                attentionRow(
                    icon: "circle.hexagongrid",
                    tint: spool.color,
                    title: L.t("filament.low"),
                    subtitle: "\(spool.displayName) · \(Format.grams(spool.remainingGrams))"
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func attentionRow(icon: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card(tint: tint)
    }

    // MARK: - Live peek + shortcuts

    @ViewBuilder
    private var livePeek: some View {
        if let url = media.streamURL, settings.cameraKind == .mjpeg {
            MJPEGView(url: url)
                .aspectRatio(4 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        }
    }

    private var shortcuts: some View {
        HStack(spacing: 10) {
            NavigationLink {
                LibraryView()
            } label: {
                shortcut(titleKey: "library.title", icon: "square.grid.2x2.fill")
            }
            .buttonStyle(.plain)

            NavigationLink {
                QueueView()
            } label: {
                shortcut(
                    titleKey: "queue.title",
                    icon: "list.number",
                    badge: inventory.queue.waiting.count
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                FixMyPrinterView()
            } label: {
                shortcut(
                    titleKey: "doctor.short_title",
                    icon: "stethoscope",
                    badge: doctor.criticalFindings.count
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                FilamentView()
            } label: {
                shortcut(titleKey: "filament.title", icon: "circle.hexagongrid")
            }
            .buttonStyle(.plain)
        }
    }

    private func shortcut(titleKey: String, icon: String, badge: Int = 0) -> some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .frame(height: 24)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(Theme.danger, in: Circle())
                        .offset(x: 10, y: -6)
                }
            }
            Text(localized: titleKey)
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
    }

    private var totals: some View {
        HStack(spacing: Theme.spacing) {
            StatTile(
                titleKey: "home.stats.prints",
                value: "\(printer.summary?.totals.totalPrints ?? 0)",
                systemImage: "printer"
            )
            StatTile(
                titleKey: "home.stats.hours",
                value: String(format: "%.0f", printer.summary?.totals.totalPrintHours ?? 0),
                systemImage: "clock"
            )
            StatTile(
                titleKey: "home.stats.filament",
                value: Format.grams(printer.summary?.totals.totalFilamentGrams ?? 0),
                systemImage: "scalemass"
            )
        }
        .card()
    }

    // MARK: - Banners

    /// The demo banner, except in screenshot mode: those pictures are of the
    /// interface, and the showcase that uses them says plainly that the data is
    /// the built-in demo. Everywhere a person can reach, demo mode says so.
    private var showsDemoBanner: Bool {
        #if DEBUG
        if Showcase.isActive { return false }
        #endif
        return settings.demoMode
    }

    private var demoBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "theatermasks.fill")
            Text(localized: "demo.banner").font(.subheadline)
            Spacer(minLength: 0)
            Button(L.t("demo.disable")) { settings.demoMode = false }
                .font(.caption.weight(.semibold))
        }
        .padding(12)
        .background(Theme.paused.opacity(0.15), in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
    }

}
