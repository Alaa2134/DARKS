import AVKit
import SwiftUI
import WebKit

struct CameraView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var printer: PrinterStore

    @StateObject private var stream = MJPEGStream()
    @State private var isFullscreen = false
    @State private var snapshotImage: UIImage?
    @State private var showingShare = false
    @State private var snapshotURL: URL?

    private var cameraURL: URL? {
        let raw = settings.cameraURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if raw.lowercased().hasPrefix("http") { return URL(string: raw) }
        // Relative path -> resolve against the Pi.
        guard let base = settings.connection.moonrakerBaseURL else { return nil }
        return URL(string: base.absoluteString + (raw.hasPrefix("/") ? raw : "/\(raw)"))
    }

    var body: some View {
        Group {
            if settings.demoMode {
                demoView
            } else if let cameraURL {
                streamView(url: cameraURL)
            } else {
                setupInstructions
            }
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("tab.camera"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        takeSnapshot()
                    } label: {
                        Label(L.t("camera.snapshot"), systemImage: "camera")
                    }
                    .disabled(stream.image == nil)

                    Button {
                        isFullscreen = true
                    } label: {
                        Label(L.t("camera.fullscreen"), systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .disabled(cameraURL == nil)

                    Button {
                        reconnect()
                    } label: {
                        Label(L.t("common.retry"), systemImage: "arrow.clockwise")
                    }

                    NavigationLink(destination: CameraSettingsView()) {
                        Label(L.t("camera.settings"), systemImage: "gearshape")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .fullScreenCover(isPresented: $isFullscreen) {
            CameraFullscreenView(stream: stream, kind: settings.cameraKind, url: cameraURL)
        }
        .sheet(isPresented: $showingShare) {
            if let snapshotURL { ShareSheet(items: [snapshotURL]) }
        }
        .onDisappear { stream.stop() }
    }

    // MARK: - Stream

    @ViewBuilder
    private func streamView(url: URL) -> some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .fill(Color.black)

                    switch settings.cameraKind {
                    case .mjpeg:
                        if let image = stream.image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .rotationEffect(.degrees(Double(settings.cameraRotation)))
                                .scaleEffect(x: settings.cameraMirrored ? -1 : 1, y: 1)
                        } else {
                            connectingView
                        }
                    case .snapshot:
                        SnapshotCameraView(url: url)
                    case .webrtc, .mainsail:
                        CameraWebView(url: url)
                            .frame(height: 260)
                    }
                }
                .frame(minHeight: 240)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))

                statusCard
                overlayCard
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .task(id: url) {
            if settings.cameraKind == .mjpeg { stream.start(url: url) }
        }
    }

    private var connectingView: some View {
        VStack(spacing: 10) {
            if let message = stream.errorMessage {
                Image(systemName: "video.slash.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.white.opacity(0.7))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button(L.t("common.retry"), action: reconnect)
                    .buttonStyle(.bordered)
                    .tint(.white)
            } else {
                ProgressView().tint(.white)
                Text(localized: "camera.connecting")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("camera.status", systemImage: "video.fill")
            InfoRow(
                titleKey: "camera.connection",
                value: L.t(stream.isConnected ? "status.connected" : "status.disconnected"),
                tint: stream.isConnected ? Theme.printing : Theme.paused
            )
            InfoRow(titleKey: "camera.kind", value: L.t(settings.cameraKind.localizationKey))
            InfoRow(titleKey: "camera.frames", value: "\(stream.framesReceived)")
        }
        .card()
    }

    private var overlayCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("camera.overlay", systemImage: "printer")
            HStack(spacing: 12) {
                StatTile(titleKey: "printer.state", value: L.t(printer.snapshot.state.localizationKey),
                         systemImage: printer.snapshot.state.symbolName,
                         tint: Theme.color(for: printer.snapshot.state))
                StatTile(titleKey: "print.progress", value: Format.percent(printer.snapshot.progress),
                         systemImage: "chart.pie")
                StatTile(titleKey: "temperature.nozzle",
                         value: Format.temperatureShort(printer.snapshot.nozzleActual),
                         systemImage: "flame.fill", tint: Theme.nozzle)
            }
        }
        .card()
    }

    // MARK: - Demo

    private var demoView: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.black, Color(white: 0.18)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .frame(height: 240)
                    VStack(spacing: 10) {
                        Image(systemName: "video.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.white.opacity(0.5))
                        Text(localized: "camera.demo_placeholder")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
                overlayCard
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Setup instructions

    private var setupInstructions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 42))
                        .foregroundStyle(.secondary)
                    Text(localized: "camera.none.title")
                        .font(.headline)
                    Text(localized: "camera.none.message")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()

                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader("camera.setup.title", systemImage: "list.number")
                    ForEach(1...4, id: \.self) { step in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(step)")
                                .font(.caption.weight(.bold))
                                .frame(width: 22, height: 22)
                                .background(Theme.accent.opacity(0.18), in: Circle())
                            Text(localized: "camera.setup.step\(step)")
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .card()

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader("camera.setup.urls", systemImage: "link")
                    Text(verbatim: "http://\(settings.host)/webcam/?action=stream")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Text(verbatim: "http://\(settings.host)/webcam/?action=snapshot")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Text(verbatim: "http://\(settings.host):8080/?action=stream")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                .card()

                NavigationLink(destination: CameraSettingsView()) {
                    Label(L.t("camera.settings"), systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Actions

    private func reconnect() {
        guard let cameraURL, settings.cameraKind == .mjpeg else { return }
        stream.start(url: cameraURL)
    }

    private func takeSnapshot() {
        guard let image = stream.snapshot(), let data = image.jpegData(compressionQuality: 0.9) else { return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("neptune-share", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("snapshot-\(Int(Date().timeIntervalSince1970)).jpg")
        do {
            try data.write(to: url, options: .atomic)
            snapshotURL = url
            snapshotImage = image
            showingShare = true
            Haptics.success()
        } catch {
            Haptics.error()
        }
    }
}

// MARK: - Fullscreen

struct CameraFullscreenView: View {
    @ObservedObject var stream: MJPEGStream
    let kind: CameraKind
    let url: URL?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if kind == .mjpeg, let image = stream.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea()
            } else if let url, kind != .mjpeg {
                CameraWebView(url: url).ignoresSafeArea()
            } else {
                ProgressView().tint(.white)
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white.opacity(0.85))
                            .padding()
                    }
                }
                Spacer()
            }
        }
        .statusBarHidden()
    }
}

// MARK: - Snapshot polling camera

struct SnapshotCameraView: View {
    let url: URL
    @State private var image: UIImage?
    @State private var timerTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .onAppear(perform: start)
        .onDisappear { timerTask?.cancel() }
    }

    private func start() {
        timerTask?.cancel()
        timerTask = Task {
            while !Task.isCancelled {
                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                if let (data, _) = try? await URLSession.shared.data(for: request),
                   let decoded = UIImage(data: data) {
                    await MainActor.run { image = decoded }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}

// MARK: - WebView (WebRTC / Mainsail camera pages)

struct CameraWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }
}

// MARK: - Home preview card

struct CameraPreviewCard: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var stream = MJPEGStream()

    private var cameraURL: URL? {
        let raw = settings.cameraURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw.lowercased().hasPrefix("http") else { return nil }
        return URL(string: raw)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("camera.preview", systemImage: "video.fill")

            ZStack {
                RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous)
                    .fill(Color.black.opacity(0.85))
                    .frame(height: 150)

                if settings.demoMode {
                    VStack(spacing: 6) {
                        Image(systemName: "video.fill")
                            .font(.title)
                            .foregroundStyle(.white.opacity(0.5))
                        Text(localized: "camera.demo_placeholder")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                } else if let image = stream.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 150)
                        .clipped()
                } else if cameraURL == nil {
                    Text(localized: "camera.not_configured")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                } else {
                    ProgressView().tint(.white)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
        }
        .card()
        .task(id: settings.cameraURL) {
            guard !settings.demoMode, settings.cameraKind == .mjpeg, let cameraURL else { return }
            stream.start(url: cameraURL)
        }
        .onDisappear { stream.stop() }
    }
}
