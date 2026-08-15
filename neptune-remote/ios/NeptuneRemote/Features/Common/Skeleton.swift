import SwiftUI

/// Placeholders shaped like the thing that is loading.
///
/// The app showed a spinner in the middle of an empty screen and nothing else,
/// which tells you two things - that something is happening, and nothing about
/// what. A shape that matches the content answers the second question before
/// the data arrives: how many rows, how big, laid out how. The screen then
/// fills in rather than appearing, so the layout never jumps.
///
/// The shimmer is deliberately slow and low-contrast. A fast bright sweep reads
/// as an alarm; this one reads as work in progress, which is what it is.
struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { geometry in
                        let width = geometry.size.width
                        LinearGradient(
                            colors: [
                                .clear,
                                Color.primary.opacity(0.09),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: width * 0.55)
                        .offset(x: phase * width * 1.6)
                    }
                    .allowsHitTesting(false)
                }
            }
            .mask(content)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

extension View {
    /// A slow sweep across a placeholder, so it reads as loading rather than as
    /// a rendering failure. Respects Reduce Motion by simply not moving.
    func shimmering() -> some View { modifier(Shimmer()) }
}

/// One grey block, sized like the text or image it stands in for.
struct SkeletonBlock: View {
    var width: CGFloat?
    var height: CGFloat = 12
    var cornerRadius: CGFloat = 6

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.primary.opacity(0.10))
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

/// A card-shaped placeholder: a title, two lines, and an optional image block.
struct SkeletonCard: View {
    var lines: Int = 3
    var showsThumbnail = false
    var thumbnailHeight: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsThumbnail {
                SkeletonBlock(height: thumbnailHeight, cornerRadius: Theme.smallCornerRadius)
            }
            SkeletonBlock(width: 140, height: 15)
            ForEach(0..<max(0, lines), id: \.self) { index in
                // Ragged right edge, like real text. A stack of identical bars
                // reads as a loading bar, not as a paragraph.
                SkeletonBlock(width: index == lines - 1 ? 180 : nil, height: 11)
            }
        }
        .card()
        .shimmering()
        .accessibilityHidden(true)
    }
}

/// A list row placeholder: thumbnail, title, subtitle.
struct SkeletonRow: View {
    var showsThumbnail = true

    var body: some View {
        HStack(spacing: 12) {
            if showsThumbnail {
                SkeletonBlock(width: 52, height: 52, cornerRadius: 10)
            }
            VStack(alignment: .leading, spacing: 7) {
                SkeletonBlock(width: 150, height: 13)
                SkeletonBlock(width: 90, height: 10)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .shimmering()
        .accessibilityHidden(true)
    }
}

/// Several rows, for a list that is still arriving.
struct SkeletonList: View {
    var rows: Int = 5
    var showsThumbnail = true

    var body: some View {
        VStack(spacing: 10) {
            ForEach(0..<max(1, rows), id: \.self) { index in
                SkeletonRow(showsThumbnail: showsThumbnail)
                if index < rows - 1 { Divider() }
            }
        }
        .card()
        .accessibilityHidden(true)
    }
}

/// A grid of tiles, for the library.
struct SkeletonGrid: View {
    var tiles: Int = 6
    var columns: Int = 2
    var tileHeight: CGFloat = 150

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: max(1, columns)),
            spacing: 12
        ) {
            ForEach(0..<max(1, tiles), id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    SkeletonBlock(height: tileHeight, cornerRadius: Theme.smallCornerRadius)
                    SkeletonBlock(width: 100, height: 12)
                    SkeletonBlock(width: 60, height: 10)
                }
            }
        }
        .shimmering()
        .accessibilityHidden(true)
    }
}

// MARK: - Saying what is happening

/// A line of text that says what the app is doing right now.
///
/// "Loading" is not an answer. Reaching the printer, reading its config,
/// slicing a model and uploading a file are four different waits with four
/// different reasons to be slow, and telling them apart is the difference
/// between waiting and wondering whether it has hung.
struct BusyLine: View {
    let textKey: String
    /// Filled in when the wait has a measurable end. Left nil rather than
    /// invented - a progress bar that does not track anything is a lie that
    /// looks like information.
    var progress: Double?
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(localized: textKey)
                        .font(.subheadline.weight(.medium))
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }

            if let progress {
                ProgressView(value: min(max(progress, 0), 1))
                    .tint(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Motion

extension Animation {
    /// The app's one transition curve, so screens feel like one app rather than
    /// like a collection of them. Slightly damped rather than bouncy: this is a
    /// tool attached to a machine, not a game.
    static let neptune = Animation.spring(response: 0.34, dampingFraction: 0.86)

    /// For content arriving - a shade slower, so a list filling in reads as
    /// arriving rather than snapping.
    static let neptuneContent = Animation.spring(response: 0.42, dampingFraction: 0.9)
}

extension AnyTransition {
    /// Content replacing a placeholder: it fades up into place.
    static let neptuneContent = AnyTransition.opacity.combined(
        with: .move(edge: .bottom)
    )
}
