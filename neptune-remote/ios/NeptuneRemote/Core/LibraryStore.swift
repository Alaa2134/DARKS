import Combine
import Foundation
import SwiftUI

/// The model library: the heart of "choose something to print".
@MainActor
final class LibraryStore: ObservableObject {

    @Published private(set) var items: [LibraryItem] = []
    @Published private(set) var categories: [LibraryCategory] = []
    @Published private(set) var collections: [LibraryCollection] = []
    @Published private(set) var isLoading = false
    @Published var lastError: APIError?

    // Search
    @Published var query: String = ""
    @Published private(set) var results: [SearchResultEntry] = []
    @Published private(set) var suggestions: [String] = []
    @Published private(set) var isSearching = false
    @Published var recentSearches: [String] = []

    // Filters
    @Published var selectedCategory: String?
    @Published var favouritesOnly = false

    // Idea finder
    @Published private(set) var ideas: [LibraryItem] = []
    @Published private(set) var isLoadingIdeas = false

    /// Models staged by the Share Extension and not yet uploaded.
    @Published private(set) var pendingShareCount = 0

    private let settings: AppSettings
    private let printer: PrinterStore
    private var searchTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private static let recentSearchKey = "library.recentSearches"

    init(settings: AppSettings, printer: PrinterStore) {
        self.settings = settings
        self.printer = printer
        recentSearches = UserDefaults.standard.stringArray(forKey: Self.recentSearchKey) ?? []

        // Debounced live search as the user types.
        $query
            .removeDuplicates()
            .debounce(for: .milliseconds(280), scheduler: RunLoop.main)
            .sink { [weak self] text in
                Task { @MainActor in await self?.performSearch(text) }
            }
            .store(in: &cancellables)
    }

    // MARK: - Loading

    func load(force: Bool = false) async {
        guard force || items.isEmpty else { return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        if settings.demoMode {
            items = DemoLibrary.items
            categories = DemoLibrary.categories
            collections = DemoLibrary.collections
            return
        }

        do {
            async let itemsTask = printer.backend.libraryItems(limit: 500)
            async let categoriesTask = printer.backend.categories()
            async let collectionsTask = printer.backend.collections()
            items = try await itemsTask
            categories = try await categoriesTask
            collections = try await collectionsTask
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    func item(id: String) -> LibraryItem? {
        items.first { $0.id == id }
    }

    func refreshItem(id: String) async {
        guard !settings.demoMode else { return }
        guard let updated = try? await printer.backend.libraryItem(id: id) else { return }
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index] = updated
        } else {
            items.insert(updated, at: 0)
        }
    }

    // MARK: - Search

    func performSearch(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()

        guard !trimmed.isEmpty else {
            results = []
            suggestions = []
            return
        }

        isSearching = true
        defer { isSearching = false }

        if settings.demoMode {
            results = DemoLibrary.search(trimmed)
            suggestions = []
            return
        }

        do {
            let response = try await printer.backend.search(
                query: trimmed, category: selectedCategory, favouritesOnly: favouritesOnly
            )
            results = response.results
            suggestions = response.suggestions
            lastError = nil
        } catch {
            if case .cancelled = APIError.from(error) { return }
            lastError = APIError.from(error, host: settings.host)
        }
    }

    func commitSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var recents = recentSearches.filter { $0 != trimmed }
        recents.insert(trimmed, at: 0)
        recentSearches = Array(recents.prefix(12))
        UserDefaults.standard.set(recentSearches, forKey: Self.recentSearchKey)
    }

    func clearRecentSearches() {
        recentSearches = []
        UserDefaults.standard.removeObject(forKey: Self.recentSearchKey)
    }

    /// What the browse grid shows when there is no query.
    var browseItems: [LibraryItem] {
        var filtered = items
        if let selectedCategory {
            filtered = filtered.filter { $0.category == selectedCategory }
        }
        if favouritesOnly {
            filtered = filtered.filter(\.favourite)
        }
        return filtered
    }

    var favourites: [LibraryItem] { items.filter(\.favourite) }

    var recentlyPrinted: [LibraryItem] {
        items.filter { $0.lastPrinted != nil }
            .sorted { ($0.lastPrinted ?? 0) > ($1.lastPrinted ?? 0) }
    }

    var recentlyAdded: [LibraryItem] {
        items.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Ideas

    func loadIdeas(room: String?, maxSeconds: Double?, material: String?) async {
        isLoadingIdeas = true
        defer { isLoadingIdeas = false }

        if settings.demoMode {
            ideas = DemoLibrary.items.shuffled()
            return
        }
        do {
            ideas = try await printer.backend.ideas(
                room: room, maxSeconds: maxSeconds, material: material
            )
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    /// "فاجئني" - one deterministic pick, avoiding what was just printed.
    func surpriseMe() async -> LibraryItem? {
        await loadIdeas(room: nil, maxSeconds: nil, material: nil)
        return ideas.first
    }

    // MARK: - Mutations

    func toggleFavourite(_ item: LibraryItem) async {
        Haptics.impact(.light)
        guard !settings.demoMode else {
            return
        }
        do {
            let updated = try await printer.backend.updateLibraryItem(
                id: item.id, payload: LibraryItemUpdatePayload(favourite: !item.favourite)
            )
            replace(updated)
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    func rename(_ item: LibraryItem, nameAR: String, nameEN: String) async {
        guard !settings.demoMode else { return }
        do {
            let updated = try await printer.backend.updateLibraryItem(
                id: item.id,
                payload: LibraryItemUpdatePayload(nameAR: nameAR, nameEN: nameEN)
            )
            replace(updated)
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    func update(_ item: LibraryItem, payload: LibraryItemUpdatePayload) async {
        guard !settings.demoMode else { return }
        do {
            replace(try await printer.backend.updateLibraryItem(id: item.id, payload: payload))
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    func delete(_ item: LibraryItem) async {
        guard !settings.demoMode else {
            items.removeAll { $0.id == item.id }
            return
        }
        do {
            try await printer.backend.deleteLibraryItem(id: item.id)
            items.removeAll { $0.id == item.id }
            results.removeAll { $0.item.id == item.id }
            Haptics.success()
        } catch {
            lastError = APIError.from(error, host: settings.host)
            Haptics.error()
        }
    }

    // MARK: - Import trace
    //
    // Importing has failed silently in several different ways - a picker whose
    // callback never fired, a read that stalled, an error written to a store no
    // screen was showing. Each one looked identical from the outside: nothing
    // happens. This records every step so the next failure names itself on
    // screen instead of needing another round of guessing.

    @Published private(set) var importTrace: [String] = []

    func trace(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        importTrace.append("\(stamp)  \(line)")
        if importTrace.count > 14 { importTrace.removeFirst() }
    }

    func clearImportTrace() { importTrace.removeAll() }

    @discardableResult
    func importModel(url: URL, nameAR: String = "", category: String = "other") async -> LibraryItem? {
        trace("read: \(url.lastPathComponent)")

        // Reading goes through ImportedFile so an iCloud placeholder is
        // downloaded first and the failure says which step failed, rather than
        // reporting "unreadable" for a file the user can plainly see in Files.
        let data: Data
        do {
            data = try await ImportedFile.read(url)
            trace("read ok: \(Format.fileSize(Int64(data.count)))")
        } catch {
            trace("read FAILED: \(error.localizedDescription)")
            lastError = .unknown(error.localizedDescription)
            Haptics.error()
            return nil
        }

        guard !settings.demoMode else {
            Haptics.success()
            return DemoLibrary.items.first
        }

        do {
            trace("upload started")
            let item = try await printer.backend.uploadLibraryModel(
                filename: url.lastPathComponent,
                data: data,
                nameAR: nameAR,
                category: category
            )
            items.insert(item, at: 0)
            trace("upload ok: \(item.displayName)")
            Haptics.success()
            lastError = nil
            return item
        } catch {
            let apiError = APIError.from(error, host: settings.host)
            trace("upload FAILED: \(apiError.localizedDescription)")
            lastError = apiError
            Haptics.error()
            return nil
        }
    }

    /// Files handed over by the Share Extension. The extension only stages
    /// them in the App Group - the upload happens here, with the app's own
    /// Keychain-held token, so no credential ever leaves the app.
    @discardableResult
    func importPendingShares() async -> Int {
        let pending = SharedStore.pendingImports()
        guard !pending.isEmpty else { return 0 }

        var imported = 0
        for item in pending {
            guard let url = SharedStore.fileURL(for: item),
                  FileManager.default.fileExists(atPath: url.path)
            else {
                SharedStore.consume(item)   // nothing on disk; drop the record
                continue
            }

            guard !settings.demoMode else { continue }

            guard let data = try? Data(contentsOf: url) else {
                lastError = .unknown(L.t("library.import.unreadable"))
                SharedStore.consume(item)
                continue
            }

            do {
                let created = try await printer.backend.uploadLibraryModel(
                    filename: item.filename, data: data, nameAR: "", category: "other"
                )
                items.insert(created, at: 0)
                SharedStore.consume(item)
                imported += 1
            } catch {
                // Leave the file staged so the next launch can retry.
                lastError = APIError.from(error, host: settings.host)
                break
            }
        }

        pendingShareCount = SharedStore.pendingImports().count
        if imported > 0 { Haptics.success() }
        return imported
    }

    func setThumbnail(_ item: LibraryItem, imageData: Data) async {
        guard !settings.demoMode else { return }
        do {
            replace(try await printer.backend.replaceThumbnail(id: item.id, imageData: imageData))
            Haptics.success()
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    func regenerateThumbnail(_ item: LibraryItem) async {
        guard !settings.demoMode else { return }
        do {
            replace(try await printer.backend.regenerateThumbnail(id: item.id))
            Haptics.success()
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    func modelData(_ item: LibraryItem) async -> Data? {
        guard !settings.demoMode else { return nil }
        return try? await printer.backend.downloadLibraryModel(id: item.id)
    }

    func addToCollection(_ item: LibraryItem, collection: String) async {
        guard !settings.demoMode else { return }
        try? await printer.backend.addToCollection(collectionID: collection, itemID: item.id)
        await refreshItem(id: item.id)
    }

    func ratePrint(historyID: Int, item: LibraryItem?, rating: String, profile: [String: String]) async {
        guard !settings.demoMode else { return }
        let payload = PrintRatingPayload(
            historyID: historyID, itemID: item?.id, rating: rating, profile: profile, note: ""
        )
        try? await printer.backend.ratePrint(payload)
        if rating == "excellent", let item { await refreshItem(id: item.id) }
    }

    private func replace(_ item: LibraryItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        }
        if let index = results.firstIndex(where: { $0.item.id == item.id }) {
            results[index] = SearchResultEntry(
                item: item, score: results[index].score, reasons: results[index].reasons
            )
        }
    }

    // MARK: - Media URLs

    /// Absolute URL for a thumbnail / photo / video stored on the Pi.
    func mediaURL(_ relativePath: String?) -> URL? {
        guard let relativePath, !relativePath.isEmpty else { return nil }
        guard let base = settings.connection.backendBaseURL else { return nil }
        let encoded = relativePath
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relativePath
        var components = URLComponents(
            url: base.appendingPathComponent("api/media/\(encoded)"), resolvingAgainstBaseURL: false
        )
        if !settings.backendToken.isEmpty {
            components?.queryItems = [URLQueryItem(name: "token", value: settings.backendToken)]
        }
        return components?.url
    }
}

// MARK: - Demo data

enum DemoLibrary {
    static let categories: [LibraryCategory] = [
        LibraryCategory(id: "stands", nameAR: "حوامل", nameEN: "Stands", icon: "iphone.gen3", itemCount: 2),
        LibraryCategory(id: "keychains", nameAR: "ميداليات", nameEN: "Keychains", icon: "key", itemCount: 1),
        LibraryCategory(id: "organizers", nameAR: "منظمات", nameEN: "Organizers", icon: "tray.2", itemCount: 1),
        LibraryCategory(id: "robotics", nameAR: "روبوتات", nameEN: "Robotics", icon: "cpu", itemCount: 1)
    ]

    static let collections: [LibraryCollection] = [
        LibraryCollection(id: "favourites", nameAR: "المفضلة", nameEN: "Favourites",
                          builtin: true, icon: "star.fill", itemCount: 2),
        LibraryCollection(id: "print_later", nameAR: "للطباعة لاحقاً", nameEN: "Print later",
                          builtin: true, icon: "clock", itemCount: 1),
        LibraryCollection(id: "products", nameAR: "منتجات للبيع", nameEN: "Products",
                          builtin: true, icon: "tag", itemCount: 1)
    ]

    static let items: [LibraryItem] = [
        make(id: "demo-stand", ar: "حامل موبايل للمكتب", en: "Desk phone stand",
             category: "stands", material: "PLA", seconds: 5_400, grams: 24, favourite: true, prints: 4),
        make(id: "demo-keychain", ar: "ميدالية مفاتيح", en: "Keychain",
             category: "keychains", material: "PLA", seconds: 900, grams: 4, favourite: true, prints: 12),
        make(id: "demo-organizer", ar: "منظم أدراج", en: "Drawer organizer",
             category: "organizers", material: "PETG", seconds: 14_400, grams: 96, prints: 1),
        make(id: "demo-robot", ar: "قاعدة روبوت أردوينو", en: "Arduino robot base",
             category: "robotics", material: "PLA", seconds: 21_600, grams: 145)
    ]

    static func search(_ query: String) -> [SearchResultEntry] {
        let lowered = query.lowercased()
        return items
            .filter { $0.nameAR.contains(query) || $0.nameEN.lowercased().contains(lowered) || query.count < 3 }
            .map { SearchResultEntry(item: $0, score: 500, reasons: ["demo"]) }
    }

    private static func make(
        id: String, ar: String, en: String, category: String, material: String,
        seconds: Double, grams: Double, favourite: Bool = false, prints: Int = 0
    ) -> LibraryItem {
        LibraryItem(
            id: id,
            nameAR: ar,
            nameEN: en,
            category: category,
            modelFilename: "\(id).stl",
            modelSize: 1_048_576,
            dimensionsX: 82.4,
            dimensionsY: 64.0,
            dimensionsZ: 38.5,
            triangleCount: 18_422,
            recommendedMaterial: material,
            estimatedSeconds: seconds,
            estimatedFilamentGrams: grams,
            favourite: favourite,
            printCount: prints,
            lastPrinted: prints > 0 ? Date().addingTimeInterval(-86_400).timeIntervalSince1970 : nil,
            createdAt: 1_700_000_000,
            updatedAt: 1_700_000_000,
            collections: favourite ? ["favourites"] : []
        )
    }
}
