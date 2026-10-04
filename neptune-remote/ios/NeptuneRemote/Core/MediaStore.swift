import Foundation
import SwiftUI

/// Camera, video recording, timelapse and the local print-failure monitor.
///
/// Every capability here can be genuinely unavailable (no camera plugged in,
/// no FFmpeg installed, no ONNX runtime). The store never pretends otherwise:
/// it surfaces the backend's `available` flags and `lastError` text so the UI
/// can explain exactly what is missing instead of showing a dead button.
@MainActor
final class MediaStore: ObservableObject {

    // MARK: - Published state

    @Published private(set) var camera = CameraStatus.unknown
    @Published private(set) var devices: [CameraDeviceInfo] = []
    @Published private(set) var recording = RecordingStatus.idle
    @Published private(set) var timelapse = TimelapseStatus.idle
    @Published private(set) var vision = VisionStatus.unknown

    @Published private(set) var videos: [VideoRecord] = []
    @Published private(set) var storage: VideoStorageSummary?
    @Published private(set) var visionEvents: [VisionEvent] = []

    @Published private(set) var isLoading = false
    @Published private(set) var isProbingDevices = false
    @Published private(set) var isBusy = false
    @Published var lastError: APIError?
    @Published var lastMessage: String?

    /// Region of interest the user is currently drawing (normalised 0…1).
    @Published var pendingROI: [Double]?

    /// Suggested `printer.cfg` macro for layer-based timelapse.
    /// Shown for copy/paste only - the app never writes to printer.cfg.
    @Published private(set) var timelapseMacro: String = ""

    private let settings: AppSettings
    private let printer: PrinterStore

    init(settings: AppSettings, printer: PrinterStore) {
        self.settings = settings
        self.printer = printer
    }

    // MARK: - Summary routing

    /// Called by AppEnvironment whenever a `summary` frame lands, so the media
    /// screens stay live without polling.
    func apply(_ summary: BackendSummary) {
        camera = summary.camera
        recording = summary.recording
        timelapse = summary.timelapse
        vision = summary.vision
    }

    // MARK: - Loading

    func load(force: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        if settings.demoMode {
            camera = DemoMedia.camera
            recording = DemoMedia.recording
            timelapse = DemoMedia.timelapse
            vision = DemoMedia.vision
            videos = DemoMedia.videos
            storage = DemoMedia.storage
            visionEvents = DemoMedia.visionEvents
            return
        }

        do {
            async let cameraTask = printer.backend.cameraStatus()
            async let recordingTask = printer.backend.recordingStatus()
            async let timelapseTask = printer.backend.timelapseStatus()
            async let visionTask = printer.backend.visionStatus()
            camera = try await cameraTask
            recording = try await recordingTask
            timelapse = try await timelapseTask
            vision = try await visionTask
            pendingROI = vision.roi
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }

        if force || videos.isEmpty {
            await loadVideos()
        }
    }

    func refreshCamera() async {
        guard !settings.demoMode else { return }
        camera = (try? await printer.backend.cameraStatus()) ?? camera
    }

    /// Probes `/dev/video*` on the Pi - slow, so it is only run on demand from
    /// the camera settings screen.
    func probeDevices() async {
        guard !settings.demoMode else {
            devices = DemoMedia.camera.devices
            return
        }
        isProbingDevices = true
        defer { isProbingDevices = false }
        do {
            camera = try await printer.backend.cameraStatus(probe: true)
            devices = try await printer.backend.cameraDevices()
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    // MARK: - Snapshots

    /// A single JPEG frame. Returns nil (and sets `lastError`) when there is no
    /// working camera - callers must handle that rather than showing a blank box.
    func snapshot() async -> Data? {
        guard !settings.demoMode else { return nil }
        do {
            let data = try await printer.backend.snapshot()
            lastError = nil
            return data
        } catch {
            lastError = APIError.from(error, host: settings.host)
            return nil
        }
    }

    func saveSnapshot() async {
        guard !settings.demoMode else {
            lastMessage = L.t("demo.action.ignored")
            return
        }
        do {
            _ = try await printer.backend.saveSnapshot()
            lastMessage = L.t("camera.snapshot.saved")
            Haptics.success()
        } catch {
            lastError = APIError.from(error, host: settings.host)
            Haptics.error()
        }
    }

    /// Direct MJPEG stream URL for the live view.
    ///
    /// The user's own setting wins. Otherwise the backend-reported URL is used,
    /// but only after rewriting a loopback host (`127.0.0.1` / `localhost`) to
    /// the Tailscale address - a Pi-local URL is meaningless from the phone.
    var streamURL: URL? {
        let configured = settings.cameraURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty { return URL(string: configured) }
        guard camera.available, !camera.url.isEmpty else { return nil }
        guard var components = URLComponents(string: camera.url) else { return nil }
        if let host = components.host, ["127.0.0.1", "localhost", "::1", "0.0.0.0"].contains(host) {
            guard !settings.host.isEmpty else { return nil }
            components.host = settings.host
        }
        return components.url
    }

    /// Single-frame URL served by the backend. Always reachable when the
    /// backend is, so it is the fallback when no direct stream URL exists.
    var snapshotURL: URL? {
        guard !settings.demoMode, let base = settings.connection.backendBaseURL else { return nil }
        var components = URLComponents(
            url: base.appendingPathComponent("api/camera/snapshot"), resolvingAgainstBaseURL: false
        )
        if !settings.backendToken.isEmpty {
            components?.queryItems = [URLQueryItem(name: "token", value: settings.backendToken)]
        }
        return components?.url
    }

    // MARK: - Recording

    var canRecord: Bool { recording.ffmpegAvailable && recording.cameraAvailable }

    /// Why recording is unavailable, as a localization key ("" when it works).
    var recordingBlockedKey: String {
        if canRecord { return "" }
        if !recording.cameraAvailable { return "camera.status.no_camera" }
        return "video.error.no_ffmpeg"
    }

    func toggleRecording() async {
        if recording.recording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    func startRecording() async {
        guard !settings.demoMode else {
            lastMessage = L.t("demo.action.ignored")
            return
        }
        guard canRecord else {
            lastError = .unknown(L.t(recordingBlockedKey))
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let video = try await printer.backend.startRecording()
            recording = try await printer.backend.recordingStatus()
            insert(video)
            Haptics.success()
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
            Haptics.error()
        }
    }

    func stopRecording() async {
        guard !settings.demoMode else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let video = try await printer.backend.stopRecording()
            recording = try await printer.backend.recordingStatus()
            insert(video)
            Haptics.success()
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
            Haptics.error()
        }
    }

    // MARK: - Timelapse

    var canTimelapse: Bool { timelapse.ffmpegAvailable && timelapse.cameraAvailable }

    func startTimelapse() async {
        guard !settings.demoMode else { return }
        guard canTimelapse else {
            lastError = .unknown(L.t(timelapse.cameraAvailable ? "video.error.no_ffmpeg" : "camera.status.no_camera"))
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            try await printer.backend.startTimelapse()
            timelapse = try await printer.backend.timelapseStatus()
            Haptics.success()
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
            Haptics.error()
        }
    }

    /// Renders the collected frames into an MP4.
    func finishTimelapse() async {
        guard !settings.demoMode else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let video = try await printer.backend.finishTimelapse()
            timelapse = try await printer.backend.timelapseStatus()
            insert(video)
            lastMessage = L.t("timelapse.rendered")
            Haptics.success()
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
            Haptics.error()
        }
    }

    /// Loads the *suggested* macro text. Copy/paste only - installing it into
    /// printer.cfg is always the user's own deliberate action.
    func loadTimelapseMacro() async {
        guard !settings.demoMode else {
            timelapseMacro = DemoMedia.macro
            return
        }
        timelapseMacro = (try? await printer.backend.timelapseMacro()) ?? ""
    }

    // MARK: - Videos

    func loadVideos(kind: String? = nil) async {
        guard !settings.demoMode else {
            videos = DemoMedia.videos
            storage = DemoMedia.storage
            return
        }
        do {
            async let videosTask = printer.backend.videos(kind: kind)
            async let storageTask = printer.backend.videoStorage()
            videos = try await videosTask
            storage = try await storageTask
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    func deleteVideo(_ video: VideoRecord) async {
        guard !settings.demoMode else {
            videos.removeAll { $0.id == video.id }
            return
        }
        do {
            try await printer.backend.deleteVideo(id: video.id)
            videos.removeAll { $0.id == video.id }
            storage = try? await printer.backend.videoStorage()
            Haptics.success()
        } catch {
            lastError = APIError.from(error, host: settings.host)
            Haptics.error()
        }
    }

    /// Applies the retention policy now; returns how many files were removed.
    @discardableResult
    func cleanupVideos() async -> Int {
        guard !settings.demoMode else { return 0 }
        do {
            let removed = try await printer.backend.cleanupVideos()
            await loadVideos()
            lastMessage = L.t("video.cleanup.removed", removed)
            return removed
        } catch {
            lastError = APIError.from(error, host: settings.host)
            return 0
        }
    }

    func videoData(_ video: VideoRecord) async -> Data? {
        guard !settings.demoMode else { return nil }
        return try? await printer.backend.downloadVideo(id: video.id)
    }

    /// Streamable URL for `AVPlayer` (range requests are served by the backend).
    func videoURL(_ video: VideoRecord) -> URL? {
        guard let base = settings.connection.backendBaseURL else { return nil }
        var components = URLComponents(
            url: base.appendingPathComponent("api/videos/\(video.id)/download"),
            resolvingAgainstBaseURL: false
        )
        if !settings.backendToken.isEmpty {
            components?.queryItems = [URLQueryItem(name: "token", value: settings.backendToken)]
        }
        return components?.url
    }

    private func insert(_ video: VideoRecord) {
        if let index = videos.firstIndex(where: { $0.id == video.id }) {
            videos[index] = video
        } else {
            videos.insert(video, at: 0)
        }
    }

    // MARK: - Print-failure monitor (fully local)

    var visionMode: VisionMode { VisionMode(rawValue: vision.mode) ?? .off }

    /// Explains, in one localization key, why the monitor is not watching.
    var visionBlockedKey: String {
        if vision.available { return "" }
        if !vision.cameraAvailable { return "camera.status.no_camera" }
        if vision.provider == "disabled" { return "vision.error.no_provider" }
        return "vision.error.unavailable"
    }

    var unacknowledgedVisionEvents: [VisionEvent] {
        visionEvents.filter { $0.confirmed && !$0.acknowledged }
    }

    func setVisionMode(_ mode: VisionMode) async {
        await updateVision(VisionSettingsPayload(mode: mode.rawValue))
    }

    func updateVision(_ payload: VisionSettingsPayload) async {
        guard !settings.demoMode else { return }
        do {
            vision = try await printer.backend.updateVisionSettings(payload)
            pendingROI = vision.roi
            Haptics.impact(.light)
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    /// Commits the region the user drew on the camera preview.
    func commitROI() async {
        guard !settings.demoMode else { return }
        do {
            try await printer.backend.setROI(pendingROI)
            vision = try await printer.backend.visionStatus()
            Haptics.success()
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    func clearROI() async {
        pendingROI = nil
        await commitROI()
    }

    func loadVisionEvents(confirmedOnly: Bool = false) async {
        guard !settings.demoMode else {
            visionEvents = DemoMedia.visionEvents
            return
        }
        do {
            visionEvents = try await printer.backend.visionEvents(confirmedOnly: confirmedOnly)
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    func acknowledge(_ event: VisionEvent) async {
        guard !settings.demoMode else { return }
        try? await printer.backend.acknowledgeVisionEvent(id: event.id)
        await loadVisionEvents()
    }

    func clearVisionEvents() async {
        guard !settings.demoMode else {
            visionEvents = []
            return
        }
        try? await printer.backend.clearVisionEvents()
        visionEvents = []
    }

    /// "The first layer looks fine" - resets the detector's baseline so it stops
    /// flagging the normal texture of this particular print.
    func confirmFirstLayerOK() async {
        guard !settings.demoMode else { return }
        do {
            try await printer.backend.confirmFirstLayerOK()
            vision = try await printer.backend.visionStatus()
            lastMessage = L.t("vision.first_layer.confirmed")
            Haptics.success()
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    /// URL for an event's saved frame (stored on the Pi, never uploaded anywhere).
    func eventImageURL(_ event: VisionEvent) -> URL? {
        mediaURL(event.snapshot)
    }

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

enum DemoMedia {
    static let camera = CameraStatus(
        available: true, source: "stream", url: "http://127.0.0.1:8080/?action=stream",
        devicePath: "/dev/video0", ffmpegAvailable: true, v4l2Available: true,
        devices: [
            CameraDeviceInfo(
                path: "/dev/video0", name: "USB 2.0 Camera", driver: "uvcvideo",
                bus: "usb-xhci-hcd.1-1", modes: [], recommended: nil
            )
        ],
        lastSnapshotAt: Date().timeIntervalSince1970 - 12, lastError: "",
        messageKey: "camera.status.ok"
    )

    static let recording = RecordingStatus(
        recording: false, videoID: nil, filename: "", startedAt: nil, elapsed: 0,
        mode: "manual", gcodeName: "", ffmpegAvailable: true, cameraAvailable: true,
        autoMode: "manual", lastError: ""
    )

    static let timelapse = TimelapseStatus(
        running: true, sessionID: "demo-tl", mode: "interval", frames: 218,
        startedAt: Date().timeIntervalSince1970 - 5_400,
        lastFrameAt: Date().timeIntervalSince1970 - 8,
        intervalSeconds: 20, configuredMode: "interval",
        ffmpegAvailable: true, cameraAvailable: true, lastError: ""
    )

    static let vision = VisionStatus(
        mode: "warn", running: true, provider: "heuristic", available: true, reason: "",
        intervalSeconds: 6, configuredInterval: 5, confirmationsRequired: 3, windowSeconds: 30,
        minConfidence: 0.55, framesAnalysed: 642,
        lastFrameAt: Date().timeIntervalSince1970 - 6, lastError: "",
        roi: [0.12, 0.18, 0.86, 0.92], cameraAvailable: true, canPause: true, neverCutsPower: true
    )

    static let videos: [VideoRecord] = [
        VideoRecord(
            id: "demo-video-1", kind: "timelapse", path: "videos/2026/05/18/phone_stand.mp4",
            filename: "phone_stand.mp4", itemID: "demo-stand", historyID: 41,
            gcodeName: "phone_stand_0.2_PLA.gcode",
            startedAt: Date().timeIntervalSince1970 - 90_000,
            finishedAt: Date().timeIntervalSince1970 - 84_000,
            duration: 24, sizeBytes: 8_412_336, result: "done",
            thumbnail: "thumbnails/demo-stand.png", frameCount: 412, error: ""
        ),
        VideoRecord(
            id: "demo-video-2", kind: "recording", path: "videos/2026/05/17/keychain.mp4",
            filename: "keychain.mp4", itemID: "demo-keychain", historyID: 40,
            gcodeName: "keychain_0.2_PLA.gcode",
            startedAt: Date().timeIntervalSince1970 - 180_000,
            finishedAt: Date().timeIntervalSince1970 - 179_100,
            duration: 900, sizeBytes: 41_882_112, result: "done",
            thumbnail: "thumbnails/demo-keychain.png", frameCount: nil, error: ""
        )
    ]

    static let storage = VideoStorageSummary(
        videosBytes: 41_882_112, timelapsesBytes: 8_412_336, snapshotsBytes: 1_204_992,
        totalBytes: 51_499_440, diskFreeBytes: 82_000_000_000, diskTotalBytes: 117_000_000_000,
        retentionPolicy: "keep_last", retentionMaxGB: 10, retentionKeepLast: 20
    )

    static let visionEvents: [VisionEvent] = [
        VisionEvent(
            id: "demo-vision-1", createdAt: Date().timeIntervalSince1970 - 3_600,
            kind: "spaghetti", confidence: 0.71, confirmed: true, action: "warned",
            snapshot: nil, gcodeName: "phone_stand_0.2_PLA.gcode", layer: 84, progress: 0.42,
            detail: "[heuristic] edge density +38% over 3 frames", acknowledged: false
        ),
        VisionEvent(
            id: "demo-vision-2", createdAt: Date().timeIntervalSince1970 - 7_200,
            kind: "no_motion", confidence: 0.58, confirmed: false, action: "none",
            snapshot: nil, gcodeName: "phone_stand_0.2_PLA.gcode", layer: 51, progress: 0.26,
            detail: "[heuristic] frame unchanged for 2 samples", acknowledged: true
        )
    ]

    static let macro = """
    # Suggested only - Neptune 3 Plus Remote never edits printer.cfg for you.
    [gcode_macro TIMELAPSE_TAKE_FRAME]
    gcode:
        {action_call_remote_method("timelapse_frame")}
    """
}
