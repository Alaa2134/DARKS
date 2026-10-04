import XCTest
@testable import NeptuneRemote

/// `lastUpdate` was stamped in six places and read in none, so a dropped
/// connection left the last temperatures on screen indefinitely and
/// indistinguishably from live ones. These pin the rule that replaced that.
final class StaleReadingTests: XCTestCase {

    func testAFreshReadingIsNotStale() {
        var snapshot = PrinterSnapshot()
        snapshot.lastUpdate = Date()

        XCTAssertFalse(snapshot.isStale)
        XCTAssertLessThan(snapshot.age, 1)
    }

    func testAReadingOlderThanTheThresholdIsStale() {
        var snapshot = PrinterSnapshot()
        snapshot.lastUpdate = Date().addingTimeInterval(-(PrinterSnapshot.staleAfter + 1))

        XCTAssertTrue(snapshot.isStale)
    }

    func testAReadingInsideTheThresholdIsNotStale() {
        var snapshot = PrinterSnapshot()
        // The socket pushes on change and the poll runs every four seconds, so
        // a quiet gap shorter than the threshold is normal, not a fault.
        snapshot.lastUpdate = Date().addingTimeInterval(-(PrinterSnapshot.staleAfter - 5))

        XCTAssertFalse(snapshot.isStale)
    }

    func testASnapshotThatNeverReceivedAnythingIsNotCalledStale() {
        // A snapshot with no reading at all is the state before the first frame
        // arrives. Calling that "stale" would put an alarm on the launch screen
        // of every cold start; there is nothing old here, there is nothing yet.
        let snapshot = PrinterSnapshot()

        XCTAssertEqual(snapshot.lastUpdate, .distantPast)
        XCTAssertFalse(snapshot.isStale)
    }
}
