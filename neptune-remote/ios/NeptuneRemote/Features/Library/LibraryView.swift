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
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showingImporter = true
                    } label: {
                        Label(L.t("library.import"), systemImage: "plus")
                    }
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
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: LibraryView.modelTypes,
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
        }
        .refreshable { await library.load(force: true) }
        .task { await library.load() }
    }

    /// STL / 3MF / OBJ - matching what the backend's mesh parser supports.
    static let modelTypes: [UTType] = {
        var types: [UTType] = [.data]
        for identifier in ["public.standard-tesselated-geometry-format", "org.3mf.3dmanufacturing", "public.geometry-definition-format"] {
            if let type = UTType(identifier) { types.insert(type, at: 0) }
        }
        for suffix in ["stl", "3mf", "obj"] {
            if let type = UTType(filenameExtension: suffix) { types.insert(type, at: 0) }
        }
        return types
    }()

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
        guard case .success(let urls) = result, !urls.isEmpty else {
            if case .failure(let error) = result {
                library.lastError = .unknown(error.localizedDescription)
            }
            return
        }
        Task {
            isImporting = true
            defer { isImporting = false }
            for url in urls {
                await library.importModel(url: url)
            }
        }
    }
}
