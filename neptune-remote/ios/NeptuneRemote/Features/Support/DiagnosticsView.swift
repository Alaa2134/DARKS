import SwiftUI

/// One-tap system check with a shareable, secret-free report.
struct DiagnosticsView: View {
    @EnvironmentObject private var support: SupportStore

    @State private var shareItems: [Any] = []
    @State private var showingShare = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                if let report = support.diagnostics {
                    overall(report)
                    ForEach(report.checks) { check in
                        checkRow(check)
                    }
                    shareCard
                } else if support.isRunningDiagnostics {
                    ProgressView().padding(.vertical, 60)
                } else {
                    EmptyStateView(
                        titleKey: "diagnostics.title",
                        messageKey: "diagnostics.redacted",
                        systemImage: "checklist",
                        actionTitleKey: "diagnostics.run"
                    ) {
                        Task { await support.runDiagnostics() }
                    }
                }
            }
            .padding(Theme.spacing)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("diagnostics.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await support.runDiagnostics() }
                } label: {
                    if support.isRunningDiagnostics {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .sheet(isPresented: $showingShare) {
            ShareSheet(items: shareItems)
        }
        .task { await support.runDiagnostics() }
    }

    private func overall(_ report: DiagnosticsReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: symbol(report.overall))
                    .font(.title2)
                    .foregroundStyle(color(report.overall))
                VStack(alignment: .leading, spacing: 2) {
                    Text(localized: "diagnostics.overall.\(report.overall)")
                        .font(.headline)
                    Text(Format.date(report.generatedAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if !report.summaryAR.isEmpty {
                Text(report.summaryAR)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card(tint: color(report.overall))
    }

    private func checkRow(_ check: DiagnosticCheck) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: check.symbol)
                .foregroundStyle(check.color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(check.displayName)
                    .font(.subheadline.weight(.medium))
                if !check.detail.isEmpty {
                    Text(check.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !check.hintKey.isEmpty, check.status != "ok" {
                    Text(localized: check.hintKey)
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .card()
    }

    private var shareCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localized: "diagnostics.redacted")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                Task {
                    guard let text = await support.diagnosticsText() else { return }
                    shareItems = [text]
                    showingShare = true
                }
            } label: {
                Label(L.t("diagnostics.share"), systemImage: "square.and.arrow.up")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
        }
        .card()
    }

    private func symbol(_ overall: String) -> String {
        switch overall {
        case "ok": return "checkmark.seal.fill"
        case "warning": return "exclamationmark.triangle.fill"
        default: return "xmark.seal.fill"
        }
    }

    private func color(_ overall: String) -> Color {
        switch overall {
        case "ok": return Theme.printing
        case "warning": return Theme.paused
        default: return Theme.danger
        }
    }
}

// MARK: - Bed mesh

/// Heat map of the saved bed mesh, plus the verdict in plain language.
struct BedMeshView: View {
    @EnvironmentObject private var support: SupportStore
    @EnvironmentObject private var printer: PrinterStore

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                if let mesh = support.bedMesh, mesh.available, let matrix = mesh.matrix, !matrix.isEmpty {
                    heatMap(matrix, mesh: mesh)
                    stats(mesh)
                } else {
                    EmptyStateView(
                        titleKey: "bedmesh.none",
                        messageKey: support.bedMesh?.messageKey ?? "bedmesh.title",
                        systemImage: "grid"
                    )
                }

                Button {
                    Task { await support.calibrateBedMesh() }
                } label: {
                    HStack(spacing: 8) {
                        if support.isBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "scope")
                        }
                        Text(localized: "bedmesh.calibrate")
                    }
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(printer.snapshot.isPrinting || support.isBusy)

                if printer.snapshot.isPrinting {
                    Label(L.t("bedmesh.blocked.printing"), systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(Theme.spacing)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("bedmesh.title"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await support.loadBedMesh() }
        .task { await support.loadBedMesh() }
    }

    private func heatMap(_ matrix: [[Double]], mesh: BedMeshReport) -> some View {
        let lowest = mesh.lowest ?? matrix.flatMap { $0 }.min() ?? 0
        let highest = mesh.highest ?? matrix.flatMap { $0 }.max() ?? 0
        let span = max(highest - lowest, 0.0001)

        return VStack(spacing: 3) {
            // Row 0 is the front of the bed; draw it at the bottom.
            ForEach(Array(matrix.enumerated().reversed()), id: \.offset) { _, row in
                HStack(spacing: 3) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                        let ratio = (value - lowest) / span
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(meshColor(ratio))
                            .aspectRatio(1, contentMode: .fit)
                            .overlay {
                                Text(String(format: "%.2f", value))
                                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                                    .foregroundStyle(.white)
                                    .minimumScaleFactor(0.5)
                            }
                    }
                }
            }
        }
        .card()
    }

    private func meshColor(_ ratio: Double) -> Color {
        // Blue (low) -> green (level) -> orange (high).
        let clamped = min(max(ratio, 0), 1)
        if clamped < 0.5 {
            return Theme.bed.opacity(0.55 + (0.5 - clamped) * 0.9)
        }
        return Theme.nozzle.opacity(0.45 + (clamped - 0.5) * 1.1)
    }

    private func stats(_ mesh: BedMeshReport) -> some View {
        VStack(spacing: 10) {
            if let name = mesh.profileName {
                InfoRow(titleKey: "library.detail.name_en", value: name)
            }
            if let range = mesh.range {
                InfoRow(titleKey: "bedmesh.range", value: String(format: "%.3f mm", range))
            }
            if let key = mesh.verdictKey {
                Text(localized: key)
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .card()
    }
}

// MARK: - Backups

struct BackupsView: View {
    @EnvironmentObject private var support: SupportStore

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(localized: "backup.redacted")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Task { await support.createBackup() }
                    } label: {
                        HStack(spacing: 8) {
                            if support.isBusy {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "plus")
                            }
                            Text(localized: "backup.create")
                        }
                        .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .disabled(support.isBusy)
                }
                .card()

                if support.backups.isEmpty {
                    EmptyStateView(
                        titleKey: "backup.empty",
                        messageKey: "backup.redacted",
                        systemImage: "archivebox"
                    )
                } else {
                    ForEach(support.backups) { backup in
                        backupCard(backup)
                    }
                }
            }
            .padding(Theme.spacing)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("backup.title"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await support.loadBackups() }
        .task { await support.loadBackups() }
    }

    private func backupCard(_ backup: BackupInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(backup.filename)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(Format.date(backup.createdAt)) · \(Format.fileSize(backup.sizeBytes))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(role: .destructive) {
                    Task { await support.deleteBackup(backup) }
                } label: {
                    Image(systemName: "trash").font(.caption).foregroundStyle(Theme.danger)
                }
                .buttonStyle(.plain)
            }

            if !backup.contents.isEmpty {
                Text("\(L.t("backup.contents")): \(backup.contents.joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
    }
}
