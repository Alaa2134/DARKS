import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Live Activity payload, compiled into both the app and the widget extension.
///
/// Kept small on purpose: a Live Activity update is pushed on every meaningful
/// progress change, and ActivityKit budgets both size and frequency.
public struct PrintActivityAttributes: Codable, Hashable, Sendable {
    /// Fixed for the lifetime of the activity.
    public let printerName: String
    public let modelName: String
    public let gcodeName: String
    /// Absolute URL of the model preview, if the Pi rendered one.
    public let thumbnailURL: URL?

    public init(printerName: String, modelName: String, gcodeName: String, thumbnailURL: URL?) {
        self.printerName = printerName
        self.modelName = modelName
        self.gcodeName = gcodeName
        self.thumbnailURL = thumbnailURL
    }

    /// What actually changes while the print runs.
    public struct ContentState: Codable, Hashable, Sendable {
        public var progress: Double
        public var state: PrinterState
        public var nozzleActual: Double
        public var nozzleTarget: Double
        public var bedActual: Double
        public var bedTarget: Double
        public var currentLayer: Int?
        public var totalLayer: Int?
        public var estimatedFinish: Date?
        /// Set when the local monitor has flagged something the user should see.
        public var warningKey: String?

        public init(
            progress: Double,
            state: PrinterState,
            nozzleActual: Double = 0,
            nozzleTarget: Double = 0,
            bedActual: Double = 0,
            bedTarget: Double = 0,
            currentLayer: Int? = nil,
            totalLayer: Int? = nil,
            estimatedFinish: Date? = nil,
            warningKey: String? = nil
        ) {
            self.progress = progress
            self.state = state
            self.nozzleActual = nozzleActual
            self.nozzleTarget = nozzleTarget
            self.bedActual = bedActual
            self.bedTarget = bedTarget
            self.currentLayer = currentLayer
            self.totalLayer = totalLayer
            self.estimatedFinish = estimatedFinish
            self.warningKey = warningKey
        }

        public var layerText: String? {
            guard let currentLayer else { return nil }
            if let totalLayer, totalLayer > 0 { return "\(currentLayer)/\(totalLayer)" }
            return "\(currentLayer)"
        }
    }
}

#if canImport(ActivityKit)
extension PrintActivityAttributes: ActivityAttributes {}
#endif
