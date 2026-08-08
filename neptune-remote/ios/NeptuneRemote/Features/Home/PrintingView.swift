import SwiftUI

/// The screen you look at while something is printing.
///
/// The rule the whole design follows: you should always be able to see *what*
/// is being printed as a picture. The G-code filename is supporting detail, not
/// the headline - and when the model is unknown the app says so plainly instead
/// of showing a filename where a picture belongs.
struct PrintingView: View {
    @EnvironmentObject private var printer: PrinterStore
    @EnvironmentObject private var media: MediaStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    @State private var viewMode: ViewMode = .model
    @State private var showingCancelConfirm = false

    enum ViewMode: String, CaseIterable, Identifiable {
        case model, camera, split
        var id: String { rawValue }
        var localizationKey: String { "printing.view.\(rawValue)" }
    }

    private var snapshot: PrinterSnapshot { printer.snapshot }
    private var item: PrintingItemInfo? { printer.summary?.item }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                viewModePicker
                stage
                progressCard
                if let event = media.unacknowledgedVisionEvents.first {
                    visionBanner(event)
                }
                temperatures
                controls
            }
            .padding(Theme.spacing)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("home.state.printing"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await printer.refreshSummary()
            await media.load()
        }
    }

    // MARK: - The picture

    private var viewModePicker: some View {
        Picker(L.t("printing.view.model"), selection: $viewMode) {
            ForEach(ViewMode.allCases) { mode in
                Text(localized: mode.localizationKey).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .disabled(media.streamURL == nil && media.snapshotURL == nil)
    }

    @ViewBuilder
    private var stage: some View {
        switch viewMode {
        case .model:
            modelPanel.frame(maxWidth: .infinity)
        case .camera:
            cameraPanel.frame(maxWidth: .infinity)
        case .split:
            HStack(spacing: Theme.spacing) {
                modelPanel
                cameraPanel
            }
        }
    }

    private var modelPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let item {
                ModelImage(
                    url: library.mediaURL(item.heroImage ?? item.thumbnail),
                    name: item.displayName,
                    category: item.category,
                    cornerRadius: Theme.cornerRadius
                )
                .aspectRatio(4 / 3, contentMode: .fit)

                Text(item.displayName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                if !item.recommendedMaterial.isEmpty {
                    Text(item.recommendedMaterial)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                unknownModelPanel
            }

            // The filename is deliberately small, secondary and last.
            if !snapshot.filename.isEmpty {
                Text(snapshot.filename)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .card()
    }

    private var unknownModelPanel: some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(Theme.idle.opacity(0.12))
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay {
                    VStack(spacing: 10) {
                        Image(systemName: "questionmark.square.dashed")
                            .font(.system(size: 38, weight: .light))
                            .foregroundStyle(.secondary)
                        Text(localized: "printing.unknown_model")
                            .font(.headline)
                        Text(localized: "printing.unknown_model.hint")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }
                }
        }
    }

    @ViewBuilder
    private var cameraPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let url = media.streamURL, settings.cameraKind == .mjpeg {
                MJPEGView(url: url)
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            } else if let url = media.snapshotURL {
                TimedSnapshotView(url: url)
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Theme.idle.opacity(0.12))
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "video.slash")
                                .font(.title)
                                .foregroundStyle(.secondary)
                            Text(localized: media.camera.messageKey.isEmpty
                                 ? "camera.status.no_camera"
                                 : media.camera.messageKey)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
            }

            if media.recording.recording {
                Label(
                    L.t("video.recording", Format.clock(media.recording.elapsed)),
                    systemImage: "record.circle"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.danger)
            }
        }
        .card()
    }

    // MARK: - Progress

    private var progressCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                ProgressRing(
                    progress: snapshot.progress,
                    tint: Theme.color(for: snapshot.state),
                    caption: layerCaption
                )
                .frame(width: 100, height: 100)

                VStack(alignment: .leading, spacing: 8) {
                    if let layer = snapshot.currentLayer, let total = snapshot.totalLayer, total > 0 {
                        Text(L.t("printing.layer", layer, total))
                            .font(.subheadline.weight(.medium))
                    }
                    InfoRow(titleKey: "printing.elapsed", value: Format.clock(snapshot.printDuration))
                    InfoRow(
                        titleKey: "print.remaining",
                        value: Format.duration(snapshot.estimatedTimeLeft)
                    )
                    if let finish = snapshot.estimatedFinishDate {
                        InfoRow(
                            titleKey: "print.eta",
                            value: finish.formatted(date: .omitted, time: .shortened)
                        )
                    }
                }
            }
        }
        .card(tint: Theme.color(for: snapshot.state))
    }

    private var layerCaption: String? {
        guard let current = snapshot.currentLayer else { return nil }
        if let total = snapshot.totalLayer, total > 0 { return "\(current) / \(total)" }
        return "\(current)"
    }

    // MARK: - Monitor banner

    private func visionBanner(_ event: VisionEvent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "eye.trianglebadge.exclamationmark")
                    .foregroundStyle(Theme.paused)
                VStack(alignment: .leading, spacing: 2) {
                    Text(localized: event.localizationKey)
                        .font(.subheadline.weight(.semibold))
                    Text(L.t("vision.action.\(event.action.isEmpty ? "none" : event.action)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(Format.percentValue(event.confidence * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if event.isHeuristic {
                Text(localized: "vision.provider.heuristic.note")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button(L.t("vision.acknowledge")) {
                    Task { await media.acknowledge(event) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button(L.t("vision.first_layer")) {
                    Task { await media.confirmFirstLayerOK() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .card(tint: Theme.paused)
    }

    // MARK: - Temperatures + controls

    private var temperatures: some View {
        HStack(spacing: Theme.spacing) {
            TemperatureBadge(
                titleKey: "temperature.nozzle", actual: snapshot.nozzleActual,
                target: snapshot.nozzleTarget, tint: Theme.nozzle, systemImage: "thermometer.high"
            )
            .card()
            TemperatureBadge(
                titleKey: "temperature.bed", actual: snapshot.bedActual,
                target: snapshot.bedTarget, tint: Theme.bed, systemImage: "square.3.layers.3d.bottom.filled"
            )
            .card()
        }
    }

    private var controls: some View {
        VStack(spacing: Theme.spacing) {
            HStack(spacing: 10) {
                BigActionButton(
                    titleKey: snapshot.isPaused ? "action.resume" : "action.pause",
                    systemImage: snapshot.isPaused ? "play.fill" : "pause.fill",
                    tint: Theme.paused
                ) {
                    Task {
                        if snapshot.isPaused {
                            await printer.resumePrint()
                        } else {
                            await printer.pausePrint()
                        }
                    }
                }

                BigActionButton(
                    titleKey: "action.cancel_print",
                    systemImage: "stop.fill",
                    isDestructive: true
                ) {
                    showingCancelConfirm = true
                }

                BigActionButton(
                    titleKey: media.recording.recording ? "video.record.stop" : "video.record.start",
                    systemImage: media.recording.recording ? "stop.circle" : "record.circle",
                    tint: Theme.danger,
                    isEnabled: media.canRecord
                ) {
                    Task { await media.toggleRecording() }
                }
            }

            EmergencyStopButton {
                Task { await printer.emergencyStop() }
            }
        }
        .confirmationDialog(
            L.t("action.cancel_print.confirm"),
            isPresented: $showingCancelConfirm,
            titleVisibility: .visible
        ) {
            Button(L.t("action.cancel_print"), role: .destructive) {
                Task { await printer.cancelPrint() }
            }
            Button(L.t("common.cancel"), role: .cancel) {}
        }
    }
}

/// Polls the backend snapshot endpoint when no MJPEG stream is reachable.
/// This is a genuine fallback, not a fake live view - the refresh rate is
/// deliberately shown as what it is.
struct TimedSnapshotView: View {
    let url: URL
    var interval: TimeInterval = 2

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if failed {
                Color.clear.overlay {
                    Text(localized: "camera.status.error")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func refresh() async {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let decoded = UIImage(data: data) {
                image = decoded
                failed = false
            }
        } catch {
            if image == nil { failed = true }
        }
    }
}
