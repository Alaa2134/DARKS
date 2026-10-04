import SwiftUI

/// The G-code Inspector: what a sliced file actually asks the printer to do.
///
/// It reads and reports. There is no "fix this file" button anywhere in this
/// screen, because the app never rewrites a toolpath.
struct GCodeInspectorView: View {
    let filename: String

    @EnvironmentObject private var doctor: DoctorStore

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                if doctor.isInspecting, doctor.lastInspection == nil {
                    ProgressView().padding(.vertical, 60)
                } else if let report = doctor.lastInspection {
                    verdictCard(report)
                    provenanceCard(report)
                    geometryCard(report)
                    motionCard(report)
                    if !report.unsupported.isEmpty { unsupportedCard(report) }
                    if !report.issues.isEmpty { issuesCard(report) }
                    Text(localized: "gcode.never_modified")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    EmptyStateView(
                        titleKey: "gcode.inspector.title",
                        messageKey: "gcode.inspector.empty",
                        systemImage: "doc.text.magnifyingglass"
                    )
                }
            }
            .padding(Theme.spacing)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("gcode.inspector.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await doctor.inspect(filename: filename) }
    }

    private func verdictCard(_ report: GCodeReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: report.verdict == "safe" ? "checkmark.seal.fill"
                      : report.verdict == "warning" ? "exclamationmark.triangle.fill"
                      : "xmark.octagon.fill")
                    .font(.title2)
                    .foregroundStyle(report.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(localized: report.verdictKey)
                        .font(.headline)
                    Text(filename)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            if report.errorCount > 0 || report.warningCount > 0 {
                Text(L.t("gcode.issue_counts", report.errorCount, report.warningCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .card(tint: report.color)
    }

    private func provenanceCard(_ report: GCodeReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("gcode.provenance", systemImage: "signature")
            InfoRow(titleKey: "gcode.slicer", value: report.slicer.isEmpty ? "—" : report.slicer)
            if !report.slicerVersion.isEmpty {
                InfoRow(titleKey: "gcode.version", value: report.slicerVersion)
            }
            InfoRow(
                titleKey: "gcode.profile",
                value: report.profileName.isEmpty ? "—" : report.profileName
            )
            InfoRow(
                titleKey: "gcode.profile_status",
                value: L.t(report.profileStatusKey),
                tint: report.isVerified ? Theme.printing : Theme.paused
            )
            if !report.isVerified {
                Label(L.t("gcode.unverified_warning"), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Theme.paused)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
    }

    private func geometryCard(_ report: GCodeReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("gcode.geometry", systemImage: "cube")
            InfoRow(titleKey: "gcode.bounds", value: report.bounds.description)
            if let height = report.layerHeight {
                InfoRow(titleKey: "gcode.layer_height", value: String(format: "%.2f mm", height))
            }
            if let nozzle = report.nozzleDiameter {
                InfoRow(titleKey: "gcode.nozzle", value: String(format: "%.2f mm", nozzle))
            }
            if let seconds = report.estimatedSeconds {
                InfoRow(titleKey: "gcode.estimated_time", value: Format.duration(seconds))
            }
            InfoRow(titleKey: "gcode.lines", value: "\(report.linesScanned)")
        }
        .card()
    }

    private func motionCard(_ report: GCodeReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("gcode.motion", systemImage: "speedometer")
            if let feed = report.maxRequestedFeedrate {
                InfoRow(
                    titleKey: "gcode.max_speed",
                    value: String(format: "%.0f mm/s", feed / 60.0)
                )
            }
            if let accel = report.maxRequestedAccel {
                InfoRow(titleKey: "gcode.max_accel", value: String(format: "%.0f mm/s²", accel))
            }
            InfoRow(
                titleKey: "gcode.positioning",
                value: L.t(report.positioningAbsolute == true ? "gcode.absolute" : "gcode.relative")
            )
            InfoRow(
                titleKey: "gcode.extrusion",
                value: L.t(report.extrusionRelative == true ? "gcode.relative" : "gcode.absolute")
            )
            InfoRow(
                titleKey: "gcode.homes",
                value: L.t(report.hasHome ? "common.on" : "common.off"),
                tint: report.hasHome ? Theme.printing : Theme.danger
            )
        }
        .card()
    }

    private func unsupportedCard(_ report: GCodeReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("gcode.unsupported", systemImage: "exclamationmark.triangle")
            ForEach(report.unsupported) { command in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(command.command)
                            .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        Spacer()
                        Text(L.t("gcode.line", command.line))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(command.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .card(tint: Theme.paused)
    }

    private func issuesCard(_ report: GCodeReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("gcode.issues", systemImage: "list.bullet.rectangle")
            ForEach(report.issues) { issue in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: issue.severity == "error" ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(issue.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.message)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        if !issue.detail.isEmpty {
                            Text(issue.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !issue.remedy.isEmpty {
                            Text(issue.remedy)
                                .font(.caption2)
                                .foregroundStyle(Theme.accent)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .card()
    }
}

// MARK: - Preflight

/// The pre-print check, shown before a print starts.
struct PreflightView: View {
    let filename: String
    var onProceed: (() -> Void)?

    @EnvironmentObject private var doctor: DoctorStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var report: PreflightReport?
    @State private var isRunning = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                if isRunning, report == nil {
                    ProgressView().padding(.vertical, 60)
                } else if let report {
                    verdictCard(report)
                    if let banner = report.banner { bannerCard(banner) }
                    checksCard(report)
                    actions(report)
                }
            }
            .padding(Theme.spacing)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("preflight.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L.t("common.cancel")) { dismiss() }
            }
        }
        .task { await run() }
    }

    private func run() async {
        isRunning = true
        report = await doctor.runPreflight(filename: filename)
        isRunning = false
    }

    private func verdictCard(_ report: PreflightReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: report.ready ? "checkmark.seal.fill"
                      : report.verdict == "warning" ? "exclamationmark.triangle.fill"
                      : "hand.raised.fill")
                    .font(.title2)
                    .foregroundStyle(report.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(localized: report.verdictKey)
                        .font(.headline)
                    Text(report.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if report.strict {
                Label(L.t("preflight.strict_on"), systemImage: "lock.shield")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .card(tint: report.color)
    }

    private func bannerCard(_ banner: PreflightBanner) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("preflight.summary", systemImage: "checklist")
            ForEach(banner.rows, id: \.labelKey) { row in
                HStack {
                    Text(localized: row.labelKey)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(row.value)
                        .font(.caption.weight(.semibold).monospaced())
                        .foregroundStyle(colour(for: row.value))
                        .multilineTextAlignment(.trailing)
                }
            }
            Text(banner.bounds)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .card()
    }

    private func colour(for value: String) -> Color {
        switch value {
        case "PASSED", "SAFE", "GOLDEN", "NONE": return Theme.printing
        case "WARNING", "KNOWN": return Theme.paused
        case "FAILED", "BLOCKED", "UNVERIFIED": return Theme.danger
        default: return .primary
        }
    }

    private func checksCard(_ report: PreflightReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("preflight.checks", systemImage: "list.bullet")
            ForEach(report.checks) { check in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: check.symbol)
                        .font(.caption)
                        .foregroundStyle(check.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(check.label)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        if !check.remedy.isEmpty {
                            Text(check.remedy)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .card()
    }

    @ViewBuilder
    private func actions(_ report: PreflightReport) -> some View {
        VStack(spacing: 10) {
            if report.verdict == "blocked" {
                Label(L.t("preflight.blocked_explain"), systemImage: "hand.raised.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button {
                    onProceed?()
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "printer.fill")
                        Text(localized: "preflight.start_print")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(report.color, in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }

            NavigationLink {
                GCodeInspectorView(filename: filename)
            } label: {
                Label(L.t("gcode.inspector.title"), systemImage: "doc.text.magnifyingglass")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)

            Toggle(isOn: Binding(
                get: { settings.strictSafetyMode },
                set: { value in
                    settings.strictSafetyMode = value
                    Task { await run() }
                }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(localized: "preflight.strict")
                        .font(.subheadline)
                    Text(localized: "preflight.strict.detail")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        }
    }
}
