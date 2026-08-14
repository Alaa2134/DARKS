import XCTest
@testable import NeptuneRemote

/// The client half of orientation: what gets encoded, what gets sent, and when
/// the app decides a suggestion is worth showing.
final class PlacementTests: XCTestCase {

    // MARK: - The transform itself

    func testAFreshTransformIsIdentity() {
        XCTAssertTrue(ModelTransform.identity.isIdentity)
        XCTAssertEqual(ModelTransform.identity.uniformScale, 1)
    }

    func testAnyChangeStopsItBeingIdentity() {
        XCTAssertFalse(ModelTransform(rotationDeg: [90, 0, 0]).isIdentity)
        XCTAssertFalse(ModelTransform(scale: [2, 2, 2]).isIdentity)
        XCTAssertFalse(ModelTransform(mirror: [true, false, false]).isIdentity)
    }

    func testAStretchedModelHasNoUniformScale() {
        // The signal the UI needs to show three fields instead of one.
        XCTAssertNil(ModelTransform(scale: [2, 2, 1]).uniformScale)
        XCTAssertEqual(ModelTransform.uniform(1.5).uniformScale, 1.5)
    }

    func testTheTransformEncodesWithTheKeysTheBackendReads() throws {
        let data = try JSONEncoder().encode(
            ModelTransform(rotationDeg: [90, 0, 45], scale: [2, 2, 2], mirror: [true, false, false])
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        // Snake case, matching raspberry-pi/app/schemas.py. A silent mismatch
        // here means the Pi quietly slices an unturned model.
        XCTAssertEqual(json["rotation_deg"] as? [Double], [90, 0, 45])
        XCTAssertEqual(json["scale"] as? [Double], [2, 2, 2])
        XCTAssertEqual(json["mirror"] as? [Bool], [true, false, false])
        XCTAssertEqual(json["drop_to_bed"] as? Bool, true)
        XCTAssertEqual(json["center_on_bed"] as? Bool, true)
    }

    func testAReportDecodesFromTheBackendsShape() throws {
        let json = """
        {
          "base_area": 800.0,
          "overhang_area": 0.0,
          "height": 10.0,
          "width": 20.0,
          "depth": 40.0,
          "needs_support": false,
          "fits": true,
          "problems_ar": []
        }
        """.data(using: .utf8)!

        let report = try JSONDecoder().decode(OrientationReport.self, from: json)

        XCTAssertEqual(report.baseArea, 800)
        XCTAssertEqual(report.height, 10)
        XCTAssertFalse(report.needsSupport)
        XCTAssertTrue(report.fits)
    }

    // MARK: - Whether a suggestion is worth showing

    private func suggestion(
        currentOverhang: Double,
        suggestedOverhang: Double,
        currentBase: Double = 100,
        suggestedBase: Double = 100,
        currentFits: Bool = true,
        suggestedFits: Bool = true
    ) -> OrientationSuggestion {
        OrientationSuggestion(
            transform: ModelTransform(rotationDeg: [90, 0, 0]),
            suggested: OrientationReport(
                baseArea: suggestedBase, overhangArea: suggestedOverhang, fits: suggestedFits
            ),
            current: OrientationReport(
                baseArea: currentBase, overhangArea: currentOverhang, fits: currentFits
            )
        )
    }

    func testALargeReductionInSupportIsWorthApplying() {
        let result = suggestion(currentOverhang: 1000, suggestedOverhang: 100)

        XCTAssertEqual(result.overhangReduction ?? 0, 0.9, accuracy: 0.001)
        XCTAssertTrue(result.isWorthApplying)
    }

    func testATinyReductionIsNotWorthTurningTheModelFor() {
        // Turning a model has a cost - the user has to think about it - so a
        // 2% improvement is not an improvement worth offering.
        let result = suggestion(currentOverhang: 1000, suggestedOverhang: 980)

        XCTAssertFalse(result.isWorthApplying)
    }

    func testAModelThatAlreadyNeedsNoSupportFallsBackToComparingBases() {
        // With no support either way there is no reduction to compute, and
        // reporting one would be inventing a number.
        let noBetter = suggestion(
            currentOverhang: 0, suggestedOverhang: 0,
            currentBase: 100, suggestedBase: 105
        )
        let muchBetter = suggestion(
            currentOverhang: 0, suggestedOverhang: 0,
            currentBase: 100, suggestedBase: 400
        )

        XCTAssertNil(noBetter.overhangReduction)
        XCTAssertFalse(noBetter.isWorthApplying)
        XCTAssertTrue(muchBetter.isWorthApplying)
    }

    func testAnOrientationThatMakesTheModelFitIsAlwaysWorthApplying() {
        // Fitting the machine beats every other consideration: the alternative
        // is not printing at all.
        let result = suggestion(
            currentOverhang: 0, suggestedOverhang: 500,
            currentFits: false, suggestedFits: true
        )

        XCTAssertTrue(result.isWorthApplying)
    }

    func testReductionNeverGoesNegativeWhenTheSuggestionIsWorse() {
        let result = suggestion(currentOverhang: 100, suggestedOverhang: 500)

        XCTAssertEqual(result.overhangReduction, 0)
        XCTAssertFalse(result.isWorthApplying)
    }

    // MARK: - What gets sent with a slice

    @MainActor
    func testOnlyMovedModelsAreSentWithTheSliceRequest() {
        let store = PlacementStore(
            settings: AppSettings(),
            printer: PrinterStore(settings: AppSettings(), notifications: NotificationManager())
        )
        store.set(ModelTransform(rotationDeg: [90, 0, 0]), for: "turned", measure: false)
        store.set(.identity, for: "untouched", measure: false)

        let payload = store.payload(for: ["turned", "untouched", "never-seen"])

        // An identity transform would make the Pi write a pointless copy of an
        // unturned mesh, so it is left out entirely.
        XCTAssertEqual(Set(payload.keys), ["turned"])
    }

    @MainActor
    func testRotatingWrapsInsteadOfGrowingWithoutBound() {
        let store = PlacementStore(
            settings: AppSettings(),
            printer: PrinterStore(settings: AppSettings(), notifications: NotificationManager())
        )

        for _ in 0..<5 { store.rotate("m", byDegrees: 90, axis: 2) }

        // Five right angles is one right angle, not 450 degrees - a dial that
        // has been spun should still read as an angle.
        XCTAssertEqual(store.transform(for: "m").rotationDeg[2], 90, accuracy: 0.001)
    }

    @MainActor
    func testRotatingBackwardsStaysPositive() {
        let store = PlacementStore(
            settings: AppSettings(),
            printer: PrinterStore(settings: AppSettings(), notifications: NotificationManager())
        )

        store.rotate("m", byDegrees: -90, axis: 0)

        XCTAssertEqual(store.transform(for: "m").rotationDeg[0], 270, accuracy: 0.001)
    }

    @MainActor
    func testResettingClearsTheTransformEntirely() {
        let store = PlacementStore(
            settings: AppSettings(),
            printer: PrinterStore(settings: AppSettings(), notifications: NotificationManager())
        )
        store.set(ModelTransform(scale: [3, 3, 3]), for: "m", measure: false)
        XCTAssertTrue(store.isPlaced("m"))

        store.reset("m")

        XCTAssertFalse(store.isPlaced("m"))
        XCTAssertTrue(store.transform(for: "m").isIdentity)
    }

    @MainActor
    func testAZeroScaleIsIgnoredRatherThanStored() {
        let store = PlacementStore(
            settings: AppSettings(),
            printer: PrinterStore(settings: AppSettings(), notifications: NotificationManager())
        )

        store.setUniformScale(0, for: "m")

        // A zero scale is a model with no size. The backend refuses it too, but
        // it should never get that far.
        XCTAssertTrue(store.transform(for: "m").isIdentity)
    }

    @MainActor
    func testMirroringTogglesRatherThanAccumulates() {
        let store = PlacementStore(
            settings: AppSettings(),
            printer: PrinterStore(settings: AppSettings(), notifications: NotificationManager())
        )

        store.toggleMirror("m", axis: 0)
        XCTAssertEqual(store.transform(for: "m").mirror, [true, false, false])

        store.toggleMirror("m", axis: 0)
        XCTAssertEqual(store.transform(for: "m").mirror, [false, false, false])
        XCTAssertTrue(store.transform(for: "m").isIdentity)
    }

    @MainActor
    func testTurningAModelByHandDiscardsAdviceAboutTheOldOrientation() {
        let store = PlacementStore(
            settings: AppSettings(),
            printer: PrinterStore(settings: AppSettings(), notifications: NotificationManager())
        )
        store.set(ModelTransform(rotationDeg: [45, 0, 0]), for: "m", measure: false)

        // Advice about a different orientation is not advice.
        XCTAssertNil(store.suggestion(for: "m"))
    }

    func testTheSliceRequestCarriesTransformsUnderTheKeyTheBackendReads() throws {
        var payload = SliceRequestPayload(modelID: "abc")
        payload.transforms = ["abc": ModelTransform(rotationDeg: [0, 90, 0])]

        let data = try JSONEncoder().encode(payload)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let transforms = try XCTUnwrap(json["transforms"] as? [String: Any])
        let entry = try XCTUnwrap(transforms["abc"] as? [String: Any])

        XCTAssertEqual(entry["rotation_deg"] as? [Double], [0, 90, 0])
    }
}
