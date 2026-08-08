import Foundation

// MARK: - Camera

struct CameraMode: Decodable, Equatable, Hashable {
    let width: Int
    let height: Int
    let fps: Double
    let label: String
    let pixelFormat: String?

    enum CodingKeys: String, CodingKey {
        case width, height, fps, label
        case pixelFormat = "pixel_format"
    }
}

struct CameraDeviceInfo: Decodable, Equatable, Hashable, Identifiable {
    let path: String
    let name: String
    let driver: String
    let bus: String
    let modes: [CameraMode]
    let recommended: CameraMode?

    var id: String { path }
}

struct CameraStatus: Decodable, Equatable {
    let available: Bool
    let source: String            // stream | device | none
    let url: String
    let devicePath: String
    let ffmpegAvailable: Bool
    let v4l2Available: Bool
    let devices: [CameraDeviceInfo]
    let lastSnapshotAt: Double?
    let lastError: String
    let messageKey: String

    enum CodingKeys: String, CodingKey {
        case available, source, url, devices
        case devicePath = "device_path"
        case ffmpegAvailable = "ffmpeg_available"
        case v4l2Available = "v4l2_available"
        case lastSnapshotAt = "last_snapshot_at"
        case lastError = "last_error"
        case messageKey = "message_key"
    }

    static let unknown = CameraStatus(
        available: false, source: "none", url: "", devicePath: "",
        ffmpegAvailable: false, v4l2Available: false, devices: [],
        lastSnapshotAt: nil, lastError: "", messageKey: "camera.status.no_camera"
    )
}

// MARK: - Recording

struct RecordingStatus: Decodable, Equatable {
    let recording: Bool
    let videoID: String?
    let filename: String
    let startedAt: Double?
    let elapsed: Double
    let mode: String
    let gcodeName: String
    let ffmpegAvailable: Bool
    let cameraAvailable: Bool
    let autoMode: String
    let lastError: String

    enum CodingKeys: String, CodingKey {
        case recording, filename, elapsed, mode
        case videoID = "video_id"
        case startedAt = "started_at"
        case gcodeName = "gcode_name"
        case ffmpegAvailable = "ffmpeg_available"
        case cameraAvailable = "camera_available"
        case autoMode = "auto_mode"
        case lastError = "last_error"
    }

    static let idle = RecordingStatus(
        recording: false, videoID: nil, filename: "", startedAt: nil, elapsed: 0,
        mode: "manual", gcodeName: "", ffmpegAvailable: false, cameraAvailable: false,
        autoMode: "manual", lastError: ""
    )
}

struct TimelapseStatus: Decodable, Equatable {
    let running: Bool
    let sessionID: String?
    let mode: String
    let frames: Int
    let startedAt: Double?
    let lastFrameAt: Double?
    let intervalSeconds: Int
    let configuredMode: String
    let ffmpegAvailable: Bool
    let cameraAvailable: Bool
    let lastError: String

    enum CodingKeys: String, CodingKey {
        case running, mode, frames
        case sessionID = "session_id"
        case startedAt = "started_at"
        case lastFrameAt = "last_frame_at"
        case intervalSeconds = "interval_seconds"
        case configuredMode = "configured_mode"
        case ffmpegAvailable = "ffmpeg_available"
        case cameraAvailable = "camera_available"
        case lastError = "last_error"
    }

    static let idle = TimelapseStatus(
        running: false, sessionID: nil, mode: "off", frames: 0, startedAt: nil,
        lastFrameAt: nil, intervalSeconds: 10, configuredMode: "off",
        ffmpegAvailable: false, cameraAvailable: false, lastError: ""
    )
}

struct VideoRecord: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let kind: String              // recording | timelapse
    let path: String
    let filename: String
    let itemID: String?
    let historyID: Int?
    let gcodeName: String
    let startedAt: Double
    let finishedAt: Double?
    let duration: Double?
    let sizeBytes: Int
    let result: String
    let thumbnail: String?
    let frameCount: Int?
    let error: String

    var isTimelapse: Bool { kind == "timelapse" }
    var isFinished: Bool { result != "in_progress" }

    enum CodingKeys: String, CodingKey {
        case id, kind, path, filename, duration, result, thumbnail, error
        case itemID = "item_id"
        case historyID = "history_id"
        case gcodeName = "gcode_name"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case sizeBytes = "size_bytes"
        case frameCount = "frame_count"
    }
}

struct VideoStorageSummary: Decodable, Equatable {
    let videosBytes: Double
    let timelapsesBytes: Double
    let snapshotsBytes: Double
    let totalBytes: Double
    let diskFreeBytes: Double
    let diskTotalBytes: Double
    let retentionPolicy: String
    let retentionMaxGB: Double
    let retentionKeepLast: Int

    enum CodingKeys: String, CodingKey {
        case videosBytes = "videos_bytes"
        case timelapsesBytes = "timelapses_bytes"
        case snapshotsBytes = "snapshots_bytes"
        case totalBytes = "total_bytes"
        case diskFreeBytes = "disk_free_bytes"
        case diskTotalBytes = "disk_total_bytes"
        case retentionPolicy = "retention_policy"
        case retentionMaxGB = "retention_max_gb"
        case retentionKeepLast = "retention_keep_last"
    }
}

// MARK: - Vision

struct VisionStatus: Decodable, Equatable {
    let mode: String              // off | monitor | warn | auto_pause
    let running: Bool
    let provider: String          // heuristic | onnx | disabled
    let available: Bool
    let reason: String
    let intervalSeconds: Double
    let configuredInterval: Double
    let confirmationsRequired: Int
    let windowSeconds: Double
    let minConfidence: Double
    let framesAnalysed: Int
    let lastFrameAt: Double?
    let lastError: String
    let roi: [Double]?
    let cameraAvailable: Bool
    let canPause: Bool
    let neverCutsPower: Bool

    /// True when the monitor is running without a trained model.
    var isHeuristic: Bool { provider == "heuristic" }

    enum CodingKeys: String, CodingKey {
        case mode, running, provider, available, reason, roi
        case intervalSeconds = "interval_seconds"
        case configuredInterval = "configured_interval"
        case confirmationsRequired = "confirmations_required"
        case windowSeconds = "window_seconds"
        case minConfidence = "min_confidence"
        case framesAnalysed = "frames_analysed"
        case lastFrameAt = "last_frame_at"
        case lastError = "last_error"
        case cameraAvailable = "camera_available"
        case canPause = "can_pause"
        case neverCutsPower = "never_cuts_power"
    }

    static let unknown = VisionStatus(
        mode: "off", running: false, provider: "disabled", available: false, reason: "",
        intervalSeconds: 5, configuredInterval: 5, confirmationsRequired: 3, windowSeconds: 30,
        minConfidence: 0.55, framesAnalysed: 0, lastFrameAt: nil, lastError: "", roi: nil,
        cameraAvailable: false, canPause: false, neverCutsPower: true
    )
}

struct VisionEvent: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let createdAt: Double
    let kind: String
    let confidence: Double
    let confirmed: Bool
    let action: String
    let snapshot: String?
    let gcodeName: String
    let layer: Int?
    let progress: Double?
    let detail: String
    let acknowledged: Bool

    var localizationKey: String { "vision.kind.\(kind)" }
    var isHeuristic: Bool { detail.contains("[heuristic]") }

    enum CodingKeys: String, CodingKey {
        case id, kind, confidence, confirmed, action, snapshot, layer, progress, detail, acknowledged
        case createdAt = "created_at"
        case gcodeName = "gcode_name"
    }
}

struct VisionSettingsPayload: Encodable {
    var mode: String?
    var provider: String?
    var intervalSeconds: Double?
    var minConfidence: Double?
    var confirmations: Int?
    var roi: [Double]?

    enum CodingKeys: String, CodingKey {
        case mode, provider, confirmations, roi
        case intervalSeconds = "interval_seconds"
        case minConfidence = "min_confidence"
    }
}

enum VisionMode: String, CaseIterable, Identifiable {
    case off, monitor, warn, autoPause = "auto_pause"

    var id: String { rawValue }
    var localizationKey: String { "vision.mode.\(rawValue)" }

    var systemImage: String {
        switch self {
        case .off: return "eye.slash"
        case .monitor: return "eye"
        case .warn: return "exclamationmark.bubble"
        case .autoPause: return "pause.circle"
        }
    }
}
