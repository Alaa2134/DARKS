import SwiftUI

/// Everything about one model, with the picture leading.
struct ModelDetailView: View {
    let itemID: String

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var inventory: InventoryStore
    @EnvironmentObject private var settings: AppSettings

    @State private var showingPrintSheet = false
    @State private var showingRename = false
    @State private var showingDeleteConfirm = false
    @State private var showing3D = false
    @State private var nameAR = ""
    @State private var nameEN = ""
    @State private var cost: CostBreakdown?

    private var item: LibraryItem? { library.item(id: itemID) }

    var body: some View {
        ScrollView {
            if let item {
                VStack(alignment: .leading, spacing: Theme.spacing) {
                    hero(item)
                    header(item)
                    printButton(item)
                    facts(item)
                    if let cost { costCard(cost, item: item) }
                    if !item.gcodes.isEmpty { gcodes(item) }
                    if !item.photos.isEmpty { photos(item) }
                    if !item.notes.isEmpty { notes(item) }
                    actions(item)
                }
                .padding(Theme.spacing)
            } else {
                ProgressView().padding(.vertical, 80)
            }
        }
        .background(Theme.pageFill)
        .navigationTitle(item?.displayName ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await library.refreshItem(id: itemID)
            if let item { cost = await inventory.costFor(item: item) }
        }
        .sheet(isPresented: $showingPrintSheet) {
            if let item {
                NavigationStack { OneTapPrintView(item: item) }
            }
        }
        .sheet(isPresented: $showing3D) {
            if let item {
                NavigationStack { LibraryModelViewer(item: item) }
            }
        }
        .alert(L.t("library.detail.rename"), isPresented: $showingRename) {
            TextField(L.t("library.detail.name_ar"), text: $nameAR)
            TextField(L.t("library.detail.name_en"), text: $nameEN)
            Button(L.t("common.save")) {
                guard let item else { return }
                Task { await library.rename(item, nameAR: nameAR, nameEN: nameEN) }
            }
            Button(L.t("common.cancel"), role: .cancel) {}
        }
        .confirmationDialog(
            L.t("library.detail.delete.confirm"),
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(L.t("common.delete"), role: .destructive) {
                guard let item else { return }
                Task { await library.delete(item) }
            }
            Button(L.t("common.cancel"), role: .cancel) {}
        }
    }

    // MARK: - Pieces

    private func hero(_ item: LibraryItem) -> some View {
        ModelImage(
            url: library.mediaURL(item.heroImage ?? item.thumbnail),
            name: item.displayName,
            category: item.category,
            cornerRadius: Theme.cornerRadius
        )
        .aspectRatio(4 / 3, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .onTapGesture { showing3D = true }
    }

    private func header(_ item: LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.displayName)
                        .font(.title2.weight(.semibold))
                    if !item.nameEN.isEmpty, item.nameEN != item.displayName {
                        Text(item.nameEN)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                Button {
                    Task { await library.toggleFavourite(item) }
                } label: {
                    Image(systemName: item.favourite ? "star.fill" : "star")
                        .font(.title3)
                        .foregroundStyle(item.favourite ? Theme.paused : .secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                StatusPill(
                    text: L.t("library.category.\(item.category)"),
                    color: Theme.accent,
                    systemImage: LibraryCategoryCatalog.icon(for: item.category)
                )
                if item.printCount > 0 {
                    StatusPill(
                        text: L.t("library.detail.prints", item.printCount),
                        color: Theme.printing,
                        systemImage: "printer.fill"
                    )
                } else {
                    StatusPill(
                        text: L.t("library.detail.never_printed"),
                        color: Theme.idle,
                        systemImage: "clock"
                    )
                }
            }

            if !item.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(item.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption2)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(Theme.cardFill, in: Capsule())
                        }
                    }
                }
            }
        }
        .card()
    }

    private func printButton(_ item: LibraryItem) -> some View {
        Button {
            showingPrintSheet = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "printer.fill")
                Text(localized: "print.setup.start")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private func facts(_ item: LibraryItem) -> some View {
        VStack(spacing: 10) {
            if let dimensions = item.dimensionsDescription {
                InfoRow(titleKey: "library.detail.dimensions", value: dimensions)
            }
            if let triangles = item.triangleCount {
                InfoRow(titleKey: "library.detail.triangles", value: "\(triangles)")
            }
            InfoRow(titleKey: "library.detail.material", value: item.recommendedMaterial)
            if let seconds = item.estimatedSeconds {
                InfoRow(titleKey: "library.detail.estimate", value: Format.duration(seconds))
            }
            if let grams = item.estimatedFilamentGrams {
                InfoRow(titleKey: "filament.material", value: Format.grams(grams))
            }
            InfoRow(titleKey: "files.size", value: Format.fileSize(item.modelSize))
        }
        .card()
    }

    private func costCard(_ breakdown: CostBreakdown, item: LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("cost.title", systemImage: "banknote")
            InfoRow(
                titleKey: "cost.per_unit",
                value: Format.money(breakdown.costPerUnit, currency: breakdown.currency)
            )
            InfoRow(
                titleKey: "cost.suggested",
                value: Format.money(breakdown.suggestedPricePerUnit, currency: breakdown.currency),
                tint: Theme.printing
            )
            NavigationLink {
                CostView(prefill: item)
            } label: {
                Text(localized: "home.action.details")
                    .font(.caption.weight(.medium))
            }
        }
        .card()
    }

    private func gcodes(_ item: LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("library.detail.gcode_preview", systemImage: "doc.text")
            ForEach(item.gcodes) { gcode in
                VStack(alignment: .leading, spacing: 2) {
                    Text(gcode.filename)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text(gcode.profileSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .card()
    }

    private func photos(_ item: LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("library.detail.photos", systemImage: "photo.on.rectangle")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(item.photos) { photo in
                        ModelImage(
                            url: library.mediaURL(photo.path),
                            name: photo.caption,
                            category: item.category,
                            showsPlaceholderLabel: false
                        )
                        .frame(width: 120, height: 120)
                    }
                }
            }
        }
        .card()
    }

    private func notes(_ item: LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("library.detail.notes", systemImage: "note.text")
            Text(item.notes)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .card()
    }

    private func actions(_ item: LibraryItem) -> some View {
        VStack(spacing: 10) {
            Button {
                nameAR = item.nameAR
                nameEN = item.nameEN
                showingRename = true
            } label: {
                Label(L.t("library.detail.rename"), systemImage: "pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            Button {
                showing3D = true
            } label: {
                Label(L.t("library.detail.3d_view"), systemImage: "rotate.3d")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            Button {
                Task { await library.regenerateThumbnail(item) }
            } label: {
                Label(L.t("library.detail.regenerate"), systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            Button(role: .destructive) {
                showingDeleteConfirm = true
            } label: {
                Label(L.t("library.detail.delete"), systemImage: "trash")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(Theme.danger)
            }
        }
        .font(.subheadline)
        .card()
    }
}

/// Loads the model file from the Pi and shows it in the existing 3D viewer.
struct LibraryModelViewer: View {
    let item: LibraryItem

    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var mesh: LoadedMesh?
    @State private var isLoading = true
    @State private var failure: String?

    var body: some View {
        Group {
            if let mesh {
                ModelViewer3D(mesh: mesh)
            } else if isLoading {
                ProgressView()
            } else {
                EmptyStateView(
                    titleKey: "library.detail.3d_view",
                    messageKey: "slicer.preview.unavailable",
                    systemImage: "cube.transparent"
                )
            }
        }
        .navigationTitle(item.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L.t("common.close")) { dismiss() }
            }
        }
        .task {
            defer { isLoading = false }
            guard let data = await library.modelData(item) else { return }
            mesh = try? MeshLoader.load(data: data, filename: item.modelFilename)
        }
    }
}
