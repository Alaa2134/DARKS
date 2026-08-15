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

/// The startup narrator's own logic. Pure, so it is tested directly rather than
/// through a live socket.
final class StartupStageTests: XCTestCase {

    func testTheStepsAreInTheOrderTheyActuallyHappen() {
        XCTAssertEqual(PrinterStore.StartupStage.reachingPi.step, 1)
        XCTAssertEqual(PrinterStore.StartupStage.reachingPrinter.step, 2)
        XCTAssertEqual(PrinterStore.StartupStage.waitingForKlipper.step, 3)
        XCTAssertEqual(PrinterStore.StartupStage.readingConfig.step, 4)
    }

    func testReadyIsTheLastStepRatherThanAFifth() {
        // The bar has to be full when the app is usable, not one notch short.
        XCTAssertEqual(
            PrinterStore.StartupStage.ready.step,
            PrinterStore.StartupStage.totalSteps
        )
    }

    func testAFailureIsNotPlacedOnTheProgressBarAtAll() {
        // Offline is not "step zero of four" - it is not on the sequence at
        // all. A failure shown as progress reads as something still happening.
        XCTAssertEqual(PrinterStore.StartupStage.offline.step, 0)
        XCTAssertEqual(PrinterStore.StartupStage.authenticationFailed.step, 0)
    }

    func testOnlyTheEndStatesAreSettled() {
        XCTAssertTrue(PrinterStore.StartupStage.ready.isSettled)
        XCTAssertTrue(PrinterStore.StartupStage.offline.isSettled)
        XCTAssertTrue(PrinterStore.StartupStage.authenticationFailed.isSettled)

        // These four are still moving, so the card keeps its spinner.
        XCTAssertFalse(PrinterStore.StartupStage.reachingPi.isSettled)
        XCTAssertFalse(PrinterStore.StartupStage.reachingPrinter.isSettled)
        XCTAssertFalse(PrinterStore.StartupStage.waitingForKlipper.isSettled)
        XCTAssertFalse(PrinterStore.StartupStage.readingConfig.isSettled)
    }

    func testEveryStageNamesAStringTheAppCanShow() {
        let stages: [PrinterStore.StartupStage] = [
            .reachingPi, .reachingPrinter, .waitingForKlipper,
            .readingConfig, .ready, .authenticationFailed, .offline
        ]
        for stage in stages {
            XCTAssertFalse(stage.localizationKey.isEmpty)
            // A key that resolves to itself is a key with no translation.
            XCTAssertNotEqual(L.t(stage.localizationKey), stage.localizationKey)
        }
    }

    @MainActor
    func testDemoModeIsAlwaysReady() {
        let settings = AppSettings()
        settings.demoMode = true
        let store = PrinterStore(settings: settings, notifications: NotificationManager())

        XCTAssertEqual(store.startupStage, .ready)
    }
}

/// Decoding a layer, and the geometry the canvas draws from it.
final class ToolpathPreviewTests: XCTestCase {

    func testASegmentDecodesWithTheBackendsKeys() throws {
        let json = """
        {"feature": "outer_wall", "points": [10.0, 10.0, 40.0, 10.0, 40.0, 30.0]}
        """.data(using: .utf8)!

        let segment = try JSONDecoder().decode(PreviewSegment.self, from: json)

        XCTAssertEqual(segment.feature, .outerWall)
        XCTAssertEqual(segment.coordinates.count, 3)
        XCTAssertEqual(segment.coordinates.last, CGPoint(x: 40, y: 30))
    }

    func testAnUnknownFeatureNameDecodesRatherThanFailing() throws {
        // A newer backend talking to an older app. Drawing the geometry as
        // unclassified beats dropping the whole layer.
        let json = """
        {"feature": "quantum_wall", "points": [0, 0, 1, 1]}
        """.data(using: .utf8)!

        let segment = try JSONDecoder().decode(PreviewSegment.self, from: json)

        XCTAssertEqual(segment.feature, .unknown)
        // Four values is two points, and the geometry survives the unknown name.
        XCTAssertEqual(segment.coordinates.count, 2)
    }

    func testAnOddPointCountDropsTheStrayValueInsteadOfCrashing() {
        // Five numbers is two points and a leftover. Reading past the end of
        // the array to pair it would be a crash in a view.
        let segment = PreviewSegment(feature: .infill, points: [0, 0, 1, 1, 2])

        XCTAssertEqual(segment.coordinates, [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)])
    }

    func testAnEmptySegmentHasNoCoordinates() {
        XCTAssertTrue(PreviewSegment(feature: .travel, points: []).coordinates.isEmpty)
        XCTAssertTrue(PreviewSegment(feature: .travel, points: [5]).coordinates.isEmpty)
    }

    func testTheSummaryDecodesFromTheBackendsShape() throws {
        let json = """
        {
          "filename": "part.gcode",
          "layer_count": 3,
          "layer_heights": [0.2, 0.4, null],
          "bounds": {"min_x": 10.0, "min_y": 5.0, "max_x": 40.0, "max_y": 35.0},
          "color_change_layers": [2]
        }
        """.data(using: .utf8)!

        let summary = try JSONDecoder().decode(PreviewSummary.self, from: json)

        XCTAssertEqual(summary.layerCount, 3)
        XCTAssertEqual(summary.height(at: 0), 0.2)
        // Cura writes no ;Z:, so a height can genuinely be unknown.
        XCTAssertNil(summary.height(at: 2))
        XCTAssertNil(summary.height(at: 99))
        XCTAssertEqual(summary.bounds.width, 30)
        XCTAssertEqual(summary.bounds.height, 30)
        XCTAssertEqual(summary.colorChangeLayers, [2])
    }

    func testEmptyBoundsAreRecognisedSoTheCanvasDoesNotDivideByZero() {
        XCTAssertTrue(PreviewBounds().isEmpty)
        XCTAssertTrue(PreviewBounds(minX: 5, minY: 5, maxX: 5, maxY: 20).isEmpty)
        XCTAssertFalse(PreviewBounds(minX: 0, minY: 0, maxX: 10, maxY: 10).isEmpty)
    }

    func testOnlyTheFeaturesActuallyPresentAreListedForTheLegend() {
        let layer = PreviewLayer(
            index: 0,
            z: 0.2,
            segments: [
                PreviewSegment(feature: .infill, points: [0, 0, 1, 1]),
                PreviewSegment(feature: .outerWall, points: [0, 0, 1, 1]),
                PreviewSegment(feature: .outerWall, points: [2, 2, 3, 3])
            ]
        )

        // Listed once each, and in the drawing order rather than the order they
        // happened to arrive - a legend that reshuffles between layers is one
        // nobody can use.
        XCTAssertEqual(layer.featuresPresent, [.infill, .outerWall])
        XCTAssertEqual(layer.segments(for: .outerWall).count, 2)
        XCTAssertTrue(layer.segments(for: .support).isEmpty)
    }

    func testTravelIsTheOnlyNonExtrudingFeature() {
        for feature in ToolpathFeature.allCases where feature != .travel {
            XCTAssertTrue(feature.isExtruding, "\(feature.rawValue) should extrude")
        }
        XCTAssertFalse(ToolpathFeature.travel.isExtruding)
    }

    func testEveryFeatureHasATranslatedName() {
        for feature in ToolpathFeature.allCases {
            let key = feature.localizationKey
            XCTAssertNotEqual(L.t(key), key, "missing translation for \(key)")
        }
    }
}

/// Mesh health: what counts as serious, and what the app promises to fix.
final class MeshHealthTests: XCTestCase {

    func testHealthDecodesFromTheBackendsShape() throws {
        let json = """
        {
          "triangle_count": 12, "degenerate": 0, "open_edges": 3,
          "overlapping_edges": 0, "total_edges": 18, "shells": 1,
          "flipped": 2, "inside_out": false, "watertight": false,
          "clean": false, "probably_not_a_solid": false,
          "summary_ar": ["فيه 3 ضلع مفتوح"], "repairable": true
        }
        """.data(using: .utf8)!

        let health = try JSONDecoder().decode(MeshHealth.self, from: json)

        XCTAssertEqual(health.openEdges, 3)
        XCTAssertEqual(health.flipped, 2)
        XCTAssertFalse(health.clean)
        XCTAssertTrue(health.repairable)
    }

    func testAFewHolesIsNotSerious() {
        // A model with small holes slices fine - slicers close them per layer.
        // Raising an alarm for it would train the user to ignore alarms.
        let health = MeshHealth(openEdges: 3, totalEdges: 18, watertight: false, clean: false)

        XCTAssertFalse(health.isSerious)
    }

    func testNotBeingASolidIsSerious() {
        let health = MeshHealth(
            openEdges: 3, totalEdges: 3, watertight: false, clean: false,
            probablyNotASolid: true
        )

        XCTAssertTrue(health.isSerious)
    }

    func testAnInsideOutModelIsSerious() {
        // A slicer given this prints the negative of the part.
        XCTAssertTrue(MeshHealth(insideOut: true, clean: false).isSerious)
    }

    func testFusedShellsAreSerious() {
        // An edge shared by three faces means the slicer cannot tell inside
        // from outside.
        XCTAssertTrue(MeshHealth(overlappingEdges: 4, watertight: false, clean: false).isSerious)
    }

    func testARepairThatChangedNothingIsNotReportedAsAChange() {
        let result = MeshRepairResult(ok: true)

        XCTAssertFalse(result.changed)
        XCTAssertTrue(result.repairedModelID.isEmpty)
    }

    func testARepairThatRemovedOrTurnedSomethingCounts() {
        XCTAssertTrue(MeshRepairResult(ok: true, removedTriangles: 3).changed)
        XCTAssertTrue(MeshRepairResult(ok: true, reoriented: true).changed)
    }
}

/// The plate: what gets sent, and how a position round-trips.
final class PlateArrangementTests: XCTestCase {

    func testAPositionRoundTripsThroughTheTransform() {
        var placement = ModelTransform()
        placement.position = CGPoint(x: 40, y: -25)

        XCTAssertEqual(placement.offsetXY, [40, -25])
        XCTAssertEqual(placement.position, CGPoint(x: 40, y: -25))
    }

    func testAPlacedModelIsNotIdentity() {
        // The offset is what tells the Pi the user placed these themselves, so
        // it must survive the identity check that decides what gets sent.
        var placement = ModelTransform()
        placement.position = CGPoint(x: 10, y: 0)

        XCTAssertFalse(placement.isIdentity)
    }

    func testAModelAtTheOriginIsStillIdentity() {
        XCTAssertTrue(ModelTransform().isIdentity)
        XCTAssertEqual(ModelTransform().position, .zero)
    }

    func testTheTransformEncodesTheOffsetWithTheBackendsKey() throws {
        var placement = ModelTransform()
        placement.position = CGPoint(x: 12.5, y: -3)

        let data = try JSONEncoder().encode(placement)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["offset_xy"] as? [Double], [12.5, -3])
    }

    func testTheArrangeRequestEncodesWithTheBackendsKeys() throws {
        let payload = ArrangeRequestPayload(
            modelIDs: ["a", "b"], spacing: 8, margin: 10, checkOnly: true
        )

        let data = try JSONEncoder().encode(payload)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["model_ids"] as? [String], ["a", "b"])
        XCTAssertEqual(json["check_only"] as? Bool, true)
        XCTAssertEqual(json["spacing"] as? Double, 8)
    }

    func testAnArrangeResponseDecodesFromTheBackendsShape() throws {
        let json = """
        {
          "placements": [
            {"model_id": "a", "width": 40.0, "depth": 30.0, "x": -25.0, "y": 0.0}
          ],
          "problems_ar": [],
          "unplaced": [],
          "ok": true,
          "bed_width": 250.0,
          "bed_depth": 320.0
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(ArrangeResponse.self, from: json)

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.bedWidth, 250)
        XCTAssertEqual(result.placements.first?.center, CGPoint(x: -25, y: 0))
        XCTAssertEqual(result.placements.first?.size, CGSize(width: 40, height: 30))
    }

    @MainActor
    func testThePlatePayloadKeepsEveryModelEvenTheUntouchedOnes() {
        // payload(for:) drops identity transforms because the slicer does not
        // need them. The arrangement does: a part sitting unturned at the
        // origin still has to be in the list, or the plate loses a model.
        let store = PlacementStore(
            settings: AppSettings(),
            printer: PrinterStore(settings: AppSettings(), notifications: NotificationManager())
        )
        store.setPosition(CGPoint(x: 30, y: 0), for: "moved")

        let slicePayload = store.payload(for: ["moved", "untouched"])
        let platePayload = store.platePayload(for: ["moved", "untouched"])

        XCTAssertEqual(Set(slicePayload.keys), ["moved"])
        XCTAssertEqual(Set(platePayload.keys), ["moved", "untouched"])
    }

    @MainActor
    func testSettingAPositionLeavesTheRotationAlone() {
        let store = PlacementStore(
            settings: AppSettings(),
            printer: PrinterStore(settings: AppSettings(), notifications: NotificationManager())
        )
        store.set(ModelTransform(rotationDeg: [90, 0, 0]), for: "m", measure: false)

        store.setPosition(CGPoint(x: 20, y: 20), for: "m")

        let result = store.transform(for: "m")
        XCTAssertEqual(result.rotationDeg, [90, 0, 0])
        XCTAssertEqual(result.position, CGPoint(x: 20, y: 20))
    }
}
