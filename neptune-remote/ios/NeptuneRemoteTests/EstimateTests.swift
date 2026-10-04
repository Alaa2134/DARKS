import XCTest
@testable import NeptuneRemote

/// The remaining-time estimate on the phone side.
///
/// The bug these pin down: the app computed `printDuration / progress` locally
/// and ignored the backend's answer entirely - the same formula the backend had
/// already been fixed to stop using, kept alive in a second place. Deleting a
/// bad calculation in one file does nothing if a copy of it survives in another.
final class EstimateTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func snapshot(
        progress: Double,
        duration: TimeInterval,
        estimate: PrintEstimate? = nil
    ) -> PrinterSnapshot {
        var value = PrinterSnapshot()
        value.state = .printing
        value.progress = progress
        value.printDuration = duration
        value.estimate = estimate
        return value
    }

    private func backendEstimate(
        remaining: Double?,
        method: String = "slicer_calibrated",
        confidence: Double = 0.8
    ) throws -> PrintEstimate {
        // Interpolated rather than `String.init`: that initialiser has enough
        // overloads that the compiler cannot pick one inside a string literal.
        let remainingJSON: String = remaining.map { "\($0)" } ?? "null"
        return try decode(PrintEstimate.self, """
        {"remaining_seconds": \(remainingJSON),
         "total_seconds": 17000, "method": "\(method)",
         "method_ar": "من تقدير السلايسر، معايَر على طابعتك",
         "method_en": "Slicer estimate, calibrated to this printer",
         "confidence": \(confidence), "slicer_seconds": 14400,
         "speed_factor": 1.0, "progress_source": "filament",
         "calibration": {"factor": 1.18, "samples": 5, "spread": 0.02,
                         "learned": true, "percent_off": 18.0}}
        """)
    }

    // MARK: - The backend's answer wins

    func testTheBackendEstimateIsUsedInsteadOfTheLocalDivision() throws {
        // Local maths on these numbers gives 2400s. The backend, which has the
        // slicer's figure and this printer's calibration, says 5000.
        let value = snapshot(progress: 0.5, duration: 2400, estimate: try backendEstimate(remaining: 5000))
        XCTAssertEqual(value.estimatedTimeLeft, 5000)
    }

    func testTheLocalFallbackIsUsedWithNoBackend() throws {
        // The Moonraker-direct path, where there is no backend to ask.
        let value = snapshot(progress: 0.5, duration: 2400)
        XCTAssertEqual(try XCTUnwrap(value.estimatedTimeLeft), 2400, accuracy: 1)
    }

    func testAnUnknownBackendEstimateFallsBackRatherThanShowingNothing() throws {
        let value = snapshot(progress: 0.5, duration: 2400,
                             estimate: try backendEstimate(remaining: nil, method: "unknown"))
        XCTAssertEqual(try XCTUnwrap(value.estimatedTimeLeft), 2400, accuracy: 1)
    }

    // MARK: - The local fallback no longer reports days

    func testTheFallbackStaysSilentDuringTheWarmup() {
        // 400 seconds of heating at 0.1 % progress. The old threshold of 2 %
        // let this through and printed "4 days remaining".
        let value = snapshot(progress: 0.001, duration: 400)
        XCTAssertNil(value.estimatedTimeLeft)

        // What it would have said, for the record.
        XCTAssertGreaterThan(400.0 / 0.001 - 400.0, 4 * 24 * 3600)
    }

    func testTheFallbackAnswersOnceThereIsRealProgress() {
        XCTAssertNil(snapshot(progress: 0.05, duration: 600).estimatedTimeLeft)
        XCTAssertNotNil(snapshot(progress: 0.20, duration: 600).estimatedTimeLeft)
    }

    func testNoEstimateWhenNotPrinting() {
        var value = snapshot(progress: 0.5, duration: 2400)
        value.state = .standby
        XCTAssertNil(value.estimatedTimeLeft)
    }

    // MARK: - Decoding

    func testTheEstimateDecodesWithItsReasoning() throws {
        let estimate = try backendEstimate(remaining: 5000)
        XCTAssertEqual(estimate.method, "slicer_calibrated")
        XCTAssertEqual(estimate.progressSource, "filament")
        XCTAssertEqual(try XCTUnwrap(estimate.calibration).percentOff, 18.0)
        XCTAssertTrue(try XCTUnwrap(estimate.calibration).learned)
        XCTAssertFalse(estimate.isRough)
    }

    func testALowConfidenceEstimateIsMarkedRough() throws {
        let estimate = try backendEstimate(remaining: 5000, method: "observed", confidence: 0.3)
        XCTAssertTrue(estimate.isRough)
    }

    func testTheMethodTextIsOnlyOfferedWhenThereIsANumber() throws {
        let withNumber = snapshot(progress: 0.5, duration: 2400,
                                  estimate: try backendEstimate(remaining: 5000))
        XCTAssertNotNil(withNumber.estimateMethodText)

        let withoutNumber = snapshot(progress: 0.5, duration: 2400,
                                     estimate: try backendEstimate(remaining: nil))
        XCTAssertNil(withoutNumber.estimateMethodText)

        XCTAssertNil(snapshot(progress: 0.5, duration: 2400).estimateMethodText)
    }

    func testAStatusFromAnOlderBackendStillDecodes() throws {
        // The estimate field is new. A Pi that has not been updated yet must
        // not blank the whole dashboard.
        let status = try decode(BackendPrinterStatus.self, """
        {"online": true, "klippy_state": "ready", "state": "printing",
         "progress": 0.4, "print_duration": 1200}
        """)
        XCTAssertNil(status.estimate)
        XCTAssertEqual(status.snapshot.progress, 0.4)
    }

    func testTheSnapshotCarriesTheEstimateThrough() throws {
        let status = try decode(BackendPrinterStatus.self, """
        {"online": true, "klippy_state": "ready", "state": "printing",
         "progress": 0.4, "print_duration": 1200,
         "estimate": {"remaining_seconds": 3600, "total_seconds": 4800,
                      "method": "blended", "method_ar": "أ", "method_en": "b",
                      "confidence": 0.85, "speed_factor": 1.0,
                      "progress_source": "filament"}}
        """)
        XCTAssertEqual(status.snapshot.estimatedTimeLeft, 3600)
        XCTAssertEqual(status.snapshot.estimate?.method, "blended")
    }
}
