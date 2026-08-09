import SwiftUI

/// One place for every guided procedure, so nobody has to remember a command.
struct CalibrationHubView: View {
    @EnvironmentObject private var doctor: DoctorStore
    @EnvironmentObject private var printer: PrinterStore

    @State private var started: String?

    private static let order = [
        "full_bed_calibration", "z_offset", "screws_tilt",
        "bed_mesh", "axis_health", "input_shaper", "safe_home"
    ]

    private var options: [WorkflowOption] {
        let known = doctor.workflowOptions
        return Self.order.compactMap { kind in known.first { $0.kind == kind } }
            + known.filter { !Self.order.contains($0.kind) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                if let run = doctor.workflow, !run.finished {
                    resumeCard(run)
                }

                ForEach(options) { option in
                    Button {
                        Task {
                            if await doctor.startWorkflow(option.kind) {
                                started = option.kind
                            }
                        }
                    } label: {
                        card(option)
                    }
                    .buttonStyle(.plain)
                    .disabled(doctor.workflow.map { !$0.finished } ?? false)
                }

                if options.isEmpty {
                    ProgressView().padding(.vertical, 60)
                }

                // Everything above is about the bed. These are about what the
                // plastic looks like - flow, pressure advance, temperature -
                // which nothing in this app measured before.
                NavigationLink {
                    CalibrationPrintsView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "ruler")
                            .foregroundStyle(Theme.accent)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(localized: "calibration.prints.title")
                                .font(.subheadline.weight(.medium))
                            Text(localized: "calibration.prints.subtitle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.forward").font(.caption).foregroundStyle(.secondary)
                    }
                    .card()
                }
                .buttonStyle(.plain)
            }
            .padding(Theme.spacing)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("calibration.title"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $started) { kind in
            WorkflowView(kind: kind)
        }
        .task { await doctor.loadWorkflows() }
    }

    private func resumeCard(_ run: WorkflowRun) -> some View {
        NavigationLink {
            WorkflowView(kind: run.kind)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: DoctorCatalog.icon(forWorkflow: run.kind))
                    .foregroundStyle(run.color)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(localized: "calibration.in_progress")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(run.title)
                        .font(.subheadline.weight(.medium))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward").font(.caption).foregroundStyle(.secondary)
            }
            .card(tint: run.color)
        }
        .buttonStyle(.plain)
    }

    private func card(_ option: WorkflowOption) -> some View {
        HStack(spacing: 14) {
            Image(systemName: option.icon)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(localized: option.titleKey)
                    .font(.subheadline.weight(.semibold))
                Text(localized: option.descriptionKey)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward").font(.caption).foregroundStyle(.secondary)
        }
        .card()
    }
}

// MARK: - printer.cfg versions

/// Backup, name, compare and roll back printer.cfg.
struct ConfigVersionsView: View {
    @EnvironmentObject private var doctor: DoctorStore

    @State private var renaming: ConfigVersion?
    @State private var newLabel = ""
    @State private var diffTarget: ConfigVersion?
    @State private var diff: ConfigDiff?
    @State private var restoreTarget: ConfigVersion?
    @State private var restorePreview: ConfigRestoreResult?

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                if let error = doctor.lastError {
                    ErrorBanner(message: error.localizedDescription) {
                        doctor.lastError = nil
                    }
                }

                if let live = doctor.liveConfig {
                    liveCard(live)
                }

                snapshotButton

                if doctor.configVersions.isEmpty {
                    EmptyStateView(
                        titleKey: "config.versions.empty",
                        messageKey: "config.versions.empty.detail",
                        systemImage: "doc.on.doc"
                    )
                } else {
                    ForEach(doctor.configVersions) { version in
                        versionCard(version)
                    }
                }
            }
            .padding(Theme.spacing)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("config.versions.title"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await doctor.loadConfig() }
        .task { await doctor.loadConfig() }
        .alert(L.t("config.name_version"), isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField(L.t("config.name_placeholder"), text: $newLabel)
            Button(L.t("common.save")) {
                if let version = renaming {
                    Task { await doctor.rename(version, label: newLabel) }
                }
                renaming = nil
            }
            Button(L.t("common.cancel"), role: .cancel) { renaming = nil }
        }
        .sheet(item: $diffTarget) { version in
            NavigationStack {
                ConfigDiffView(version: version, diff: diff)
            }
        }
        .sheet(item: $restoreTarget) { version in
            NavigationStack {
                RestoreConfirmView(version: version, preview: restorePreview)
            }
        }
    }

    private func liveCard(_ live: LiveConfig) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("config.live", systemImage: "doc.text")

            HStack(spacing: 8) {
                Image(systemName: live.matchesKnownGood ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(live.matchesKnownGood ? Theme.printing : Theme.paused)
                Text(localized: live.matchesKnownGood ? "config.matches_known_good" : "config.differs_from_known_good")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }

            InfoRow(titleKey: "config.sections", value: "\(live.sections.count)")
            InfoRow(
                titleKey: "config.validation",
                value: L.t("config.verdict.\(live.validation.verdict)"),
                tint: live.validation.ok ? Theme.printing : Theme.danger
            )

            ForEach(live.validation.findings.prefix(6)) { finding in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: finding.severity == "error" ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(finding.severity == "error" ? Theme.danger : Theme.paused)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(finding.message)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        if !finding.remedy.isEmpty {
                            Text(finding.remedy)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .card(tint: live.validation.ok ? .clear : Theme.danger)
    }

    private var snapshotButton: some View {
        HStack(spacing: 10) {
            Button {
                Task { await doctor.snapshotConfig(label: "") }
            } label: {
                Label(L.t("config.snapshot"), systemImage: "camera")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                Task {
                    restorePreview = await doctor.previewRestore(nil)
                    restoreTarget = doctor.goldenConfig
                }
            } label: {
                Label(L.t("config.restore_known_good"), systemImage: "arrow.uturn.backward")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(doctor.goldenConfig == nil)
        }
    }

    private func versionCard(_ version: ConfigVersion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if version.golden {
                    Image(systemName: "seal.fill").foregroundStyle(Theme.paused)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(version.displayName)
                        .font(.subheadline.weight(.medium))
                    Text("\(Format.date(version.createdAt)) · \(L.t(version.reasonKey))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if version.provenPrints > 0 {
                    StatusPill(
                        text: L.t("config.proven", version.provenPrints),
                        color: Theme.printing,
                        systemImage: "checkmark"
                    )
                }
            }

            HStack(spacing: 14) {
                Button(L.t("config.rename")) {
                    newLabel = version.label
                    renaming = version
                }
                Button(L.t("config.compare")) {
                    Task {
                        diff = await doctor.diff(from: version)
                        diffTarget = version
                    }
                }
                if !version.golden {
                    Button(L.t("config.mark_golden")) {
                        Task { await doctor.markGolden(version) }
                    }
                }
                Spacer(minLength: 0)
                Button(L.t("config.restore")) {
                    Task {
                        restorePreview = await doctor.previewRestore(version)
                        restoreTarget = version
                    }
                }
                .foregroundStyle(Theme.accent)
            }
            .font(.caption.weight(.medium))
            .buttonStyle(.plain)
        }
        .card(tint: version.golden ? Theme.paused : .clear)
    }
}

/// Section-aware diff, so a reformatted config does not look like a rewrite.
struct ConfigDiffView: View {
    let version: ConfigVersion
    let diff: ConfigDiff?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                if let diff {
                    if diff.identical {
                        EmptyStateView(
                            titleKey: "config.diff.identical",
                            messageKey: "config.diff.identical.detail",
                            systemImage: "equal.circle"
                        )
                    } else {
                        if !diff.addedSections.isEmpty {
                            listCard("config.diff.added", diff.addedSections, tint: Theme.printing)
                        }
                        if !diff.removedSections.isEmpty {
                            listCard("config.diff.removed", diff.removedSections, tint: Theme.danger)
                        }
                        ForEach(diff.changedSections) { change in
                            changeCard(change, titleKey: "config.diff.changed")
                        }
                        if !diff.autosaveChanges.isEmpty {
                            Text(localized: "config.diff.autosave_note")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(diff.autosaveChanges) { change in
                                changeCard(change, titleKey: "config.diff.autosave")
                            }
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 60)
                }
            }
            .padding(Theme.spacing)
        }
        .background(Theme.pageFill)
        .navigationTitle(version.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L.t("common.close")) { dismiss() }
            }
        }
    }

    private func listCard(_ titleKey: String, _ names: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localized: titleKey)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            ForEach(names, id: \.self) { name in
                Text("[\(name)]")
                    .font(.system(.caption, design: .monospaced))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(tint: tint)
    }

    private func changeCard(_ change: ConfigSectionChange, titleKey: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("[\(change.section)]")
                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
            ForEach(change.options, id: \.option) { option in
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.option)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(option.before ?? "—")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.danger)
                        Image(systemName: "arrow.right").font(.system(size: 9))
                        Text(option.after ?? "—")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.printing)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .card()
    }
}

/// Restoring rewrites printer.cfg and restarts Klipper, so it is shown in full
/// and confirmed explicitly.
struct RestoreConfirmView: View {
    let version: ConfigVersion
    let preview: ConfigRestoreResult?

    @EnvironmentObject private var doctor: DoctorStore
    @Environment(\.dismiss) private var dismiss
    @State private var isRestoring = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(localized: "config.restore.explain")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(localized: "config.restore.backup_note")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .card(tint: Theme.paused)

                if let diff = preview?.diff {
                    if diff.identical {
                        Text(localized: "config.diff.identical")
                            .font(.subheadline)
                            .card()
                    } else {
                        Text(L.t("config.diff.count", diff.changeCount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(diff.changedSections) { change in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("[\(change.section)]")
                                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                                ForEach(change.options, id: \.option) { option in
                                    Text("\(option.option): \(option.before ?? "—") → \(option.after ?? "—")")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .card()
                        }
                    }
                }

                Button {
                    Task {
                        isRestoring = true
                        if await doctor.confirmRestore(version) { dismiss() }
                        isRestoring = false
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isRestoring {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        Text(localized: "config.restore.confirm")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Theme.danger, in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(isRestoring)
            }
            .padding(Theme.spacing)
        }
        .background(Theme.pageFill)
        .navigationTitle(version.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L.t("common.cancel")) { dismiss() }
            }
        }
    }
}
