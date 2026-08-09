import SwiftUI

struct GCodeDetailView: View {
    let file: BackendGCodeFile

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var printer: PrinterStore
    @EnvironmentObject private var files: FilesStore
    @Environment(\.dismiss) private var dismiss

    @State private var metadata: MoonrakerFile?
    @State private var shareURL: URL?
    @State private var showingShare = false
    @State private var showingChecklist = false
    @State private var showingDeleteConfirm = false
    @State private var isWorking = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                // Printing and deleting go through FilesStore, so its error has
                // to be visible here or the action fails with no sign of it.
                if let error = files.lastError {
                    ErrorBanner(
                        message: error.localizedDescription,
                        onDismiss: { files.lastError = nil }
                    )
                }
                thumbnailCard
                detailsCard
                actionsCard
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .background(Theme.pageFill)
        .navigationTitle(file.filename)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            metadata = await files.metadata(for: file)
        }
        .sheet(isPresented: $showingShare) {
            if let shareURL { ShareSheet(items: [shareURL]) }
        }
        .sheet(isPresented: $showingChecklist) {
            PrintChecklistView {
                Task {
                    await files.startPrint(file)
                    showingChecklist = false
                    dismiss()
                }
            }
            .presentationDetents([.medium])
        }
        .confirmationDialog(
            L.t("files.delete.confirm"),
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(L.t("common.delete"), role: .destructive) {
                Task {
                    await files.delete(file)
                    dismiss()
                }
            }
            Button(L.t("common.cancel"), role: .cancel) {}
        }
    }

    private var thumbnailURL: URL? {
        guard let path = file.thumbnailPath ?? metadata?.thumbnailPath else { return nil }
        return printer.thumbnailURL(for: path)
    }

    private var thumbnailCard: some View {
        ZStack {
            if let thumbnailURL {
                AsyncImage(url: thumbnailURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    case .failure:
                        placeholder
                    default:
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 200)
            } else {
                placeholder.frame(height: 160)
            }
        }
        .card()
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 40))
                .foregroundStyle(Theme.accent.opacity(0.6))
            Text(localized: "files.no_thumbnail")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("files.details", systemImage: "info.circle")
            InfoRow(titleKey: "files.name", value: file.filename)
            InfoRow(titleKey: "files.size", value: Format.fileSize(file.size))
            InfoRow(titleKey: "files.modified", value: Format.date(file.modified))
            InfoRow(titleKey: "files.estimated_time", value: Format.duration(file.estimatedTime))
            if let grams = file.filamentWeightG {
                InfoRow(titleKey: "files.filament_weight", value: Format.grams(grams))
            }
            if let mm = file.filamentTotalMM {
                InfoRow(titleKey: "files.filament_length", value: Format.meters(mm / 1000))
            }
            if let height = file.layerHeight {
                InfoRow(titleKey: "files.layer_height", value: String(format: "%.2f mm", height))
            }
            if let first = file.firstLayerHeight {
                InfoRow(titleKey: "files.first_layer_height", value: String(format: "%.2f mm", first))
            }
            if let objectHeight = file.objectHeight {
                InfoRow(titleKey: "files.object_height", value: String(format: "%.1f mm", objectHeight))
            }
            if let type = file.filamentType {
                InfoRow(titleKey: "files.filament_type", value: type)
            }
            if let name = file.filamentName {
                InfoRow(titleKey: "files.filament_name", value: name)
            }
            if let slicer = file.slicer {
                InfoRow(titleKey: "files.slicer", value: slicer)
            }
            if let layers = file.layerCount {
                InfoRow(titleKey: "files.layers", value: "\(layers)")
            }
            InfoRow(titleKey: "files.source", value: file.source)
        }
        .card()
    }

    private var actionsCard: some View {
        VStack(spacing: 12) {
            Button {
                if settings.requirePrintChecklist {
                    showingChecklist = true
                } else {
                    Task {
                        await files.startPrint(file)
                        dismiss()
                    }
                }
            } label: {
                Label(L.t("files.print"), systemImage: "printer.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(printer.snapshot.isActive)

            // The automated counterpart to the manual checklist: it reads the
            // actual G-code and reports what is wrong with it. It existed,
            // worked, and had no way in until the reachability check found it.
            NavigationLink {
                PreflightView(filename: file.path) {
                    Task {
                        await files.startPrint(file)
                        dismiss()
                    }
                }
            } label: {
                Label(L.t("preflight.open"), systemImage: "checklist.checked")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(printer.snapshot.isActive)

            Button {
                Task {
                    isWorking = true
                    shareURL = await files.download(file)
                    isWorking = false
                    showingShare = shareURL != nil
                }
            } label: {
                HStack {
                    if isWorking { ProgressView().controlSize(.small) }
                    Label(L.t("files.share"), systemImage: "square.and.arrow.up")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button(role: .destructive) {
                showingDeleteConfirm = true
            } label: {
                Label(L.t("common.delete"), systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .card()
    }
}
