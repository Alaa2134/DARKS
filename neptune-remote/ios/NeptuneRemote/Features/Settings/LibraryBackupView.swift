import SwiftUI

/// Get the library off the SD card.
///
/// The library is the only thing on the Pi that cannot be recreated. Klipper's
/// config lives in a repository, the G-code can be re-sliced, the videos are
/// disposable - but the models, what they are called, which ones worked and
/// which profile printed them are years of accumulation on a consumer SD card.
/// Those fail.
///
/// The archive is written on the Pi, and then the important part: it can be
/// saved somewhere else. A backup that only exists on the card it protects is
/// not a backup.
struct LibraryBackupView: View {
    @EnvironmentObject private var printer: PrinterStore
    @EnvironmentObject private var settings: AppSettings

    @State private var backups: [BackupInfo] = []
    @State private var isLoading = false
    @State private var isCreating = false
    @State private var isRestoring = false
    @State private var lastResult: BackupResult?
    @State private var restoreResult: RestoreResult?
    @State private var error: APIError?

    @State private var restoring: BackupInfo?
    @State private var deleting: BackupInfo?
    @State private var exportURL: URL?
    @State private var isExporting = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                if let error {
                    ErrorBanner(
                        message: error.localizedDescription,
                        onDismiss: { self.error = nil }
                    )
                }

                explainer
                createCard

                if isLoading && backups.isEmpty {
                    SkeletonList(rows: 3, showsThumbnail: false)
                } else if backups.isEmpty {
                    EmptyStateView(
                        titleKey: "backup.empty.title",
                        messageKey: "backup.empty.message",
                        systemImage: "externaldrive.badge.timemachine"
                    )
                } else {
                    listCard
                }

                if let restoreResult { restoreResultCard(restoreResult) }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
            .animation(.neptuneContent, value: backups)
            .animation(.neptuneContent, value: restoreResult)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("backup.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog(
            L.t("backup.restore.confirm.title"),
            isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }),
            titleVisibility: .visible
        ) {
            if let target = restoring {
                Button(L.t("backup.restore.merge")) {
                    Task { await restore(target, keepExisting: true) }
                }
                Button(L.t("backup.restore.replace"), role: .destructive) {
                    Task { await restore(target, keepExisting: false) }
                }
            }
            Button(L.t("common.cancel"), role: .cancel) { restoring = nil }
        } message: {
            Text(localized: "backup.restore.confirm.message")
        }
        .confirmationDialog(
            L.t("backup.delete.confirm"),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            if let target = deleting {
                Button(L.t("common.delete"), role: .destructive) {
                    Task { await delete(target) }
                }
            }
            Button(L.t("common.cancel"), role: .cancel) { deleting = nil }
        }
        .sheet(isPresented: $isExporting) {
            if let exportURL { ShareSheet(items: [exportURL]) }
        }
    }

    // MARK: - What this is

    private var explainer: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("backup.title", systemImage: "externaldrive.badge.timemachine")
            Text(localized: "backup.explain")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(localized: "backup.excludes")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    private var createCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                Task { await create() }
            } label: {
                if isCreating {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(localized: "backup.creating")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Label(L.t("backup.create"), systemImage: "plus.circle")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isCreating || isRestoring)

            if let result = lastResult {
                Text(L.t(
                    "backup.created",
                    result.manifest.modelCount,
                    Format.fileSize(result.size)
                ))
                .font(.caption)
                .foregroundStyle(Theme.printing)
                .fixedSize(horizontal: false, vertical: true)

                if result.pruned > 0 {
                    Text(L.t("backup.pruned", result.pruned))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .card()
    }

    // MARK: - The archives

    private var listCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("backup.existing", systemImage: "clock.arrow.circlepath")
                .padding(.bottom, 10)

            ForEach(Array(backups.enumerated()), id: \.element.id) { index, backup in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Format.date(backup.createdAt))
                                .font(.subheadline.weight(.medium))
                            Text(Format.fileSize(backup.size))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 8) {
                        // First, and given the prominent treatment: saving the
                        // archive off the Pi is the only step that makes this a
                        // backup rather than a second copy on the same card.
                        Button {
                            Task { await export(backup) }
                        } label: {
                            Label(L.t("backup.save_elsewhere"), systemImage: "square.and.arrow.up")
                                .font(.caption)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button {
                            restoring = backup
                        } label: {
                            Label(L.t("backup.restore"), systemImage: "arrow.counterclockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isRestoring)

                        Spacer(minLength: 0)

                        Button(role: .destructive) {
                            deleting = backup
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel(L.t("common.delete"))
                    }
                }
                .padding(.vertical, 8)

                if index < backups.count - 1 { Divider() }
            }
        }
        .card()
    }

    private func restoreResultCard(_ result: RestoreResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L.t("backup.restored"), systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.printing)

            ForEach(result.notesAr, id: \.self) { note in
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if result.databaseRestored {
                Text(localized: "backup.restart_needed")
                    .font(.caption)
                    .foregroundStyle(Theme.paused)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
        .transition(.neptuneContent)
    }

    // MARK: - Work

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            backups = try await printer.backend.backups()
            error = nil
        } catch {
            self.error = APIError.from(error, host: settings.host)
        }
    }

    private func create() async {
        isCreating = true
        defer { isCreating = false }
        do {
            lastResult = try await printer.backend.createBackup()
            error = nil
            Haptics.success()
            await load()
        } catch {
            self.error = APIError.from(error, host: settings.host)
            Haptics.error()
        }
    }

    private func restore(_ backup: BackupInfo, keepExisting: Bool) async {
        restoring = nil
        isRestoring = true
        defer { isRestoring = false }
        do {
            restoreResult = try await printer.backend.restoreBackup(
                RestoreRequestPayload(filename: backup.filename, keepExisting: keepExisting)
            )
            error = nil
            Haptics.success()
        } catch {
            self.error = APIError.from(error, host: settings.host)
            Haptics.error()
        }
    }

    private func delete(_ backup: BackupInfo) async {
        deleting = nil
        do {
            try await printer.backend.deleteBackup(filename: backup.filename)
            await load()
        } catch {
            self.error = APIError.from(error, host: settings.host)
        }
    }

    /// Pull the archive down and hand it to the share sheet.
    ///
    /// This is the step that makes it a backup. Everything before it produces a
    /// second copy on the same card as the first.
    private func export(_ backup: BackupInfo) async {
        do {
            let data = try await printer.backend.downloadBackup(filename: backup.filename)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(backup.filename)
            try data.write(to: url, options: .atomic)
            exportURL = url
            isExporting = true
            Haptics.success()
        } catch {
            self.error = APIError.from(error, host: settings.host)
            Haptics.error()
        }
    }
}
