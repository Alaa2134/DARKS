import SwiftUI

/// "Fix My Printer" - the guided diagnostic.
///
/// It inspects, explains and offers a fix. It never moves the printer on its
/// own: every fix is an explicit tap that starts a workflow.
struct FixMyPrinterView: View {
    @EnvironmentObject private var doctor: DoctorStore
    @EnvironmentObject private var printer: PrinterStore

    @State private var startedWorkflow: String?
    @State private var expanded: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                if let error = doctor.lastError {
                    ErrorBanner(message: error.localizedDescription) {
                        Task { await doctor.diagnose() }
                    } onDismiss: {
                        doctor.lastError = nil
                    }
                }

                verdictCard

                if doctor.isDiagnosing, doctor.diagnosis == nil {
                    ProgressView().padding(.vertical, 50)
                } else if let diagnosis = doctor.diagnosis {
                    if diagnosis.findings.isEmpty {
                        allClearCard
                    } else {
                        ForEach(diagnosis.findings) { finding in
                            findingCard(finding)
                        }
                    }
                    quickActions
                }
            }
            .padding(Theme.spacing)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("doctor.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await doctor.diagnose() }
                } label: {
                    if doctor.isDiagnosing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .navigationDestination(item: $startedWorkflow) { kind in
            WorkflowView(kind: kind)
        }
        .refreshable { await doctor.diagnose() }
        .task {
            if doctor.diagnosis == nil { await doctor.diagnose() }
        }
    }

    // MARK: - Verdict

    private var verdictCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill((doctor.diagnosis?.color ?? Theme.idle).opacity(0.16))
                        .frame(width: 58, height: 58)
                    Image(systemName: symbol)
                        .font(.title2)
                        .foregroundStyle(doctor.diagnosis?.color ?? Theme.idle)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(doctor.headline)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    if let checked = doctor.lastDiagnosedAt {
                        Text(L.t("doctor.checked", Format.relativeDate(checked.timeIntervalSince1970)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            if let diagnosis = doctor.diagnosis, !diagnosis.safeToPrint {
                Label(L.t("doctor.not_safe_to_print"), systemImage: "hand.raised.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.danger)
            }

            Text(localized: "doctor.read_only")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card(tint: doctor.diagnosis?.color ?? .clear)
    }

    private var symbol: String {
        switch doctor.diagnosis?.overall {
        case "green": return "checkmark.seal.fill"
        case "yellow": return "exclamationmark.triangle.fill"
        case "red": return "exclamationmark.octagon.fill"
        default: return "stethoscope"
        }
    }

    private var allClearCard: some View {
        EmptyStateView(
            titleKey: "doctor.all_clear",
            messageKey: "doctor.all_clear.detail",
            systemImage: "checkmark.seal"
        )
    }

    // MARK: - Findings

    private func findingCard(_ finding: DoctorFinding) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: finding.symbol)
                    .foregroundStyle(finding.color)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(finding.title)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Image(systemName: DoctorCatalog.icon(forSubsystem: finding.subsystem))
                            .font(.caption2)
                        Text(localized: "subsystem.\(finding.subsystem)")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if !finding.cause.isEmpty {
                labelled("doctor.likely_cause", finding.cause)
            }
            if !finding.recommendation.isEmpty {
                labelled("doctor.recommendation", finding.recommendation)
            }

            if !finding.manualSteps.isEmpty {
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expanded.contains(finding.id) },
                        set: { on in
                            if on { expanded.insert(finding.id) } else { expanded.remove(finding.id) }
                        }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(finding.manualSteps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(index + 1).")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(step)
                                    .font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Label(L.t("doctor.manual_steps"), systemImage: "hand.raised")
                        .font(.caption.weight(.medium))
                }
            }

            if let fix = finding.autoFix {
                fixButton(fix, label: finding.autoFixLabel)
            }
        }
        .card(tint: finding.color)
    }

    private func labelled(_ titleKey: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(localized: titleKey)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func fixButton(_ fix: String, label: String) -> some View {
        switch fix {
        case "firmware_restart":
            Button {
                Task { await printer.restartFirmware() }
            } label: {
                fixLabel(label.isEmpty ? L.t("doctor.fix.restart_firmware") : label, icon: "arrow.clockwise")
            }
            .buttonStyle(.plain)

        case "safe_home":
            workflowButton("safe_home", label: label, icon: "house")
        case "z_offset_wizard":
            workflowButton("z_offset", label: label, icon: "ruler")
        case "bed_mesh_wizard":
            workflowButton("bed_mesh", label: label, icon: "grid")

        case "config_diff":
            NavigationLink {
                ConfigVersionsView()
            } label: {
                fixLabel(label.isEmpty ? L.t("config.versions.title") : label, icon: "doc.text.magnifyingglass")
            }
            .buttonStyle(.plain)

        default:
            EmptyView()
        }
    }

    private func workflowButton(_ kind: String, label: String, icon: String) -> some View {
        Button {
            Task {
                if await doctor.startWorkflow(kind) {
                    startedWorkflow = kind
                }
            }
        } label: {
            fixLabel(label.isEmpty ? L.t("workflow.\(kind)") : label, icon: icon)
        }
        .buttonStyle(.plain)
    }

    private func fixLabel(_ text: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(text)
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward").font(.caption)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
        .foregroundStyle(Theme.accent)
    }

    // MARK: - Quick actions

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("doctor.next_steps", systemImage: "wrench.and.screwdriver")

            NavigationLink {
                PrinterHealthView()
            } label: {
                fixLabel(L.t("health.title"), icon: "heart.text.square")
            }
            .buttonStyle(.plain)

            NavigationLink {
                CalibrationHubView()
            } label: {
                fixLabel(L.t("calibration.title"), icon: "wand.and.stars")
            }
            .buttonStyle(.plain)

            NavigationLink {
                ConfigVersionsView()
            } label: {
                fixLabel(L.t("config.versions.title"), icon: "doc.on.doc")
            }
            .buttonStyle(.plain)
        }
        .card()
    }
}

// MARK: - Health page

/// One card per subsystem: green, yellow, red or unknown.
struct PrinterHealthView: View {
    @EnvironmentObject private var doctor: DoctorStore

    private let columns = [GridItem(.adaptive(minimum: 165), spacing: Theme.spacing)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                if doctor.healthCards.isEmpty, doctor.isDiagnosing {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 60)
                } else if doctor.healthCards.isEmpty {
                    EmptyStateView(
                        titleKey: "health.title",
                        messageKey: "doctor.not_checked",
                        systemImage: "heart.text.square",
                        actionTitleKey: "doctor.run_check"
                    ) {
                        Task { await doctor.diagnose() }
                    }
                } else {
                    LazyVGrid(columns: columns, spacing: Theme.spacing) {
                        ForEach(doctor.healthCards) { card in
                            healthCard(card)
                        }
                    }
                }
            }
            .padding(Theme.spacing)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("health.title"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await doctor.diagnose() }
        .task {
            if doctor.diagnosis == nil { await doctor.diagnose() }
        }
    }

    private func healthCard(_ card: HealthCard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: card.icon)
                    .font(.caption)
                    .foregroundStyle(card.color)
                Text(localized: card.nameKey)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: card.symbol)
                    .font(.caption)
                    .foregroundStyle(card.color)
            }

            Text(card.status)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !card.detail.isEmpty {
                Text(card.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if !card.recommendation.isEmpty {
                Text(card.recommendation)
                    .font(.caption2)
                    .foregroundStyle(card.color)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card(tint: card.health == "green" ? .clear : card.color, padding: 12)
    }
}
