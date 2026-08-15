import SwiftUI
import UniformTypeIdentifiers

struct FilesView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var printer: PrinterStore
    @EnvironmentObject private var files: FilesStore
    @EnvironmentObject private var history: HistoryStore

    @State private var section: Section = .gcode
    @State private var search = ""
    @State private var showingImporter = false
    @State private var shareURL: URL?
    @State private var showingShare = false
    @State private var pendingPrint: BackendGCodeFile?
    @State private var showingChecklist = false

    enum Section: String, CaseIterable, Identifiable {
        case gcode, models, recent
        var id: String { rawValue }
        var titleKey: String { "files.section.\(rawValue)" }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $section) {
                ForEach(Section.allCases) { item in
                    Text(localized: item.titleKey).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            content
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("tab.files"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: L.t("files.search"))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { AppMenu() }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingImporter = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .task { await reload() }
        .refreshable { await reload() }
        // Same picker as the other two screens, for the same reason: this view
        // is rebuilt on every status refresh, and .fileImporter loses its
        // callback when that happens while the picker is open.
        .sheet(isPresented: $showingImporter) {
            DocumentPicker(
                contentTypes: importTypes,
                allowsMultipleSelection: false,
                onPick: { urls in
                    showingImporter = false
                    guard let url = urls.first else { return }
                    Task {
                        let ext = url.pathExtension.lowercased()
                        if ["gcode", "gco", "g"].contains(ext) {
                            _ = await files.upload(gcodeURL: url)
                            await files.loadGCodes()
                        } else {
                            _ = await files.upload(modelURL: url)
                        }
                    }
                },
                onCancel: { showingImporter = false }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showingShare) {
            if let shareURL { ShareSheet(items: [shareURL]) }
        }
        .sheet(isPresented: $showingChecklist) {
            PrintChecklistView {
                if let file = pendingPrint {
                    Task {
                        await files.startPrint(file)
                        showingChecklist = false
                        // A refusal leaves `files.lastError` set, and the list
                        // behind this sheet is already showing it.
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    private var importTypes: [UTType] { ModelFileTypes.allPickerTypes }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .gcode: gcodeList
        case .models: modelList
        case .recent: recentList
        }
    }

    private func reload() async {
        switch section {
        case .gcode: await files.loadGCodes()
        case .models: await files.loadModels()
        case .recent: await history.load()
        }
    }

    // MARK: - G-code

    private var filteredGCodes: [BackendGCodeFile] {
        guard !search.isEmpty else { return files.gcodes }
        return files.gcodes.filter { $0.filename.localizedCaseInsensitiveContains(search) }
    }

    private var gcodeList: some View {
        List {
            if let error = files.lastError {
                ErrorBanner(
                    message: error.localizedDescription,
                    onRetry: { Task { await files.loadGCodes() } },
                    onDismiss: { files.lastError = nil }
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            if files.isLoadingGCodes && files.gcodes.isEmpty {
                // Rows the size of the rows that are coming, rather than a
                // spinner in an empty space that says nothing about either.
                SkeletonList(rows: 4)
                    .transition(.opacity)
                    .listRowBackground(Color.clear)
            } else if filteredGCodes.isEmpty {
                EmptyStateView(
                    titleKey: "files.empty.title",
                    messageKey: "files.empty.message",
                    systemImage: "doc.text"
                )
                .listRowBackground(Color.clear)
            }

            ForEach(filteredGCodes) { file in
                NavigationLink {
                    GCodeDetailView(file: file)
                } label: {
                    GCodeRow(file: file, thumbnailURL: thumbnailURL(for: file))
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        Task { await files.delete(file) }
                    } label: {
                        Label(L.t("common.delete"), systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading) {
                    Button {
                        requestPrint(file)
                    } label: {
                        Label(L.t("files.print"), systemImage: "printer.fill")
                    }
                    .tint(Theme.printing)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func thumbnailURL(for file: BackendGCodeFile) -> URL? {
        guard let path = file.thumbnailPath else { return nil }
        return printer.thumbnailURL(for: path)
    }

    private func requestPrint(_ file: BackendGCodeFile) {
        pendingPrint = file
        if settings.requirePrintChecklist {
            showingChecklist = true
        } else {
            Task { await files.startPrint(file) }
        }
    }

    // MARK: - Models

    private var filteredModels: [BackendModelFile] {
        guard !search.isEmpty else { return files.models }
        return files.models.filter { $0.filename.localizedCaseInsensitiveContains(search) }
    }

    private var modelList: some View {
        List {
            if filteredModels.isEmpty && !files.isLoadingModels {
                EmptyStateView(
                    titleKey: "files.models.empty.title",
                    messageKey: "files.models.empty.message",
                    systemImage: "cube"
                )
                .listRowBackground(Color.clear)
            }
            ForEach(filteredModels) { model in
                HStack(spacing: 12) {
                    Image(systemName: "cube.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.accent)
                        .frame(width: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.filename)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(Format.fileSize(model.size)) · \(Format.relativeDate(model.modified))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .swipeActions {
                    Button(role: .destructive) {
                        Task { await files.deleteModel(model) }
                    } label: {
                        Label(L.t("common.delete"), systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Recent prints

    private var recentList: some View {
        List {
            if history.entries.isEmpty && !history.isLoading {
                EmptyStateView(
                    titleKey: "history.empty.title",
                    messageKey: "history.empty.message",
                    systemImage: "clock.arrow.circlepath"
                )
                .listRowBackground(Color.clear)
            }
            ForEach(history.entries) { entry in
                HistoryRow(entry: entry)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Rows

struct GCodeRow: View {
    let file: BackendGCodeFile
    let thumbnailURL: URL?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.accent.opacity(0.12))
                if let thumbnailURL {
                    AsyncImage(url: thumbnailURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFit().padding(2)
                        default:
                            Image(systemName: "doc.text")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                } else {
                    Image(systemName: "doc.text")
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text(file.filename)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    if let time = file.estimatedTime {
                        Label(Format.duration(time), systemImage: "clock")
                    }
                    if let grams = file.filamentWeightG {
                        Label(Format.grams(grams), systemImage: "scalemass")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Text(Format.fileSize(file.size))
                    if let type = file.filamentType { Text(type) }
                    if let height = file.layerHeight {
                        Text(String(format: "%.2f mm", height))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry

    private var resultColor: Color {
        switch entry.result {
        case "completed": return Theme.printing
        case "cancelled": return Theme.paused
        case "error", "interrupted": return Theme.danger
        default: return Theme.idle
        }
    }

    /// "interrupted" is a print the backend closed on startup after finding it
    /// still marked in progress - the power went out and nothing ever wrote a
    /// finish event. A bolt reads better than a generic failure cross.
    private var resultIcon: String {
        switch entry.result {
        case "completed": return "checkmark.seal.fill"
        case "interrupted": return "bolt.slash.fill"
        default: return "xmark.seal.fill"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: resultIcon)
                .foregroundStyle(resultColor)
                .font(.title3)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.filename)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    Text(Format.date(entry.startTime))
                    if let duration = entry.duration {
                        Label(Format.duration(duration), systemImage: "clock")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(localized: "history.result.\(entry.result)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(resultColor)
        }
    }
}
