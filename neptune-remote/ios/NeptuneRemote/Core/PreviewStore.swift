import Foundation
import SwiftUI

/// Holds one sliced file's toolpath while it is being looked at.
///
/// Layers arrive one at a time from the Pi, which is what makes the preview
/// possible on a phone at all - a 50 MB G-code file holds millions of
/// coordinates. The cost of that choice is latency per layer, so this smooths
/// it over in three ways:
///
/// **Layers already seen are kept.** Scrubbing back and forth over the same
/// twenty layers should not re-fetch any of them.
///
/// **The request is debounced.** Dragging a slider across four hundred layers
/// would otherwise fire four hundred requests, of which one matters.
///
/// **Neighbours are fetched quietly.** After a layer settles, the one above and
/// below are pulled in the background, so stepping one at a time is instant.
@MainActor
final class PreviewStore: ObservableObject {

    @Published private(set) var summary: PreviewSummary?
    @Published private(set) var layer: PreviewLayer?
    @Published private(set) var isLoadingSummary = false
    @Published private(set) var isLoadingLayer = false
    @Published var lastError: APIError?

    /// Which layer the scrubber is on. Set freely while dragging; the fetch
    /// behind it is debounced.
    @Published var selectedLayer = 0 {
        didSet {
            guard selectedLayer != oldValue else { return }
            scheduleLoad()
        }
    }

    @Published var showsTravel = false {
        didSet {
            guard showsTravel != oldValue else { return }
            // Travel changes what a layer contains, so everything cached for
            // the other setting is the wrong answer now.
            cache.removeAll()
            scheduleLoad(immediately: true)
        }
    }

    /// How long a slider has to settle before the layer behind it is fetched.
    /// Long enough to skip the layers dragged through, short enough that it
    /// does not feel like the app is thinking about it.
    private static let debounce: Duration = .milliseconds(140)

    private let settings: AppSettings
    private let printer: PrinterStore
    private var filename: String = ""

    private var cache: [Int: PreviewLayer] = [:]
    private var loadTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?

    /// Beyond this many layers held at once, the oldest are dropped. A layer is
    /// a few thousand doubles; four hundred of them is not something to keep on
    /// a phone for a file the user may be about to close.
    private static let cacheLimit = 60

    init(settings: AppSettings, printer: PrinterStore) {
        self.settings = settings
        self.printer = printer
    }

    var layerCount: Int { summary?.layerCount ?? 0 }
    var hasContent: Bool { (summary?.layerCount ?? 0) > 0 }

    /// The height of the layer on screen, when the slicer recorded one.
    var selectedHeight: Double? { summary?.height(at: selectedLayer) }

    /// Whether the print stops here for a filament swap.
    var isColorChangeLayer: Bool {
        summary?.colorChangeLayers.contains(selectedLayer) ?? false
    }

    // MARK: - Loading

    func open(filename: String) async {
        guard filename != self.filename || summary == nil else { return }
        self.filename = filename
        cache.removeAll()
        layer = nil
        summary = nil
        lastError = nil

        isLoadingSummary = true
        defer { isLoadingSummary = false }

        do {
            let result = try await printer.backend.previewSummary(name: filename)
            summary = result
            // Open on the first layer. It is the one that decides whether the
            // print sticks, and the one worth looking at before starting.
            selectedLayer = 0
            await loadLayer(0)
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    func close() {
        loadTask?.cancel()
        prefetchTask?.cancel()
        loadTask = nil
        prefetchTask = nil
        cache.removeAll()
        layer = nil
        summary = nil
        filename = ""
    }

    private func scheduleLoad(immediately: Bool = false) {
        // A cached layer needs no request at all, so the slider stays live
        // over ground it has already covered.
        if let cached = cache[selectedLayer], !immediately {
            layer = cached
            schedulePrefetch()
            return
        }

        loadTask?.cancel()
        let target = selectedLayer
        loadTask = Task { [weak self] in
            if !immediately {
                try? await Task.sleep(for: Self.debounce)
                guard !Task.isCancelled else { return }
            }
            await self?.loadLayer(target)
        }
    }

    private func loadLayer(_ index: Int) async {
        guard !filename.isEmpty, index >= 0, index < layerCount else { return }

        if let cached = cache[index] {
            if index == selectedLayer { layer = cached }
            return
        }

        isLoadingLayer = true
        defer { isLoadingLayer = false }

        do {
            let result = try await printer.backend.previewLayer(
                name: filename, layer: index, includeTravel: showsTravel
            )
            store(result)
            // The slider may have moved on while this was in flight. Showing a
            // layer the user has already scrolled past is worse than showing
            // the previous one a moment longer.
            if index == selectedLayer {
                layer = result
                lastError = nil
            }
            schedulePrefetch()
        } catch {
            guard !Task.isCancelled else { return }
            if index == selectedLayer {
                lastError = APIError.from(error, host: settings.host)
            }
        }
    }

    private func store(_ result: PreviewLayer) {
        cache[result.index] = result
        guard cache.count > Self.cacheLimit else { return }
        // Drop whatever is furthest from where the user is looking.
        let current = selectedLayer
        let furthest = cache.keys.max { abs($0 - current) < abs($1 - current) }
        if let furthest { cache.removeValue(forKey: furthest) }
    }

    /// Pull the layers either side, quietly, so stepping is instant.
    private func schedulePrefetch() {
        prefetchTask?.cancel()
        let current = selectedLayer
        prefetchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            for neighbour in [current + 1, current - 1] {
                guard !Task.isCancelled else { return }
                guard neighbour >= 0, neighbour < self.layerCount else { continue }
                guard self.cache[neighbour] == nil else { continue }
                // Failures here are silent on purpose: this is work the user
                // did not ask for, and an error banner for it would be noise.
                if let result = try? await self.printer.backend.previewLayer(
                    name: self.filename, layer: neighbour, includeTravel: self.showsTravel
                ) {
                    self.store(result)
                }
            }
        }
    }

    // MARK: - Moving about

    func step(by delta: Int) {
        selectedLayer = min(max(selectedLayer + delta, 0), max(0, layerCount - 1))
    }

    /// Jump to the next layer where the filament gets swapped, if there is one.
    func jumpToNextColorChange() {
        guard let layers = summary?.colorChangeLayers.sorted() else { return }
        if let next = layers.first(where: { $0 > selectedLayer }) {
            selectedLayer = next
        } else if let first = layers.first {
            selectedLayer = first
        }
    }
}
