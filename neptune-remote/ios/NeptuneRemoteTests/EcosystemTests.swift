import SwiftUI
import XCTest
@testable import NeptuneRemote

/// Covers the phase-2 decoding, mapping and state-machine logic - including the
/// failure paths, where "does not fake success" is the thing being asserted.
final class EcosystemTests: XCTestCase {

    private let decoder = JSONDecoder()

    // MARK: - Home state machine

    private func snapshot(
        state: PrinterState = .standby,
        klippy: KlippyState = .ready,
        online: Bool = true
    ) -> PrinterSnapshot {
        var value = PrinterSnapshot()
        value.isOnline = online
        value.state = state
        value.klippy = klippy
        return value
    }

    private func power(_ state: PowerState) -> PowerReading {
        PowerReading(state: state, available: true, provider: .backend)
    }

    func testPhaseIsOffWheneverThePlugIsOff() {
        let phase = PrinterPhase.resolve(snapshot: snapshot(), power: power(.off))
        XCTAssertEqual(phase, .off)
    }

    func testPhaseIsStartingWhileKlipperBoots() {
        let phase = PrinterPhase.resolve(
            snapshot: snapshot(klippy: .startup), power: power(.on)
        )
        XCTAssertEqual(phase, .starting)
    }

    func testPhaseIsReadyWhenIdleAndKlipperIsUp() {
        XCTAssertEqual(
            PrinterPhase.resolve(snapshot: snapshot(), power: power(.on)),
            .ready
        )
    }

    func testPausedStillCountsAsPrinting() {
        XCTAssertEqual(
            PrinterPhase.resolve(snapshot: snapshot(state: .paused), power: power(.on)),
            .printing
        )
    }

    func testErrorBeatsEveryOtherSignal() {
        // Even with the plug reporting "off", a Klipper error must surface.
        XCTAssertEqual(
            PrinterPhase.resolve(snapshot: snapshot(klippy: .error), power: power(.off)),
            .error
        )
    }

    func testUnknownPowerDoesNotClaimThePrinterIsOff() {
        XCTAssertNotEqual(
            PrinterPhase.resolve(snapshot: snapshot(), power: power(.unknown)),
            .off
        )
    }

    // MARK: - Search result reasons

    private func searchEntry(reasons: [String]) throws -> SearchResultEntry {
        let json = """
        {
          "item": {"id": "a", "name_ar": "حامل", "model_filename": "a.stl",
                   "model_size": 10, "created_at": 1, "updated_at": 1},
          "score": 900,
          "reasons": \(try String(data: JSONEncoder().encode(reasons), encoding: .utf8)!)
        }
        """
        return try decoder.decode(SearchResultEntry.self, from: Data(json.utf8))
    }

    func testFuzzyReasonWithAScoreSuffixStillMapsToAKey() throws {
        let entry = try searchEntry(reasons: ["fuzzy:0.83"])
        XCTAssertEqual(entry.primaryReasonKey, "search.reason.fuzzy")
    }

    func testCoverageReasonMapsToFuzzy() throws {
        let entry = try searchEntry(reasons: ["coverage:2/3"])
        XCTAssertEqual(entry.primaryReasonKey, "search.reason.fuzzy")
    }

    func testPartialAliasMapsToTheAliasKey() throws {
        let entry = try searchEntry(reasons: ["alias-partial"])
        XCTAssertEqual(entry.primaryReasonKey, "search.reason.alias")
    }

    func testTheStrongestReasonWins() throws {
        let entry = try searchEntry(reasons: ["exact", "tag", "fuzzy:0.9"])
        XCTAssertEqual(entry.primaryReasonKey, "search.reason.exact")
    }

    func testUnknownReasonProducesNoLabelRatherThanAMissingKey() throws {
        let entry = try searchEntry(reasons: ["something-new"])
        XCTAssertNil(entry.primaryReasonKey)
    }

    // MARK: - Simple choices -> real slicer profiles

    private func profile(_ id: String) -> BackendProfile {
        BackendProfile(id: id, name: id, kind: "print", description: "", values: [:])
    }

    func testFilamentProfileMatchesExactlyWhenItExists() {
        let available = [profile("pla"), profile("petg"), profile("tpu")]
        XCTAssertEqual(SliceProfileMapper.filamentProfile(for: "PETG", available: available), "petg")
    }

    func testPlaPlusFallsBackToThePlaFamilyRatherThanTheFirstProfile() {
        let available = [profile("abs"), profile("pla"), profile("petg")]
        XCTAssertEqual(SliceProfileMapper.filamentProfile(for: "PLA+", available: available), "pla")
    }

    func testFilamentProfileNeverInventsAnIdThatTheBackendDoesNotHave() {
        let available = [profile("only_one")]
        let chosen = SliceProfileMapper.filamentProfile(for: "Nylon", available: available)
        XCTAssertTrue(available.map(\.id).contains(chosen))
    }

    func testPrintProfilePicksTheQualityHint() {
        let available = [profile("draft_0.28"), profile("standard_0.2"), profile("fine_0.16")]
        XCTAssertEqual(SliceProfileMapper.printProfile(for: .fine, available: available), "fine_0.16")
        XCTAssertEqual(SliceProfileMapper.printProfile(for: .draft, available: available), "draft_0.28")
    }

    func testPrintProfileFallsBackToStandard() {
        let available = [profile("standard_0.2"), profile("weird")]
        XCTAssertEqual(SliceProfileMapper.printProfile(for: .ultra, available: available), "standard_0.2")
    }

    func testQualityLayerHeightsAreOrdered() {
        let heights = PrintQuality.allCases.map(\.layerHeight)
        XCTAssertEqual(heights, heights.sorted(by: >))
    }

    // MARK: - Media models

    func testCameraStatusUnknownIsNotAvailable() {
        XCTAssertFalse(CameraStatus.unknown.available)
        XCTAssertEqual(CameraStatus.unknown.source, "none")
    }

    func testVisionStatusAlwaysDeclaresItCannotCutPower() throws {
        let json = """
        {"mode": "warn", "running": true, "provider": "heuristic", "available": true,
         "reason": "", "interval_seconds": 5, "configured_interval": 5,
         "confirmations_required": 3, "window_seconds": 30, "min_confidence": 0.55,
         "frames_analysed": 10, "last_frame_at": null, "last_error": "", "roi": null,
         "camera_available": true, "can_pause": true, "never_cuts_power": true}
        """
        let status = try decoder.decode(VisionStatus.self, from: Data(json.utf8))
        XCTAssertTrue(status.neverCutsPower)
        XCTAssertTrue(status.isHeuristic)
    }

    func testVisionEventDetectsTheHeuristicMarker() throws {
        let json = """
        {"id": "e1", "created_at": 1, "kind": "spaghetti", "confidence": 0.7,
         "confirmed": true, "action": "warned", "snapshot": null, "gcode_name": "a.gcode",
         "layer": 8, "progress": 0.2, "detail": "[heuristic] edges +40%", "acknowledged": false}
        """
        let event = try decoder.decode(VisionEvent.self, from: Data(json.utf8))
        XCTAssertTrue(event.isHeuristic)
        XCTAssertEqual(event.localizationKey, "vision.kind.spaghetti")
    }

    func testRecordingIdleReportsNoToolingRatherThanPretendingItWorks() {
        XCTAssertFalse(RecordingStatus.idle.ffmpegAvailable)
        XCTAssertFalse(RecordingStatus.idle.cameraAvailable)
        XCTAssertFalse(RecordingStatus.idle.recording)
    }

    // MARK: - Inventory models

    func testSpoolPercentRemainingIsClamped() throws {
        let json = """
        {"id": "s", "brand": "eSUN", "material": "PLA", "color_name": "أسود",
         "color_hex": "#101010", "initial_grams": 1000, "remaining_grams": 1400,
         "spool_weight_g": 200, "price": 700, "currency": "EGP", "purchased_at": null,
         "notes": "", "active": true, "archived": false}
        """
        let spool = try decoder.decode(FilamentSpool.self, from: Data(json.utf8))
        XCTAssertEqual(spool.percentRemaining, 1.0, accuracy: 0.0001)
        XCTAssertEqual(spool.costPerGram, 0.7, accuracy: 0.0001)
        XCTAssertEqual(spool.displayName, "eSUN · PLA · أسود")
    }

    func testSpoolWithNoInitialWeightDoesNotDivideByZero() throws {
        let json = """
        {"id": "s", "brand": "", "material": "PLA", "color_name": "", "color_hex": "#000000",
         "initial_grams": 0, "remaining_grams": 0, "spool_weight_g": 0, "price": 0,
         "currency": "EGP", "purchased_at": null, "notes": "", "active": false, "archived": false}
        """
        let spool = try decoder.decode(FilamentSpool.self, from: Data(json.utf8))
        XCTAssertEqual(spool.percentRemaining, 0)
        XCTAssertEqual(spool.costPerGram, 0)
    }

    func testQueueEmptyStateIsNotBedClear() {
        // The default must never be "the bed is clear" - that is what stops a
        // queued job from starting on its own.
        XCTAssertFalse(QueueState.empty.bedClear)
        XCTAssertNil(QueueState.empty.nextJob)
    }

    func testQueueWaitingFiltersOutFinishedJobs() throws {
        let json = """
        {"jobs": [
            {"id": "1", "item_id": null, "gcode_path": "a.gcode", "display_name": "A",
             "material": "PLA", "estimated_seconds": 10, "filament_g": 2, "position": 0,
             "status": "waiting"},
            {"id": "2", "item_id": null, "gcode_path": "b.gcode", "display_name": "B",
             "material": "PLA", "estimated_seconds": 10, "filament_g": 2, "position": 1,
             "status": "done"}
         ],
         "bed_clear": false, "next_job": null, "total_seconds": 20,
         "total_filament_g": 4, "blocked_reason_key": "queue.blocked.bed_not_clear"}
        """
        let state = try decoder.decode(QueueState.self, from: Data(json.utf8))
        XCTAssertEqual(state.waiting.count, 1)
        XCTAssertEqual(state.waiting.first?.id, "1")
    }

    func testTranslatedErrorAlwaysKeepsTheOriginalText() throws {
        let json = """
        {"matched": false, "code": "", "title_ar": "غير معروف", "title_en": "Unknown",
         "explanation_ar": "", "explanation_en": "", "causes_ar": [], "checks_ar": [],
         "severity": "info", "original": "!! Extruder heating failed"}
        """
        let translated = try decoder.decode(TranslatedError.self, from: Data(json.utf8))
        XCTAssertFalse(translated.matched)
        XCTAssertEqual(translated.original, "!! Extruder heating failed")
    }

    // MARK: - Library models

    func testLibraryItemFallsBackToTheEnglishNameWhenArabicIsMissing() throws {
        let json = """
        {"id": "x", "name_ar": "", "name_en": "Desk stand", "model_filename": "x.stl",
         "model_size": 100, "created_at": 1, "updated_at": 2}
        """
        let item = try decoder.decode(LibraryItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.displayName, "Desk stand")
        XCTAssertEqual(item.category, "other")
        XCTAssertTrue(item.gcodes.isEmpty)
    }

    func testGCodeProfileSummarySkipsUnknownFields() throws {
        let json = """
        {"id": "g", "item_id": "x", "filename": "x.gcode", "path": "gcode/x.gcode",
         "moonraker_path": null, "material": "PLA", "quality": "normal",
         "layer_height": 0.2, "estimated_seconds": null, "filament_g": null,
         "layer_count": null, "created_at": 1}
        """
        let gcode = try decoder.decode(LibraryGCode.self, from: Data(json.utf8))
        XCTAssertEqual(gcode.profileSummary, "PLA · 0.20 mm")
    }

    func testCategoryCatalogAlwaysReturnsASymbol() {
        XCTAssertFalse(LibraryCategoryCatalog.icon(for: "stands").isEmpty)
        XCTAssertFalse(LibraryCategoryCatalog.icon(for: "does-not-exist").isEmpty)
    }

    // MARK: - Live Activity payload

    func testLiveActivityLayerTextHandlesAMissingTotal() {
        var state = PrintActivityAttributes.ContentState(progress: 0.5, state: .printing)
        XCTAssertNil(state.layerText)
        state.currentLayer = 12
        XCTAssertEqual(state.layerText, "12")
        state.totalLayer = 100
        XCTAssertEqual(state.layerText, "12/100")
    }

    func testLiveActivityPayloadRoundTrips() throws {
        let attributes = PrintActivityAttributes(
            printerName: "Neptune", modelName: "حامل موبايل",
            gcodeName: "stand.gcode", thumbnailURL: URL(string: "http://100.78.2.66:8710/api/media/a.png")
        )
        let data = try JSONEncoder().encode(attributes)
        let decoded = try decoder.decode(PrintActivityAttributes.self, from: data)
        XCTAssertEqual(decoded, attributes)
    }

    // MARK: - Share Extension inbox

    func testPendingImportRoundTrips() throws {
        let item = PendingImport(
            id: "abc", filename: "cube.stl", relativePath: "abc.stl", receivedAt: Date()
        )
        let data = try JSONEncoder().encode([item])
        let decoded = try decoder.decode([PendingImport].self, from: data)
        XCTAssertEqual(decoded.first?.filename, "cube.stl")
        XCTAssertEqual(decoded.first?.relativePath, "abc.stl")
    }

    // MARK: - Formatting

    func testMoneyAppendsTheCurrencyCodeRatherThanGuessingASymbol() {
        XCTAssertEqual(Format.money(37.5, currency: "EGP"), "37.50 EGP")
        XCTAssertEqual(Format.money(1250, currency: "EGP"), "1250 EGP")
        XCTAssertEqual(Format.money(nil, currency: "EGP"), "--")
    }

    func testHexColourRejectsRubbish() {
        XCTAssertNotNil(Color(hex: "#1C1C1E"))
        XCTAssertNotNil(Color(hex: "1C1C1E"))
        XCTAssertNil(Color(hex: "#12345"))
        XCTAssertNil(Color(hex: "not-a-colour"))
    }
}
