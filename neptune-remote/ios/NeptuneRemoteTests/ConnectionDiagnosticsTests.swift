import XCTest
@testable import NeptuneRemote

/// The connection test reports five things that are genuinely independent.
/// Collapsing any of them into "connection failed" is what sends people
/// rebooting a Raspberry Pi that was never the problem.
final class ConnectionDiagnosticsTests: XCTestCase {

    private func diagnostics(
        moonraker: Bool? = nil,
        klippyConnected: Bool? = nil,
        klippyState: String? = nil,
        klipperReady: Bool? = nil,
        directPort: Bool = false,
        moonrakerError: APIError? = nil
    ) -> PrinterStore.Diagnostics {
        var value = PrinterStore.Diagnostics(websocketConnected: false)
        value.moonrakerReachable = moonraker
        value.klippyConnected = klippyConnected
        value.klippyState = klippyState
        value.klipperReady = klipperReady
        value.usingDirectMoonrakerPort = directPort
        value.moonrakerError = moonrakerError
        return value
    }

    /// The case the user actually hit: everything up, Klipper fine.
    func testHealthySetupHasNothingToReport() {
        let value = diagnostics(
            moonraker: true, klippyConnected: true, klippyState: "ready", klipperReady: true
        )
        XCTAssertNil(value.klipperVerdictKey)
        XCTAssertNil(value.moonrakerVerdictKey)
    }

    /// Moonraker up, Klipper down. This must read as a Klipper problem - the
    /// Moonraker row stays green.
    func testMoonrakerUpWithKlipperDownBlamesKlipper() {
        let value = diagnostics(
            moonraker: true, klippyConnected: false, klippyState: "shutdown", klipperReady: false
        )
        XCTAssertEqual(value.moonrakerReachable, true)
        XCTAssertNil(value.moonrakerVerdictKey, "Moonraker is fine and must not be flagged")
        XCTAssertEqual(value.klipperVerdictKey, "diagnostics.moonraker_ok_klipper_down")
    }

    func testMoonrakerUpWithKlipperStartingIsNotReady() {
        let value = diagnostics(
            moonraker: true, klippyConnected: true, klippyState: "startup", klipperReady: false
        )
        XCTAssertEqual(value.klipperVerdictKey, "diagnostics.moonraker_ok_klipper_not_ready")
    }

    /// Moonraker unreachable says nothing about Klipper, so Klipper must be
    /// reported as unknown rather than as failed.
    func testKlipperIsUnknownWhenMoonrakerDidNotAnswer() {
        let value = diagnostics(moonraker: false, moonrakerError: .timedOut)
        XCTAssertEqual(value.klipperVerdictKey, "diagnostics.klipper_unknown")
    }

    func testDirectPortFallbackIsSurfaced() {
        let value = diagnostics(
            moonraker: true, klippyConnected: true, klippyState: "ready",
            klipperReady: true, directPort: true
        )
        XCTAssertEqual(value.moonrakerVerdictKey, "diagnostics.direct_port")
    }

    /// Every verdict key has to exist in both bundles.
    func testVerdictKeysAreLocalized() throws {
        let keys = [
            "diagnostics.klipper_unknown",
            "diagnostics.moonraker_ok_klipper_down",
            "diagnostics.moonraker_ok_klipper_not_ready",
            "diagnostics.moonraker_unreachable",
            "diagnostics.direct_port",
            "diagnostics.backend_connected",
            "diagnostics.network",
            "diagnostics.moonraker_websocket",
            "diagnostics.backend_websocket",
            "diagnostics.technical"
        ]
        for language in ["en", "ar"] {
            guard let path = Bundle(for: ConnectionDiagnosticsTests.self)
                    .path(forResource: language, ofType: "lproj")
                    ?? Bundle.main.path(forResource: language, ofType: "lproj"),
                  let table = NSDictionary(contentsOfFile: path + "/Localizable.strings")
                    as? [String: String]
            else {
                throw XCTSkip("Localizable.strings not present in the test bundle")
            }
            for key in keys {
                XCTAssertNotNil(table[key], "\(key) missing from \(language).lproj")
            }
        }
    }
}
