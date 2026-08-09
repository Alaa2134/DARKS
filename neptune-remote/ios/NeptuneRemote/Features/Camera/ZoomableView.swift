import SwiftUI

/// Pinch to zoom and drag to pan, for a live frame.
///
/// This is digital zoom - it magnifies the pixels that arrived, it does not ask
/// for more of them. On a 640x480 camera that means detail runs out quickly,
/// which is why the factor is shown rather than hidden: a nozzle at 4x on this
/// camera is four times bigger and no sharper, and knowing that is the
/// difference between "I can see the first layer" and thinking you can.
///
/// The pan gesture is attached **only while zoomed in**. At 1x the view sits
/// inside a ScrollView, and a drag gesture that is always live would eat the
/// scroll.
struct ZoomableView<Content: View>: View {
    /// Where a double tap jumps to, before returning to 1x on the next one.
    var doubleTapScale: CGFloat = 2.5
    var maxScale: CGFloat = 8
    @ViewBuilder var content: () -> Content

    @State private var scale: CGFloat = 1
    @State private var pinchAnchor: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragAnchor: CGSize = .zero

    private var isZoomed: Bool { scale > 1.02 }

    var body: some View {
        GeometryReader { geometry in
            content()
                .scaleEffect(scale)
                .offset(offset)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(magnify(in: geometry.size))
                // `.subviews` disables the drag without removing it, which
                // keeps the surrounding ScrollView scrollable at 1x.
                .simultaneousGesture(
                    pan(in: geometry.size),
                    including: isZoomed ? .all : .subviews
                )
                .onTapGesture(count: 2) { toggle(in: geometry.size) }
                .overlay(alignment: .topLeading) {
                    if isZoomed { badge }
                }
        }
    }

    // MARK: - Gestures

    private func magnify(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = clampScale(pinchAnchor * value.magnification)
                offset = clampOffset(offset, in: size)
            }
            .onEnded { _ in
                pinchAnchor = scale
                // Zooming back out has to put the frame back where it belongs,
                // or the image stays parked off to one side at 1x.
                withAnimation(.easeOut(duration: 0.2)) {
                    offset = clampOffset(offset, in: size)
                }
            }
    }

    private func pan(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                offset = clampOffset(
                    CGSize(
                        width: dragAnchor.width + value.translation.width,
                        height: dragAnchor.height + value.translation.height
                    ),
                    in: size
                )
            }
            .onEnded { _ in dragAnchor = offset }
    }

    private func toggle(in size: CGSize) {
        withAnimation(.easeOut(duration: 0.25)) {
            if isZoomed {
                reset()
            } else {
                scale = clampScale(doubleTapScale)
                pinchAnchor = scale
                offset = .zero
                dragAnchor = .zero
            }
        }
    }

    private func reset() {
        scale = 1
        pinchAnchor = 1
        offset = .zero
        dragAnchor = .zero
    }

    // MARK: - Limits

    private func clampScale(_ value: CGFloat) -> CGFloat {
        min(max(value, 1), maxScale)
    }

    /// Keeps the frame covering the view.
    ///
    /// At scale s the magnified frame overhangs by (s-1)/2 of the view on each
    /// side, and that overhang is exactly how far it may be dragged. Without
    /// this the image can be flung away entirely, leaving a black rectangle and
    /// no obvious way back.
    private func clampOffset(_ value: CGSize, in size: CGSize) -> CGSize {
        let limitX = max(0, size.width * (scale - 1) / 2)
        let limitY = max(0, size.height * (scale - 1) / 2)
        return CGSize(
            width: min(max(value.width, -limitX), limitX),
            height: min(max(value.height, -limitY), limitY)
        )
    }

    // MARK: - Badge

    private var badge: some View {
        HStack(spacing: 6) {
            Text(verbatim: String(format: "%.1f×", scale))
                .font(.caption2.weight(.semibold).monospacedDigit())
            Button {
                withAnimation(.easeOut(duration: 0.25)) { reset() }
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.caption2.weight(.bold))
            }
            .accessibilityLabel(L.t("camera.zoom.reset"))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(8)
    }
}
