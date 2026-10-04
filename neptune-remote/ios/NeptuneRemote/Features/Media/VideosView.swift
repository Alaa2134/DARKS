import AVKit
import SwiftUI
import UIKit

/// Recordings and timelapses stored on the Raspberry Pi.
struct VideosView: View {
    @EnvironmentObject private var media: MediaStore

    @State private var filter: Filter = .all
    @State private var playing: VideoRecord?

    enum Filter: String, CaseIterable, Identifiable {
        case all, recording, timelapse
        var id: String { rawValue }
        var localizationKey: String {
            self == .all ? "library.filter.all" : "video.kind.\(rawValue)"
        }
    }

    private var visible: [VideoRecord] {
        filter == .all ? media.videos : media.videos.filter { $0.kind == filter.rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                if let error = media.lastError {
                    ErrorBanner(message: error.localizedDescription) {
                        Task { await media.loadVideos() }
                    } onDismiss: {
                        media.lastError = nil
                    }
                }

                controls

                Picker(L.t("library.sort"), selection: $filter) {
                    ForEach(Filter.allCases) { option in
                        Text(localized: option.localizationKey).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                if let storage = media.storage {
                    storageCard(storage)
                }

                if visible.isEmpty {
                    EmptyStateView(
                        titleKey: "video.empty",
                        messageKey: media.canRecord ? "video.title" : "video.error.no_ffmpeg",
                        systemImage: "film"
                    )
                } else {
                    ForEach(visible) { video in
                        videoCard(video)
                    }
                }
            }
            .padding(Theme.spacing)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("video.title"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $playing) { video in
            if let url = media.videoURL(video) {
                VideoPlayer(player: AVPlayer(url: url))
                    .ignoresSafeArea()
            }
        }
        .refreshable { await media.loadVideos() }
        .task { await media.load() }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                BigActionButton(
                    titleKey: media.recording.recording ? "video.record.stop" : "video.record.start",
                    systemImage: media.recording.recording ? "stop.circle" : "record.circle",
                    tint: Theme.danger,
                    isEnabled: media.canRecord
                ) {
                    Task { await media.toggleRecording() }
                }

                BigActionButton(
                    titleKey: media.timelapse.running ? "timelapse.finish" : "timelapse.start",
                    systemImage: media.timelapse.running ? "film.stack" : "timelapse",
                    tint: Theme.accent,
                    isEnabled: media.canTimelapse
                ) {
                    Task {
                        if media.timelapse.running {
                            await media.finishTimelapse()
                        } else {
                            await media.startTimelapse()
                        }
                    }
                }
            }

            if !media.recordingBlockedKey.isEmpty {
                Label(L.t(media.recordingBlockedKey), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if media.timelapse.running {
                HStack {
                    Label(L.t("timelapse.frames", media.timelapse.frames), systemImage: "photo.stack")
                        .font(.caption)
                    Spacer()
                    Text(localized: "timelapse.mode.\(media.timelapse.mode)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            NavigationLink {
                TimelapseSettingsView()
            } label: {
                Label(L.t("timelapse.macro"), systemImage: "curlybraces")
                    .font(.caption.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .card()
    }

    private func storageCard(_ storage: VideoStorageSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("video.storage", systemImage: "internaldrive")
            Text(L.t(
                "video.storage.used",
                Format.fileSize(Int(storage.totalBytes)),
                Format.fileSize(Int(storage.diskFreeBytes))
            ))
            .font(.caption)
            .foregroundStyle(.secondary)

            ProgressView(
                value: storage.diskTotalBytes > 0
                    ? 1 - storage.diskFreeBytes / storage.diskTotalBytes
                    : 0
            )
            .tint(Theme.accent)

            Button(L.t("video.cleanup")) {
                Task { await media.cleanupVideos() }
            }
            .font(.caption.weight(.medium))
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
        }
        .card()
    }

    private func videoCard(_ video: VideoRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                playing = video
            } label: {
                ModelImage(
                    url: media.mediaURL(video.thumbnail),
                    name: video.gcodeName,
                    category: "other",
                    showsPlaceholderLabel: false
                )
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    Image(systemName: "play.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 6)
                }
            }
            .buttonStyle(.plain)
            .disabled(!video.isFinished)

            HStack(spacing: 8) {
                StatusPill(
                    text: L.t("video.kind.\(video.kind)"),
                    color: video.isTimelapse ? Theme.accent : Theme.danger,
                    systemImage: video.isTimelapse ? "timelapse" : "record.circle"
                )
                if !video.isFinished {
                    StatusPill(text: L.t("history.result.in_progress"), color: Theme.paused, systemImage: "clock")
                }
                Spacer(minLength: 0)
                Button(role: .destructive) {
                    Task { await media.deleteVideo(video) }
                } label: {
                    Image(systemName: "trash").font(.caption).foregroundStyle(Theme.danger)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(video.filename)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    Text(Format.date(video.startedAt))
                    if let duration = video.duration {
                        Text(Format.clock(duration))
                    }
                    Text(Format.fileSize(video.sizeBytes))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            if !video.error.isEmpty {
                Text(video.error)
                    .font(.caption2)
                    .foregroundStyle(Theme.danger)
            }
        }
        .card()
    }
}

/// The timelapse macro is shown for the user to copy. The app never writes to
/// printer.cfg - it only tells you what to add if you want layer-based frames.
struct TimelapseSettingsView: View {
    @EnvironmentObject private var media: MediaStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader("timelapse.macro", systemImage: "curlybraces")
                    Text(localized: "timelapse.macro.explain")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .card()

                if media.timelapseMacro.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ScrollView(.horizontal, showsIndicators: true) {
                            Text(media.timelapseMacro)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        Button {
                            UIPasteboard.general.string = media.timelapseMacro
                            Haptics.success()
                        } label: {
                            Label(L.t("timelapse.macro.copy"), systemImage: "doc.on.doc")
                                .font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                    }
                    .card()
                }

                VStack(alignment: .leading, spacing: 8) {
                    InfoRow(
                        titleKey: "timelapse.title",
                        value: L.t("timelapse.mode.\(media.timelapse.configuredMode)")
                    )
                    InfoRow(
                        titleKey: "vision.interval",
                        value: "\(media.timelapse.intervalSeconds) s"
                    )
                }
                .card()
            }
            .padding(Theme.spacing)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("timelapse.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await media.loadTimelapseMacro() }
    }
}
