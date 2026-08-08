import XCTest
@testable import NeptuneRemote

final class ConnectionConfigTests: XCTestCase {

    func testDefaultMatchesTheDocumentedPi() {
        let config = ConnectionConfig.default
        XCTAssertEqual(config.host, "100.78.2.66")
        XCTAssertEqual(config.moonrakerPort, 80)
        XCTAssertEqual(config.backendPort, 8710)
        XCTAssertFalse(config.useHTTPS)
    }

    func testDefaultPortIsOmittedFromURLs() {
        let config = ConnectionConfig.default
        XCTAssertEqual(config.moonrakerBaseURL?.absoluteString, "http://100.78.2.66")
        XCTAssertEqual(config.backendBaseURL?.absoluteString, "http://100.78.2.66:8710")
    }

    func testWebSocketURLs() {
        let config = ConnectionConfig.default
        XCTAssertEqual(config.moonrakerWebSocketURL?.absoluteString, "ws://100.78.2.66/websocket")
        XCTAssertEqual(config.backendWebSocketURL?.absoluteString, "ws://100.78.2.66:8710/ws")
    }

    func testDirectMoonrakerPort() {
        let config = ConnectionConfig(host: "pi", moonrakerPort: 7125, backendPort: 8710, useHTTPS: false)
        XCTAssertEqual(config.moonrakerBaseURL?.absoluteString, "http://pi:7125")
    }

    func testHTTPSUsesWSS() {
        let config = ConnectionConfig(host: "pi.example", moonrakerPort: 443, backendPort: 8710, useHTTPS: true)
        XCTAssertEqual(config.moonrakerBaseURL?.absoluteString, "https://pi.example")
        XCTAssertEqual(config.moonrakerWebSocketURL?.absoluteString, "wss://pi.example/websocket")
    }

    func testValidation() {
        XCTAssertTrue(ConnectionConfig.default.isValid)
        XCTAssertFalse(ConnectionConfig(host: "  ", moonrakerPort: 80, backendPort: 8710, useHTTPS: false).isValid)
        XCTAssertFalse(ConnectionConfig(host: "pi", moonrakerPort: 0, backendPort: 8710, useHTTPS: false).isValid)
        XCTAssertFalse(ConnectionConfig(host: "pi", moonrakerPort: 80, backendPort: 70000, useHTTPS: false).isValid)
    }

    func testHostIsTrimmed() {
        let config = ConnectionConfig(host: " 100.78.2.66 ", moonrakerPort: 80, backendPort: 8710, useHTTPS: false)
        XCTAssertEqual(config.moonrakerBaseURL?.host, "100.78.2.66")
    }

    func testRoundTripsThroughJSON() throws {
        let config = ConnectionConfig(host: "10.0.0.5", moonrakerPort: 7125, backendPort: 9000, useHTTPS: true)
        let decoded = try JSONDecoder().decode(ConnectionConfig.self, from: try JSONEncoder().encode(config))
        XCTAssertEqual(decoded, config)
    }
}

final class PrinterStateTests: XCTestCase {

    func testMoonrakerStateMapping() {
        XCTAssertEqual(PrinterState(moonraker: "printing"), .printing)
        XCTAssertEqual(PrinterState(moonraker: "PAUSED"), .paused)
        XCTAssertEqual(PrinterState(moonraker: "standby"), .standby)
        XCTAssertEqual(PrinterState(moonraker: "complete"), .complete)
        XCTAssertEqual(PrinterState(moonraker: "cancelled"), .cancelled)
        XCTAssertEqual(PrinterState(moonraker: "error"), .error)
        XCTAssertEqual(PrinterState(moonraker: "some_new_state"), .unknown)
        XCTAssertEqual(PrinterState(moonraker: nil), .unknown)
    }

    func testActiveStates() {
        XCTAssertTrue(PrinterState.printing.isActive)
        XCTAssertTrue(PrinterState.paused.isActive)
        XCTAssertFalse(PrinterState.complete.isActive)
        XCTAssertFalse(PrinterState.standby.isActive)
    }

    func testEveryStateHasASymbolAndKey() {
        for state in PrinterState.allCases {
            XCTAssertFalse(state.symbolName.isEmpty)
            XCTAssertTrue(state.localizationKey.hasPrefix("printer.state."))
        }
    }

    func testKlippyStateMapping() {
        XCTAssertEqual(KlippyState(raw: "ready"), .ready)
        XCTAssertEqual(KlippyState(raw: "shutdown"), .shutdown)
        XCTAssertEqual(KlippyState(raw: "weird"), .unknown)
        XCTAssertTrue(KlippyState(raw: "ready").isReady)
    }

    func testPowerStateMapping() {
        XCTAssertEqual(PowerState(raw: "on"), .on)
        XCTAssertEqual(PowerState(raw: "OFF"), .off)
        XCTAssertEqual(PowerState(raw: "error"), .error)
        XCTAssertEqual(PowerState(raw: nil), .unknown)
    }

    func testWidgetSnapshotRoundTrip() throws {
        let snapshot = PrinterWidgetSnapshot.placeholder
        let decoded = try JSONDecoder().decode(
            PrinterWidgetSnapshot.self,
            from: try JSONEncoder().encode(snapshot)
        )
        XCTAssertEqual(decoded.state, .printing)
        XCTAssertEqual(decoded.progress, 0.42, accuracy: 0.0001)
        XCTAssertEqual(decoded.filename, "benchy.gcode")
    }
}

final class PresetTests: XCTestCase {

    func testDefaultTemperaturePresetsMatchTheSpecification() {
        let presets = TemperaturePreset.defaults
        func preset(_ name: String) -> TemperaturePreset? { presets.first { $0.name == name } }

        XCTAssertEqual(preset("PLA")?.nozzle, 205)
        XCTAssertEqual(preset("PLA")?.bed, 60)
        XCTAssertEqual(preset("PETG")?.nozzle, 235)
        XCTAssertEqual(preset("PETG")?.bed, 75)
        XCTAssertEqual(preset("TPU")?.nozzle, 220)
        XCTAssertEqual(preset("TPU")?.bed, 50)
        XCTAssertNotNil(preset("PLA+"))
        XCTAssertNotNil(preset("ASA"))
        XCTAssertNotNil(preset("ABS"))
        XCTAssertNotNil(preset("Custom"))
    }

    func testPredefinedCommandsAreKlipperSafe() {
        let commands = GCodeShortcut.predefined.map(\.command)
        XCTAssertTrue(commands.contains("G28"))
        XCTAssertTrue(commands.contains("G28 X"))
        XCTAssertTrue(commands.contains("M84"))
        XCTAssertTrue(commands.contains("M107"))
        XCTAssertTrue(commands.contains("TURN_OFF_HEATERS"))
        XCTAssertTrue(commands.contains("BED_MESH_CALIBRATE"))
        XCTAssertTrue(commands.contains("SAVE_CONFIG"))
        // The emergency stop is never a one-tap shortcut.
        XCTAssertFalse(commands.contains("M112"))
    }

    func testTemperaturePresetCodable() throws {
        let preset = TemperaturePreset(name: "Test", nozzle: 230, bed: 70)
        let decoded = try JSONDecoder().decode(
            TemperaturePreset.self, from: try JSONEncoder().encode(preset)
        )
        XCTAssertEqual(decoded, preset)
    }
}

final class FormatterTests: XCTestCase {

    func testDuration() {
        XCTAssertEqual(Format.duration(45), "45s")
        XCTAssertEqual(Format.duration(90), "1m 30s")
        XCTAssertEqual(Format.duration(5053), "1h 24m")
        XCTAssertEqual(Format.duration(90000), "1d 1h")
        XCTAssertEqual(Format.duration(nil), "--")
        XCTAssertEqual(Format.duration(-5), "--")
    }

    func testClock() {
        XCTAssertEqual(Format.clock(65), "01:05")
        XCTAssertEqual(Format.clock(3661), "1:01:01")
        XCTAssertEqual(Format.clock(nil), "--:--")
    }

    func testPercentAndTemperature() {
        XCTAssertEqual(Format.percent(0.355), "36%")
        XCTAssertEqual(Format.percent(nil), "--")
        XCTAssertEqual(Format.temperature(209.84), "209.8°")
        XCTAssertEqual(Format.temperatureShort(59.6), "60°")
    }

    func testSpeedConvertsToMillimetresPerSecond() {
        XCTAssertEqual(Format.speed(6000), "100 mm/s")
        XCTAssertEqual(Format.speed(nil), "--")
    }
}

final class APIErrorTests: XCTestCase {

    func testRetryability() {
        XCTAssertTrue(APIError.offline.isRetryable)
        XCTAssertTrue(APIError.timedOut.isRetryable)
        XCTAssertTrue(APIError.cannotConnect("pi").isRetryable)
        XCTAssertFalse(APIError.unauthorized.isRetryable)
        XCTAssertFalse(APIError.unsafeOperation(["hot"]).isRetryable)
        XCTAssertFalse(APIError.cancelled.isRetryable)
    }

    func testURLErrorMapping() {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        XCTAssertEqual(APIError.from(offline), .offline)

        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        XCTAssertEqual(APIError.from(timeout), .timedOut)

        let refused = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        XCTAssertEqual(APIError.from(refused, host: "pi"), .cannotConnect("pi"))
    }

    /// A timeout and a refused connection have to read differently: one means
    /// the Raspberry Pi never answered (VPN down, Pi off, wrong address), the
    /// other means it answered and the service was not listening. Showing the
    /// same text for both sends the user looking in the wrong place.
    func testTroubleshootingHintsDistinguishTimeoutFromRefusal() {
        let timeout = APIError.timedOut.troubleshootingKey
        let refused = APIError.cannotConnect("pi").troubleshootingKey

        XCTAssertNotNil(timeout)
        XCTAssertNotNil(refused)
        XCTAssertNotEqual(timeout, refused)

        XCTAssertEqual(APIError.offline.troubleshootingKey, "error.hint.offline")
        XCTAssertEqual(APIError.unauthorized.troubleshootingKey, "error.hint.unauthorized")
        XCTAssertEqual(APIError.notConfigured.troubleshootingKey, "error.hint.not_configured")

        // Failures the user cannot act on from this screen get no hint.
        XCTAssertNil(APIError.cancelled.troubleshootingKey)
        XCTAssertNil(APIError.decoding("bad json").troubleshootingKey)
    }

    func testUnsafeOperationCarriesBlockers() {
        let error = APIError.unsafeOperation(["Nozzle is 180C", "A print is in progress"])
        XCTAssertTrue(error.localizedDescription.contains("Nozzle"))
        XCTAssertTrue(error.localizedDescription.contains("print"))
    }

    func testExtractsFastAPIDetail() {
        let data = Data("{\"detail\": \"Unknown action 'nope'\"}".utf8)
        XCTAssertEqual(HTTPClient.extractMessage(from: data), "Unknown action 'nope'")
    }

    func testExtractsMoonrakerErrorMessage() {
        let data = Data("{\"error\": {\"code\": 400, \"message\": \"Unknown command\"}}".utf8)
        XCTAssertEqual(HTTPClient.extractMessage(from: data), "Unknown command")
    }

    func testExtractsSafetyBlockers() {
        let data = Data("""
        {"detail": {"message": "Unsafe to power off",
                    "safety": {"blockers": ["Nozzle is 180C, above the safe limit"]}}}
        """.utf8)
        let blockers = HTTPClient.extractBlockers(from: data)
        XCTAssertEqual(blockers?.count, 1)
    }
}

final class LocalizationTests: XCTestCase {

    /// Loads one `.lproj` table, looking in the test bundle first and falling
    /// back to the main bundle when the tests run against the app target.
    private func strings(_ language: String) -> [String: String]? {
        for candidate in [Bundle(for: LocalizationTests.self), Bundle.main] {
            if let path = candidate.path(forResource: language, ofType: "lproj"),
               let dictionary = NSDictionary(
                contentsOfFile: path + "/Localizable.strings"
               ) as? [String: String] {
                return dictionary
            }
        }
        return nil
    }

    func testEnglishAndArabicHaveTheSameKeys() throws {
        guard let english = strings("en"), let arabic = strings("ar") else {
            throw XCTSkip("Localizable.strings not present in the test bundle")
        }

        XCTAssertEqual(Set(english.keys).symmetricDifference(Set(arabic.keys)), [], "en/ar key sets differ")
        XCTAssertGreaterThan(english.count, 300)
    }

    /// Every troubleshooting hint has to resolve to real copy in both bundles,
    /// otherwise the setup wizard shows the raw key to the user.
    func testTroubleshootingHintsAreLocalized() throws {
        guard let english = strings("en"), let arabic = strings("ar") else {
            throw XCTSkip("Localizable.strings not present in the test bundle")
        }

        let errors: [APIError] = [.timedOut, .cannotConnect("pi"), .offline, .unauthorized, .notConfigured]
        for error in errors {
            let key = try XCTUnwrap(error.troubleshootingKey, "\(error) should offer a hint")
            for (language, table) in [("en", english), ("ar", arabic)] {
                let text = try XCTUnwrap(table[key], "\(key) is missing from \(language).lproj")
                XCTAssertFalse(text.isEmpty, "\(key) is empty in \(language).lproj")
            }
        }
    }

    /// The English table is English. Earlier revisions carried "عربي / English"
    /// double strings that leaked Arabic into the English UI.
    func testEnglishTableHasNoArabicText() throws {
        guard let english = strings("en") else {
            throw XCTSkip("Localizable.strings not present in the test bundle")
        }
        let arabicRange = "\u{0600}"..."\u{06FF}"
        let offenders = english
            .filter { $0.value.contains { arabicRange.contains(String($0)) } }
            .keys
            .sorted()
        XCTAssertEqual(offenders, [], "English strings containing Arabic text")
    }

    func testEveryEnumLocalizationKeyIsNamespaced() {
        for kind in PowerProviderKind.allCases {
            XCTAssertTrue(kind.localizationKey.hasPrefix("power.provider."))
        }
        for kind in CameraKind.allCases {
            XCTAssertTrue(kind.localizationKey.hasPrefix("camera.kind."))
        }
        for mode in AppearanceMode.allCases {
            XCTAssertTrue(mode.localizationKey.hasPrefix("settings.appearance."))
        }
    }
}
