import SwiftUI
import UniformTypeIdentifiers

/// "What do you want to print?" - browse, search and add models.
struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    @State private var showingImporter = false
    @State private var showingIdeas = false
    @State private var isImporting = false
    @FocusState private var searchFocused: Bool

    private let columns = [
        GridItem(.adaptive(minimum: 150), spacing: Theme.spacing)
    ]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.spacing) {
                searchField

                if let error = library.lastError {
                    ErrorBanner(message: error.localizedDescription) {
                        Task { await library.load(force: true) }
                    } onDismiss: {
                        library.lastError = nil
                    }
                }

                if isImporting {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(localized: "library.import.uploading")
                            .font(.subheadline)
                    }
                    .card()
                }

                // What the last import attempt actually did, step by step.
                // Shown because every previous failure was invisible from the
                // outside - one screenshot of this says which step broke.
                if !library.importTrace.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(localized: "library.import.trace")
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Button(L.t("common.close")) { library.clearImportTrace() }
                                .font(.caption)
                        }
                        ForEach(library.importTrace, id: \.self) { line in
                            Text(line)
                                .font(.caption2)
                                .monospaced()
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .card()
                }

                if library.query.isEmpty {
                    browse
                } else {
                    searchResults
                }
            }
            .padding(Theme.spacing)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("library.title"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            // Import gets its own button, deliberately NOT inside the menu.
            //
            // A .fileImporter presented from a Menu button races the menu's own
            // dismissal: the picker appears, but its completion handler never
            // fires, so choosing a file and tapping Open does nothing at all.
            // That is the "I select the file and nothing happens" this screen
            // had - FilesView and SliceView present from plain buttons and have
            // always worked.
            //
            // Do not move this back into the Menu.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingImporter = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L.t("library.import"))
            }

            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showingIdeas = true
                    } label: {
                        Label(L.t("ideas.title"), systemImage: "lightbulb")
                    }
                    Toggle(L.t("library.filter.favourites"), isOn: $library.favouritesOnly)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingIdeas) {
            NavigationStack { IdeaFinderView().withLibraryDestinations() }
        }
        // A UIKit picker in a sheet, not .fileImporter. The importer's
        // completion is bound to this view, and this view is rebuilt every few
        // seconds by the printer status refresh - when that happened while the
        // picker was open, the callback was lost and tapping Open did nothing
        // at all, with no error anywhere. DocumentPicker keeps the delegate on
        // a coordinator that UIKit retains, so a redraw cannot detach it.
        .sheet(isPresented: $showingImporter) {
            DocumentPicker(
                contentTypes: LibraryView.modelTypes,
                onPick: { urls in
                    showingImporter = false
                    handleImport(.success(urls))
                },
                onCancel: { showingImporter = false }
            )
            .ignoresSafeArea()
        }
        .refreshable { await library.load(force: true) }
        .task { await library.load() }
    }

    /// STL / 3MF / OBJ - matching what the backend's mesh parser supports.
    ///
    /// The identifiers come from the `UTImportedTypeDeclarations` in
    /// Info.plist. Without those declarations `UTType(filenameExtension: "stl")`
    /// hands back a *dynamic* type, which never matches the type the Files app
    /// assigns to a real file, and every .stl in the picker is greyed out.
    ///
    /// `.data` stays last as a catch-all so a file arriving from a provider that
    /// reports no useful type at all is still selectable.
    static let modelTypes: [UTType] = ModelFileTypes.pickerTypes

    // MARK: - Search field

    private var searchField: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(L.t("search.placeholder"), text: $library.query)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .onSubmit { library.commitSearch() }
                    .autocorrectionDisabled()
                if library.isSearching {
                    ProgressView().controlSize(.mini)
                } else if !library.query.isEmpty {
                    Button {
                        library.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))

            if library.query.isEmpty, !library.recentSearches.isEmpty {
                recentSearches
            }
        }
    }

    private var recentSearches: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(library.recentSearches, id: \.self) { term in
                    Button {
                        library.query = term
                    } label: {
                        Text(term)
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Theme.cardFill, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Button(L.t("search.clear_recent")) {
                    library.clearRecentSearches()
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Browse

    @ViewBuilder
    private var browse: some View {
        if library.isLoading, library.items.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 60)
        } else if library.items.isEmpty {
            EmptyStateView(
                titleKey: "library.empty",
                messageKey: "library.empty.hint",
                systemImage: "cube.transparent",
                actionTitleKey: "library.import"
            ) {
                showingImporter = true
            }
        } else {
            categoryChips

            if !library.favourites.isEmpty, library.selectedCategory == nil {
                shelf(titleKey: "library.section.favourites", icon: "star.fill", items: library.favourites)
            }
            if !library.recentlyPrinted.isEmpty, library.selectedCategory == nil {
                shelf(titleKey: "library.section.recent", icon: "clock.arrow.circlepath", items: Array(library.recentlyPrinted.prefix(10)))
            }

            SectionHeader("library.section.all", systemImage: "square.grid.2x2")
                .padding(.top, 4)
            LazyVGrid(columns: columns, spacing: Theme.spacing) {
                ForEach(library.browseItems) { item in
                    NavigationLink(value: item.id) {
                        LibraryCard(item: item, imageURL: library.mediaURL(item.thumbnail)) {
                            Task { await library.toggleFavourite(item) }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(titleKey: "library.filter.all", icon: "square.grid.2x2", selected: library.selectedCategory == nil) {
                    library.selectedCategory = nil
                }
                ForEach(library.categories) { category in
                    chip(
                        title: category.displayName,
                        icon: category.icon.isEmpty ? LibraryCategoryCatalog.icon(for: category.id) : category.icon,
                        selected: library.selectedCategory == category.id
                    ) {
                        library.selectedCategory = library.selectedCategory == category.id ? nil : category.id
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func chip(
        titleKey: String? = nil,
        title: String = "",
        icon: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption)
                Text(titleKey.map { L.t($0) } ?? title)
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(selected ? Theme.accent : Theme.cardFill, in: Capsule())
            .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private func shelf(titleKey: String, icon: String, items: [LibraryItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(titleKey, systemImage: icon)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.spacing) {
                    ForEach(items) { item in
                        NavigationLink(value: item.id) {
                            LibraryCard(item: item, imageURL: library.mediaURL(item.thumbnail))
                                .frame(width: 150)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var searchResults: some View {
        if !library.suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(localized: "search.suggestions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(library.suggestions, id: \.self) { suggestion in
                            Button {
                                library.query = suggestion
                            } label: {
                                Text(suggestion)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(Theme.accent.opacity(0.14), in: Capsule())
                                    .foregroundStyle(Theme.accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }

        if library.results.isEmpty, !library.isSearching {
            EmptyStateView(
                titleKey: "search.no_results",
                messageKey: "search.no_results.hint",
                systemImage: "magnifyingglass"
            )
        } else {
            Text(L.t("search.results", library.results.count))
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: columns, spacing: Theme.spacing) {
                ForEach(library.results) { entry in
                    NavigationLink(value: entry.item.id) {
                        VStack(alignment: .leading, spacing: 6) {
                            LibraryCard(item: entry.item, imageURL: library.mediaURL(entry.item.thumbnail))
                            if let reasonKey = entry.primaryReasonKey {
                                Text(localized: reasonKey)
                                    .font(.caption2)
                                    .foregroundStyle(Theme.accent)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Import

    private func handleImport(_ result: Result<[URL], Error>) {
        // Logged before anything else: if this line never appears, the picker's
        // callback did not fire at all, which is a different problem from a
        // read or an upload failing.
        library.clearImportTrace()

        switch result {
        case .failure(let error):
            library.trace("picker FAILED: \(error.localizedDescription)")
            library.lastError = .unknown(error.localizedDescription)
            return
        case .success(let urls):
            library.trace("picker returned \(urls.count) file(s)")
            guard !urls.isEmpty else { return }

            Task {
                isImporting = true
                defer { isImporting = false }
                for url in urls {
                    await library.importModel(url: url)
                }
            }
        }
    }
}
