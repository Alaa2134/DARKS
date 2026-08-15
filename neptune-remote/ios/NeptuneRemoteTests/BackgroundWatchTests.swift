import XCTest
@testable import NeptuneRemote

/// What wakes somebody up, and what does not.
///
/// The app went completely silent the moment it left the screen: every event
/// came over a WebSocket that closed with it. This is the part that decides
/// whether a phone lights up at 3am, so it is separated from delivering and
/// proved here rather than by leaving a print running overnight.
final class BackgroundWatchTests: XCTestCase {

    private func reading(
        state: String = "",
        klippy: String = "ready",
        filename: String = "part.gcode",
        message: String = "",
        unreachable: Bool = false
    ) -> BackgroundWatch.Reading {
        BackgroundWatch.Reading(
            state: state,
            klippy: klippy,
            filename: filename,
            message: message,
            progress: 0,
            unreachable: unreachable,
            at: 1_000
        )
    }

    private func decide(
        _ previous: BackgroundWatch.Reading,
        _ current: BackgroundWatch.Reading,
        allow: @escaping (AppSettings.Key) -> Bool = { _ in true }
    ) -> [BackgroundWatch.Alert] {
        BackgroundWatch.decide(previous: previous, current: current, allow: allow)
    }

    // MARK: - Nothing to say

    func testTheFirstRunEverSaysNothing() {
        // There is no previous reading to compare against, and announcing the
        // state the printer was already in would be a notification for having
        // installed the app.
        let alerts = decide(BackgroundWatch.Reading(), reading(state: "printing"))

        XCTAssertTrue(alerts.isEmpty)
    }

    func testAPrintStillRunningIsNotNews() {
        let alerts = decide(reading(state: "printing"), reading(state: "printing"))

        XCTAssertTrue(alerts.isEmpty)
    }

    func testAnIdlePrinterStayingIdleIsNotNews() {
        let alerts = decide(reading(state: "standby"), reading(state: "standby"))

        XCTAssertTrue(alerts.isEmpty)
    }

    // MARK: - Worth waking somebody for

    func testAFinishedPrintIsAnnounced() {
        let alerts = decide(reading(state: "printing"), reading(state: "complete"))

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.titleKey, "notification.print_finished.title")
        // Finishing is good news; it does not need to break through a Focus.
        XCTAssertEqual(alerts.first?.urgent, false)
    }

    func testAFailedPrintIsUrgent() {
        let alerts = decide(
            reading(state: "printing"),
            reading(state: "error", message: "Extruder heater not heating")
        )

        XCTAssertEqual(alerts.first?.titleKey, "notification.print_failed.title")
        XCTAssertEqual(alerts.first?.urgent, true)
        XCTAssertEqual(alerts.first?.body, "Extruder heater not heating")
    }

    func testACancelledPrintCountsAsAFailure() {
        let alerts = decide(reading(state: "printing"), reading(state: "cancelled"))

        XCTAssertEqual(alerts.first?.titleKey, "notification.print_failed.title")
    }

    func testAPausedPrintIsUrgent() {
        // A pause nobody asked for is a runout or a sensor, and the printer
        // sits at temperature until somebody comes.
        let alerts = decide(reading(state: "printing"), reading(state: "paused"))

        XCTAssertEqual(alerts.first?.titleKey, "notification.print_paused.title")
        XCTAssertEqual(alerts.first?.urgent, true)
    }

    func testAFailureWithNoMessageStillNamesTheFile() {
        let alerts = decide(
            reading(state: "printing"),
            reading(state: "error", filename: "bracket.gcode")
        )

        XCTAssertEqual(alerts.first?.body, "bracket.gcode")
    }

    func testKlipperGoingDownIsAnnouncedOnItsOwn() {
        let alerts = decide(
            reading(state: "standby", klippy: "ready"),
            reading(state: "standby", klippy: "shutdown", message: "MCU error")
        )

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.titleKey, "notification.klipper_error.title")
    }

    func testKlipperStayingDownIsSaidOnceRatherThanEveryCheck() {
        let alerts = decide(
            reading(state: "standby", klippy: "shutdown"),
            reading(state: "standby", klippy: "shutdown")
        )

        XCTAssertTrue(alerts.isEmpty)
    }

    func testComingBackAfterBeingUnreachableIsWorthSaying() {
        let alerts = decide(
            reading(state: "printing", unreachable: true),
            reading(state: "printing")
        )

        XCTAssertEqual(alerts.first?.titleKey, "notification.connected.title")
    }

    // MARK: - A new print

    func testANewFileFinishingIsAnnouncedEvenFromTheSameState() {
        // Two prints in a row: same state either side, different file. Comparing
        // state alone would swallow the second one entirely.
        let alerts = decide(
            reading(state: "complete", filename: "first.gcode"),
            reading(state: "complete", filename: "second.gcode")
        )

        XCTAssertEqual(alerts.first?.body, "second.gcode")
    }

    func testEachAnnouncementHasItsOwnIdentity() {
        // Two notifications sharing an identifier means the second replaces the
        // first, and the print that failed disappears behind the one that did
        // not.
        let first = decide(
            reading(state: "printing"), reading(state: "complete", filename: "a.gcode")
        )
        let second = decide(
            reading(state: "printing"), reading(state: "complete", filename: "b.gcode")
        )

        XCTAssertNotEqual(first.first?.identifier, second.first?.identifier)
    }

    // MARK: - The user's own settings

    func testATurnedOffEventIsNotAnnounced() {
        let alerts = decide(
            reading(state: "printing"),
            reading(state: "complete"),
            allow: { $0 != .notifyFinished }
        )

        XCTAssertTrue(alerts.isEmpty)
    }

    func testTurningOffOneEventDoesNotSilenceTheRest() {
        let alerts = decide(
            reading(state: "printing", klippy: "ready"),
            reading(state: "complete", klippy: "shutdown"),
            allow: { $0 != .notifyFinished }
        )

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.titleKey, "notification.klipper_error.title")
    }

    // MARK: - Remembering between wake-ups

    func testAReadingSurvivesBeingWrittenAndReadBack() {
        // iOS may relaunch the process with nothing loaded, so the comparison
        // has to come off disk rather than out of memory.
        let original = reading(state: "printing", filename: "long.gcode")
        BackgroundWatch.save(original)

        XCTAssertEqual(BackgroundWatch.loadState(), original)
    }
}
