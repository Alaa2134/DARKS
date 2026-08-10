import SwiftUI

/// Where the camera is resolved from settings, in one place.
///
/// Three views were each doing their own version of this, and two of them did
/// not understand the backend relay - so choosing an IP camera worked on the
/// camera screen and showed nothing on Home. One resolver, one answer.
enum CameraSource {
    static func url(for settings: AppSettings) -> URL? {
        let raw = settings.cameraURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if raw == ConnectionConfig.backendRelaySentinel {
            return settings.connection.backendCameraStreamURL(token: settings.backendToken)
        }
        if raw.lowercased().hasPrefix("http") { return URL(string: raw) }
        guard let base = settings.connection.moonrakerBaseURL else { return nil }
        return URL(string: base.absoluteString + (raw.hasPrefix("/") ? raw : "/\(raw)"))
    }
}

/// The live view, sized for a card, wherever what the printer is doing matters.
///
/// The camera used to be a place you went. That is backwards for a machine you
/// are watching: the question is never "what does the camera see", it is
/// "what is my print doing" - and the answer to that is a picture. So the live
/// frame goes next to the progress, and the model thumbnail becomes the
/// fallback for a printer with no camera rather than the default.
///
/// Rotation and mirroring are applied here too. A camera mounted upside down is
/// upside down everywhere, and correcting it on one screen only would make the
/// two views disagree about which way up the printer is.
struct PrinterEye: View {
    /// Shown when there is no camera - typically the sliced model's own image.
    var fallbackURL: URL?
    var height: CGFloat = 150

    @EnvironmentObject private var settings: AppSettings
    @StateObject private var stream = MJPEGStream()

    private var cameraURL: URL? { CameraSource.url(for: settings) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.85))

            if settings.demoMode {
                placeholder(key: "camera.demo_placeholder", symbol: "video.fill")
            } else if let image = stream.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .rotationEffect(.degrees(Double(settings.cameraRotation)))
                    .scaleEffect(x: settings.cameraMirrored ? -1 : 1, y: 1)
            } else if cameraURL == nil {
                fallback
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(height: height)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
        // Keyed on the URL so switching cameras restarts cleanly, and torn down
        // on disappear: two screens streaming at once is two connections to a
        // camera that may only serve one.
        .task(id: cameraURL) {
            guard let cameraURL, !settings.demoMode else { return }
            stream.start(url: cameraURL)
        }
        .onDisappear { stream.stop() }
    }

    @ViewBuilder
    private var fallback: some View {
        if let fallbackURL {
            AsyncImage(url: fallbackURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit().padding(8)
                default:
                    placeholder(key: "camera.not_configured", symbol: "video.slash")
                }
            }
        } else {
            placeholder(key: "camera.not_configured", symbol: "video.slash")
        }
    }

    private func placeholder(key: String, symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title)
                .foregroundStyle(.white.opacity(0.5))
            Text(localized: key)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .padding(8)
    }
}
