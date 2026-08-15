import SwiftUI

/// A project: several parts that were meant to be printed together.
///
/// The library was a list of single files. A thing you actually print is often
/// not one file - a box is a shell, a lid and four clips, and a ZIP from any
/// model site is exactly that. Until now those arrived as unrelated entries and
/// the only thing holding them together was that they happened to be imported
/// on the same day.
///
/// Deleting a project deletes the grouping and nothing else. The parts stay in
/// the library, because losing models to a tap meant for a folder is the one
/// mistake with no way back.
struct ProjectView: View {
    let projectID: String

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var slicing: SliceStore
    @EnvironmentObject private var placement: PlacementStore

    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmingDelete = false
    @State private var goToSlice = false

    private var project: LibraryCollection? { library.collection(id: projectID) }
    private var parts: [LibraryItem] { library.parts(of: projectID) }

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: Theme.spacing)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.spacing) {
                if library.isLoading && parts.isEmpty {
                    SkeletonGrid(tiles: 4)
                } else if parts.isEmpty {
                    emptyCard
                } else {
                    summaryCard
                    actionsCard
                    partsGrid
                }
            }
            .padding(Theme.spacing)
            .animation(.neptuneContent, value: parts)
        }
        .background(Theme.pageFill)
        .navigationTitle(project?.displayName ?? L.t("project.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        newName = project?.displayName ?? ""
                        renaming = true
                    } label: {
                        Label(L.t("project.rename"), systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label(L.t("project.delete"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert(L.t("project.rename"), isPresented: $renaming) {
            TextField(L.t("project.name"), text: $newName)
            Button(L.t("common.save")) {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task { await library.renameProject(projectID, to: name) }
            }
            Button(L.t("common.cancel"), role: .cancel) {}
        }
        // Spelled out rather than "are you sure": the parts staying is the
        // whole reason this is safe to tap.
        .confirmationDialog(
            L.t("project.delete.confirm"),
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button(L.t("project.delete"), role: .destructive) {
                Task { await library.deleteProject(projectID) }
            }
            Button(L.t("common.cancel"), role: .cancel) {}
        }
        .navigationDestination(isPresented: $goToSlice) { SliceView() }
        .task { await library.load() }
    }

    // MARK: - Cards

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("project.parts", systemImage: "shippingbox")
            HStack(spacing: 18) {
                StatTile(
                    titleKey: "project.part_count",
                    value: "\(parts.count)",
                    systemImage: "square.stack.3d.up"
                )
                if let tallest {
                    StatTile(
                        titleKey: "project.tallest",
                        value: String(format: "%.0f mm", tallest),
                        systemImage: "arrow.up.and.down"
                    )
                }
            }
        }
        .card()
    }

    /// The tallest part decides whether the whole plate clears the gantry, so
    /// it is the one number worth showing before slicing.
    private var tallest: Double? {
        parts.compactMap(\.dimensionsZ).max()
    }

    private var actionsCard: some View {
        VStack(spacing: 10) {
            Button {
                loadPlate()
                goToSlice = true
            } label: {
                Label(L.t("project.slice_all"), systemImage: "square.stack.3d.down.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            NavigationLink {
                PlateView(modelIDs: parts.map(\.id))
            } label: {
                Label(L.t("plate.title"), systemImage: "squareshape.split.2x2")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(parts.count < 2)

            Text(localized: "project.slice_all.note")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .card()
    }

    private var partsGrid: some View {
        LazyVGrid(columns: columns, spacing: Theme.spacing) {
            ForEach(parts) { item in
                NavigationLink(value: item.id) {
                    LibraryCard(item: item, imageURL: library.mediaURL(item.thumbnail))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) {
                        Task { await library.removeFromProject(item, project: projectID) }
                    } label: {
                        Label(L.t("project.remove_part"), systemImage: "minus.circle")
                    }
                }
            }
        }
    }

    private var emptyCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "shippingbox")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(localized: "project.empty")
                .font(.subheadline)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .card()
    }

    // MARK: - Work

    /// Put every part on one plate, ready to slice as a single job.
    ///
    /// One G-code, one heat-up, one purge - and one failure that takes all of
    /// them, which is why the plate screen exists next to this button.
    private func loadPlate() {
        let files = parts.map { item in
            BackendModelFile(
                id: item.id,
                filename: item.modelFilename,
                size: item.modelSize,
                modified: item.updatedAt,
                fileExtension: (item.modelFilename as NSString).pathExtension.lowercased()
            )
        }
        slicing.selectedModel = files.first
        slicing.plateModels = Array(files.dropFirst())
        // Positions already chosen on the plate screen travel with the slice.
        slicing.transforms = placement.platePayload(for: parts.map(\.id))
        Haptics.selection()
    }
}
