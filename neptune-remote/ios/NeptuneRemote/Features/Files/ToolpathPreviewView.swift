import SwiftUI

/// See what the slicer actually produced.
///
/// Until now slicing gave you a number - four hours, ninety grams - and nothing
/// to look at. That is the difference between this app and a slicer: you could
/// not tell whether the first layer covered the bed, where the supports landed,
/// or whether the part you thought you were printing was the part that got
/// sliced.
///
/// One layer at a time, deliberately. A full 3D toolpath on a phone is hundreds
/// of thousands of line segments, which is the same mistake the camera made -
/// and this answers the question people actually open it for: is the first
/// layer right, and where did the supports go.
struct ToolpathPreviewView: View {
    let filename: String

    @EnvironmentObject private var printer: PrinterStore
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var store: PreviewStore

    init(filename: String, settings: AppSettings, printer: PrinterStore) {
        self.filename = filename
        _store = StateObject(wrappedValue: PreviewStore(settings: settings, printer: printer))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                if let error = store.lastError {
                    ErrorBanner(
                        message: error.localizedDescription,
                        onDismiss: { store.lastError = nil }
                    )
                }

                if store.isLoadingSummary {
                    // The first open scans the whole file to index its layers,
                    // which on a 50 MB print is a real wait - so it is named
                    // rather than left as a spinner.
                    BusyLine(textKey: "preview.indexing", detail: filename)
                        .card()
                } else if store.hasContent {
                    canvasCard
                    scrubberCard
                    legendCard
                } else if store.lastError == nil {
                    EmptyStateView(
                        titleKey: "preview.unavailable.title",
                        messageKey: "preview.unavailable.message",
                        systemImage: "square.3.layers.3d.slash"
                    )
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
            .animation(.neptuneContent, value: store.hasContent)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("preview.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.open(filename: filename) }
        .onDisappear { store.close() }
    }

    // MARK: - The picture

    private var canvasCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader("preview.layer", systemImage: "square.3.layers.3d")
                Spacer()
                if store.isLoadingLayer {
                    ProgressView().controlSize(.mini)
                }
            }

            ToolpathCanvas(
                layer: store.layer,
                bounds: store.summary?.bounds ?? PreviewBounds()
            )
            .aspectRatio(1, contentMode: .fit)
            .background(Theme.previewBed, in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )

            HStack(spacing: 14) {
                Label(
                    L.t("preview.layer_of", store.selectedLayer + 1, store.layerCount),
                    systemImage: "number"
                )
                .font(.caption.weight(.medium))
                .monospacedDigit()

                if let height = store.selectedHeight {
                    Label(String(format: "Z %.2f mm", height), systemImage: "arrow.up.to.line")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }

            if store.isColorChangeLayer {
                Label(L.t("preview.color_change_here"), systemImage: "paintpalette.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.paused)
                    .transition(.opacity)
            }
        }
        .card()
        .animation(.neptune, value: store.isColorChangeLayer)
    }

    // MARK: - Moving through the layers

    private var scrubberCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    store.step(by: -1)
                    Haptics.selection()
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 40, height: 34)
                }
                .buttonStyle(.bordered)
                .disabled(store.selectedLayer <= 0)

                Slider(
                    value: Binding(
                        get: { Double(store.selectedLayer) },
                        set: { store.selectedLayer = Int($0.rounded()) }
                    ),
                    in: 0...Double(max(1, store.layerCount - 1)),
                    step: 1
                )
                .tint(Theme.accent)

                Button {
                    store.step(by: 1)
                    Haptics.selection()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 40, height: 34)
                }
                .buttonStyle(.bordered)
                .disabled(store.selectedLayer >= store.layerCount - 1)
            }

            // Where the filament gets swapped, marked on the track itself -
            // the whole point of tying the preview to the colour feature.
            if let changes = store.summary?.colorChangeLayers, !changes.isEmpty {
                colorChangeTrack(changes)
            }

            HStack {
                Button {
                    store.selectedLayer = 0
                } label: {
                    Label(L.t("preview.first_layer"), systemImage: "arrow.down.to.line")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if let changes = store.summary?.colorChangeLayers, !changes.isEmpty {
                    Button {
                        store.jumpToNextColorChange()
                        Haptics.selection()
                    } label: {
                        Label(L.t("preview.next_color_change"), systemImage: "paintpalette")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Spacer(minLength: 0)

                Toggle(isOn: $store.showsTravel) {
                    Text(localized: "preview.show_travel")
                        .font(.caption)
                }
                .toggleStyle(.button)
                .controlSize(.small)
            }
        }
        .card()
    }

    /// A thin track under the slider with a tick at every colour change.
    private func colorChangeTrack(_ changes: [Int]) -> some View {
        GeometryReader { geometry in
            let span = Double(max(1, store.layerCount - 1))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 4)
                ForEach(changes, id: \.self) { layer in
                    Capsule()
                        .fill(Theme.paused)
                        .frame(width: 3, height: 10)
                        .offset(x: geometry.size.width * (Double(layer) / span) - 1.5)
                }
            }
            .frame(height: 10)
        }
        .frame(height: 10)
        .accessibilityLabel(L.t("preview.color_change_count", changes.count))
    }

    // MARK: - Legend

    private var legendCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("preview.legend", systemImage: "list.bullet")

            // Only what is actually on this layer. A legend listing features
            // the layer does not contain is a legend nobody reads.
            let present = store.layer?.featuresPresent ?? []
            if present.isEmpty {
                Text(localized: "preview.legend.empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                FlowRow(spacing: 10) {
                    ForEach(present, id: \.self) { feature in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Theme.color(for: feature))
                                .frame(width: 16, height: 4)
                            Text(localized: feature.localizationKey)
                                .font(.caption2)
                        }
                    }
                }
            }
        }
        .card()
    }
}

// MARK: - The canvas

/// Draws one layer.
///
/// `Canvas` rather than a stack of `Path` views: a layer can hold a few thousand
/// segments, and that many SwiftUI views is the camera's mistake made again in a
/// different place. One path per feature, stroked once each, so the number of
/// draw calls is the number of colours rather than the number of lines.
struct ToolpathCanvas: View {
    let layer: PreviewLayer?
    let bounds: PreviewBounds

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            guard let layer, !bounds.isEmpty else { return }

            // Fit the print, not the bed. A 20 mm part framed inside a 320 mm
            // plate is a dot in the middle of nothing.
            let inset: CGFloat = 12
            let usable = CGSize(
                width: max(1, size.width - inset * 2),
                height: max(1, size.height - inset * 2)
            )
            let scale = min(usable.width / bounds.width, usable.height / bounds.height)
            let drawn = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            let originX = (size.width - drawn.width) / 2
            let originY = (size.height - drawn.height) / 2

            func project(_ point: CGPoint) -> CGPoint {
                CGPoint(
                    x: originX + (point.x - bounds.minX) * scale,
                    // The bed's Y grows away from the front; the screen's grows
                    // downwards. Without the flip the preview is a mirror of
                    // what comes off the printer.
                    y: originY + drawn.height - (point.y - bounds.minY) * scale
                )
            }

            for feature in ToolpathFeature.drawingOrder {
                let segments = layer.segments(for: feature)
                guard !segments.isEmpty else { continue }

                var path = Path()
                for segment in segments {
                    let points = segment.coordinates
                    guard points.count >= 2 else { continue }
                    path.move(to: project(points[0]))
                    for point in points.dropFirst() {
                        path.addLine(to: project(point))
                    }
                }

                context.stroke(
                    path,
                    with: .color(Theme.color(for: feature)),
                    style: StrokeStyle(
                        lineWidth: feature == .travel ? 0.5 : 1.6,
                        lineCap: .round,
                        lineJoin: .round,
                        dash: feature == .travel ? [2, 3] : []
                    )
                )
            }
        }
        .drawingGroup()
        .accessibilityLabel(L.t("preview.canvas.accessibility"))
    }
}

// MARK: - Legend layout

/// Wraps its children onto as many lines as they need.
///
/// The legend has between two and nine entries depending on the layer, and a
/// fixed grid would leave a hole on most of them.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + lineHeight)
    }

    func placeSubviews(
        in rect: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = rect.minX
        var y = rect.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > rect.maxX, x > rect.minX {
                x = rect.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
