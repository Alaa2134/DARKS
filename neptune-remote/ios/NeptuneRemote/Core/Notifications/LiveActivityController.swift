import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Starts, updates and ends the print Live Activity (lock screen + Dynamic Island).
///
/// Live Activities are a genuine iOS capability with genuine limits: they need
/// the user's permission, they are unavailable on some devices, and updates are
/// rate limited. When any of that applies the controller simply does nothing -
/// it never pretends an activity is running.
@MainActor
final class LiveActivityController: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var unavailableReason: String?

    /// Throttle: ActivityKit drops updates that arrive too fast, so only push
    /// when progress moved by ~1% or the state changed.
    private var lastPushedProgress: Double = -1
    private var lastPushedState: PrinterState = .unknown

    #if canImport(ActivityKit)
    private var activity: Activity<PrintActivityAttributes>?

    var isSupported: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func start(attributes: PrintActivityAttributes, state: PrintActivityAttributes.ContentState) {
        guard isSupported else {
            unavailableReason = L.t("live_activity.disabled")
            return
        }
        guard activity == nil else {
            update(state)
            return
        }
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(900)),
                pushType: nil
            )
            isRunning = true
            unavailableReason = nil
            lastPushedProgress = state.progress
            lastPushedState = state.state
        } catch {
            unavailableReason = error.localizedDescription
            isRunning = false
        }
    }

    func update(_ state: PrintActivityAttributes.ContentState) {
        guard let activity else { return }
        let progressMoved = abs(state.progress - lastPushedProgress) >= 0.01
        let stateChanged = state.state != lastPushedState
        let hasWarning = state.warningKey != nil
        guard progressMoved || stateChanged || hasWarning else { return }

        lastPushedProgress = state.progress
        lastPushedState = state.state
        Task {
            await activity.update(
                ActivityContent(state: state, staleDate: Date().addingTimeInterval(900))
            )
        }
    }

    func end(final state: PrintActivityAttributes.ContentState) {
        guard let activity else { return }
        self.activity = nil
        isRunning = false
        lastPushedProgress = -1
        lastPushedState = .unknown
        Task {
            await activity.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: .after(Date().addingTimeInterval(120))
            )
        }
    }

    /// Adopts an activity that survived an app restart.
    func reattach() {
        guard activity == nil else { return }
        activity = Activity<PrintActivityAttributes>.activities.first
        isRunning = activity != nil
    }
    #else
    var isSupported: Bool { false }
    func start(attributes: PrintActivityAttributes, state: PrintActivityAttributes.ContentState) {}
    func update(_ state: PrintActivityAttributes.ContentState) {}
    func end(final state: PrintActivityAttributes.ContentState) {}
    func reattach() {}
    #endif

    // MARK: - Driving it from the printer snapshot

    /// Called whenever a fresh snapshot arrives. Owns the whole lifecycle:
    /// starts on the first printing snapshot, ends when the print stops.
    func sync(
        snapshot: PrinterSnapshot,
        item: PrintingItemInfo?,
        thumbnailURL: URL?,
        printerName: String,
        warningKey: String?
    ) {
        let state = PrintActivityAttributes.ContentState(
            progress: snapshot.progress,
            state: snapshot.state,
            nozzleActual: snapshot.nozzleActual,
            nozzleTarget: snapshot.nozzleTarget,
            bedActual: snapshot.bedActual,
            bedTarget: snapshot.bedTarget,
            currentLayer: snapshot.currentLayer,
            totalLayer: snapshot.totalLayer,
            estimatedFinish: snapshot.estimatedFinishDate,
            warningKey: warningKey
        )

        guard snapshot.isActive else {
            if isRunning { end(final: state) }
            return
        }

        if isRunning {
            update(state)
        } else {
            start(
                attributes: PrintActivityAttributes(
                    printerName: printerName,
                    modelName: item?.displayName ?? "",
                    gcodeName: snapshot.filename,
                    thumbnailURL: thumbnailURL
                ),
                state: state
            )
        }
    }
}
