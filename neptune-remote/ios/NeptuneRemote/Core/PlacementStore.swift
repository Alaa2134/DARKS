import Foundation
import SwiftUI

/// How each model is turned and sized before it is sliced.
///
/// The library used to hand a model to the slicer exactly as it was exported,
/// which means a model exported lying on its side got sliced lying on its side.
/// Orientation decides which faces need support, how tall the print stands,
/// which way the layer lines run and therefore where the part snaps - so it is
/// the first decision, not a detail.
///
/// Nothing here modifies a file. A transform travels with the slice request and
/// the Pi writes a turned copy for the slicer to read, which is what makes any
/// of this reversible.
@MainActor
final class PlacementStore: ObservableObject {

    /// The transform per model id. A model missing from here is unturned.
    @Published private(set) var transforms: [String: ModelTransform] = [:]

    /// The measurements for what the user is currently looking at, per model.
    @Published private(set) var reports: [String: OrientationReport] = [:]

    /// The Pi's advice, once asked for. Cleared when the model is turned by
    /// hand, because advice about a different orientation is not advice.
    @Published private(set) var suggestions: [String: OrientationSuggestion] = [:]

    /// What is wrong with each model, per id. Checked once when the placement
    /// screen opens, because that is the moment before the slice - and the
    /// last moment a warning is still cheap.
    @Published private(set) var health: [String: MeshHealth] = [:]

    @Published private(set) var isMeasuring = false
    @Published private(set) var isSuggesting = false
    @Published private(set) var isChecking = false
    @Published private(set) var isRepairing = false
    /// Set when a repair produced a new model, so the screen can offer to use
    /// it. The original is never replaced.
    @Published var repairResult: MeshRepairResult?
    @Published var lastError: APIError?

    private let settings: AppSettings
    private let printer: PrinterStore

    /// The measurement in flight, so dragging a dial does not queue up fifty
    /// requests that all arrive out of order.
    private var measureTask: Task<Void, Never>?

    init(settings: AppSettings, printer: PrinterStore) {
        self.settings = settings
        self.printer = printer
    }

    private var backend: BackendClient { printer.backend }

    // MARK: - Reading

    func transform(for modelID: String) -> ModelTransform {
        transforms[modelID] ?? .identity
    }

    func report(for modelID: String) -> OrientationReport? {
        reports[modelID]
    }

    func suggestion(for modelID: String) -> OrientationSuggestion? {
        suggestions[modelID]
    }

    /// Whether this model has been turned or resized from how it arrived.
    func isPlaced(_ modelID: String) -> Bool {
        !transform(for: modelID).isIdentity
    }

    /// Transforms for a plate, ready to attach to a slice request. Identity
    /// transforms are left out - sending them would make the Pi write a
    /// pointless copy of every unturned model.
    func payload(for modelIDs: [String]) -> [String: ModelTransform] {
        var result: [String: ModelTransform] = [:]
        for identifier in modelIDs {
            let placement = transform(for: identifier)
            if !placement.isIdentity { result[identifier] = placement }
        }
        return result
    }

    // MARK: - Changing

    /// Where a model sits on the bed, in mm from the bed centre.
    ///
    /// Not measured afterwards: moving a part across the plate changes nothing
    /// about its height, its footprint or whether it needs support, and a
    /// request to the Pi per frame of a drag is not a drag.
    func setPosition(_ point: CGPoint, for modelID: String) {
        var placement = transform(for: modelID)
        placement.position = point
        transforms[modelID] = placement
    }

    /// Every transform for a plate, position included, whether or not it is
    /// otherwise identity.
    ///
    /// `payload(for:)` drops identity transforms because the slicer does not
    /// need them. The arrangement does: a part sitting at the origin unturned
    /// still has to be in the list, or the plate loses a model.
    func platePayload(for modelIDs: [String]) -> [String: ModelTransform] {
        var result: [String: ModelTransform] = [:]
        for identifier in modelIDs {
            result[identifier] = transform(for: identifier)
        }
        return result
    }

    /// Set the transform and measure what it did.
    ///
    /// Measuring is debounced and single-flighted: a rotation dial produces a
    /// value every frame, and each one is a request to the Pi that has to load
    /// and turn the whole mesh.
    func set(_ placement: ModelTransform, for modelID: String, measure: Bool = true) {
        transforms[modelID] = placement
        // Advice about the previous orientation is not advice about this one.
        suggestions[modelID] = nil
        guard measure else { return }
        scheduleMeasure(modelID)
    }

    func rotate(_ modelID: String, byDegrees degrees: Double, axis: Int) {
        guard (0...2).contains(axis) else { return }
        var placement = transform(for: modelID)
        var rotation = placement.rotationDeg
        guard rotation.count == 3 else { return }
        // Kept in 0..<360 so a dial that has been spun ten times still reads as
        // an angle rather than as 3600 degrees.
        rotation[axis] = (rotation[axis] + degrees).truncatingRemainder(dividingBy: 360)
        if rotation[axis] < 0 { rotation[axis] += 360 }
        placement.rotationDeg = rotation
        set(placement, for: modelID)
    }

    func setUniformScale(_ factor: Double, for modelID: String) {
        guard factor > 0 else { return }
        var placement = transform(for: modelID)
        placement.scale = [factor, factor, factor]
        set(placement, for: modelID)
    }

    func toggleMirror(_ modelID: String, axis: Int) {
        guard (0...2).contains(axis) else { return }
        var placement = transform(for: modelID)
        var mirror = placement.mirror
        guard mirror.count == 3 else { return }
        mirror[axis].toggle()
        placement.mirror = mirror
        set(placement, for: modelID)
    }

    func reset(_ modelID: String) {
        transforms[modelID] = nil
        suggestions[modelID] = nil
        scheduleMeasure(modelID)
    }

    // MARK: - Measuring

    private func scheduleMeasure(_ modelID: String) {
        measureTask?.cancel()
        measureTask = Task { [weak self] in
            // Long enough that a drag produces one request at the end of it,
            // short enough that it still feels like it answered immediately.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await self?.measure(modelID)
        }
    }

    // MARK: - Mesh health

    /// Check a model, quietly. Failures are swallowed: this is advice offered
    /// alongside the real task, and an error banner for a check the user did
    /// not ask for would be noise in front of the thing they did.
    func checkHealth(_ modelID: String) async {
        guard health[modelID] == nil else { return }
        isChecking = true
        defer { isChecking = false }
        if let result = try? await printer.backend.meshHealth(id: modelID) {
            health[modelID] = result
        }
    }

    /// Repair a model into a new library item. The original is kept.
    @discardableResult
    func repair(_ modelID: String) async -> String? {
        isRepairing = true
        defer { isRepairing = false }
        do {
            let result = try await printer.backend.repairMesh(id: modelID)
            repairResult = result
            // The repaired copy is a different model, so the old verdict no
            // longer describes anything on screen.
            health[modelID] = result.after
            Haptics.success()
            return result.repairedModelID.isEmpty ? nil : result.repairedModelID
        } catch {
            lastError = APIError.from(error, host: settings.host)
            Haptics.error()
            return nil
        }
    }

    func measure(_ modelID: String) async {
        guard !settings.demoMode else {
            reports[modelID] = Self.demoReport(for: transform(for: modelID))
            return
        }
        isMeasuring = true
        defer { isMeasuring = false }
        do {
            let report = try await backend.measureTransform(
                id: modelID, transform: transform(for: modelID)
            )
            guard !Task.isCancelled else { return }
            reports[modelID] = report
            lastError = nil
        } catch is CancellationError {
            return
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    // MARK: - Advice

    /// Ask the Pi for the way up that needs the least support.
    ///
    /// The answer includes the measurements for the current orientation as
    /// well, so the app can show what the change buys instead of asking the
    /// user to take it on trust - and so it can say "it is already the best way
    /// up" when that is the truth.
    @discardableResult
    func suggestOrientation(for modelID: String) async -> OrientationSuggestion? {
        guard !settings.demoMode else {
            let suggestion = Self.demoSuggestion(for: transform(for: modelID))
            suggestions[modelID] = suggestion
            return suggestion
        }
        isSuggesting = true
        defer { isSuggesting = false }
        do {
            let suggestion = try await backend.suggestOrientation(
                id: modelID, transform: transform(for: modelID)
            )
            suggestions[modelID] = suggestion
            reports[modelID] = suggestion.current
            lastError = nil
            return suggestion
        } catch {
            lastError = APIError.from(error, host: settings.host)
            return nil
        }
    }

    /// Take the advice. Separate from asking for it, because turning a model is
    /// a decision and the suggestion is only ever advice.
    func applySuggestion(for modelID: String) {
        guard let suggestion = suggestions[modelID] else { return }
        transforms[modelID] = suggestion.transform
        reports[modelID] = suggestion.suggested
        suggestions[modelID] = nil
        Haptics.success()
    }

    // MARK: - Demo

    /// Demo mode answers from the transform alone. It cannot measure a mesh it
    /// does not have, so it reports the sizes it can derive and nothing it
    /// cannot - an invented overhang area would be a number that looks measured.
    private static func demoReport(for placement: ModelTransform) -> OrientationReport {
        let base = (60.0, 40.0, 90.0)
        let scale = placement.uniformScale ?? 1
        let rotation = placement.rotationDeg
        let turnedOnX = abs(rotation.first ?? 0).truncatingRemainder(dividingBy: 180) > 45

        let width = base.0 * scale
        let depth = (turnedOnX ? base.2 : base.1) * scale
        let height = (turnedOnX ? base.1 : base.2) * scale

        return OrientationReport(
            baseArea: width * depth,
            overhangArea: turnedOnX ? 0 : 420,
            height: height,
            width: width,
            depth: depth,
            needsSupport: !turnedOnX,
            fits: width <= 320 && depth <= 320 && height <= 400,
            problemsAr: height > 400 ? ["الارتفاع أكبر من ٤٠٠ مم."] : []
        )
    }

    private static func demoSuggestion(for placement: ModelTransform) -> OrientationSuggestion {
        var lying = placement
        lying.rotationDeg = [90, 0, 0]
        return OrientationSuggestion(
            transform: lying,
            suggested: demoReport(for: lying),
            current: demoReport(for: placement)
        )
    }
}
