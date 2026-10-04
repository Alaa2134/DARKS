import SwiftUI

/// Points the camera, for the cameras that can be pointed.
///
/// It draws nothing at all unless the Pi reports a camera with motors. That is
/// the same rule the rest of this app follows for fans, lights and macros:
/// a control for hardware that is not there is worse than a missing feature,
/// because it looks like something broke when you press it.
///
/// Each direction sends **two** calls - start on press, stop on release. The
/// camera keeps turning until told otherwise, so a single tap-and-forget would
/// leave the lens travelling until it hit its own limit.
struct PTZPad: View {
    @EnvironmentObject private var printer: PrinterStore

    @State private var status = PTZStatus()
    @State private var moving: String?
    @State private var error: String?

    var body: some View {
        if status.available {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("camera.ptz", systemImage: "dpad")

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.paused)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(alignment: .center, spacing: 20) {
                    pad
                    if status.hasOpticalZoom { zoomColumn }
                }
                .frame(maxWidth: .infinity)

                Text(localized: status.hasOpticalZoom
                        ? "camera.ptz.hint.zoom"
                        : "camera.ptz.hint")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .card()
            .task { await load() }
        } else {
            // Still asks once - a camera can gain motors when the config
            // changes, and this is the only place that would notice.
            Color.clear.frame(height: 0).task { await load() }
        }
    }

    // MARK: - Pad

    private var pad: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                button("up_left", "arrow.up.left")
                button("up", "arrow.up")
                button("up_right", "arrow.up.right")
            }
            HStack(spacing: 6) {
                button("left", "arrow.left")
                Circle()
                    .fill(Theme.pageFill)
                    .frame(width: 52, height: 52)
                    .overlay(
                        Image(systemName: "video.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    )
                button("right", "arrow.right")
            }
            HStack(spacing: 6) {
                button("down_left", "arrow.down.left")
                button("down", "arrow.down")
                button("down_right", "arrow.down.right")
            }
        }
    }

    private var zoomColumn: some View {
        VStack(spacing: 6) {
            button("zoom_in", "plus.magnifyingglass")
            button("zoom_out", "minus.magnifyingglass")
        }
    }

    private func button(_ direction: String, _ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .frame(width: 52, height: 52)
            .background(
                moving == direction ? Theme.accent.opacity(0.35) : Theme.accent.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            // A drag gesture with no minimum distance is how a press and its
            // release are told apart; a Button only reports the tap, which is
            // too late to stop a motor that started when the finger landed.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard moving != direction else { return }
                        moving = direction
                        Haptics.impact(.light)
                        Task { await send(direction, action: "start") }
                    }
                    .onEnded { _ in
                        moving = nil
                        Task { await send(direction, action: "stop") }
                    }
            )
            .accessibilityLabel(L.t("camera.ptz.\(direction)"))
    }

    // MARK: - Calls

    private func load() async {
        guard let fresh = try? await printer.backend.ptzStatus() else { return }
        status = fresh
    }

    private func send(_ direction: String, action: String) async {
        do {
            try await printer.backend.movePTZ(direction: direction, action: action)
            if action == "start" { error = nil }
        } catch {
            // Stop failing silently would leave the camera turning, so the
            // failure is shown whichever half of the gesture it came from.
            self.error = APIError.from(error, host: "").localizedDescription
            moving = nil
        }
    }
}
