import XCTest
@testable import NeptuneRemote

/// Decoding the alert API, and the small pieces of judgement that live in the
/// models rather than in a view.
final class AlertModelTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: - Status

    func testAlertStatusDecodesTheSnakeCaseKeys() throws {
        let status = try decode(AlertStatus.self, #"""
        {
          "notifications": {
            "enabled": true,
            "language": "ar",
            "channels": [{"name": "ntfy", "sent": 12, "failed": 0,
                          "last_error": "", "last_success_at": 1700000000.0}],
            "configured": true,
            "warnings": [],
            "preferences": {"enabled": true, "events": ["power_lost"],
                            "min_priority": "low", "quiet_hours_enabled": false,
                            "quiet_start_hour": 23, "quiet_end_hour": 8},
            "available_events": ["power_lost", "print_finished"],
            "critical_events": ["power_lost"],
            "default_events": ["power_lost", "print_finished"],
            "last_decision": ""
          },
          "heartbeat": {"enabled": true, "interval_seconds": 300,
                        "last_ping_at": 1700000000.0, "seconds_since_last_ping": 42.0,
                        "successes": 5, "failures": 0, "last_error": ""},
          "reachable_when_app_is_closed": true,
          "advice": {"level": "ok", "ar": "شغالة", "en": "Working"}
        }
        """#)

        XCTAssertTrue(status.reachableWhenAppIsClosed)
        XCTAssertEqual(status.notifications.channels.first?.sent, 12)
        XCTAssertEqual(status.notifications.criticalEvents, ["power_lost"])
        XCTAssertEqual(status.heartbeat.secondsSinceLastPing, 42.0)
        XCTAssertEqual(status.advice.level, "ok")
    }

    func testAChannelWithAnErrorIsNotHealthy() {
        let healthy = AlertChannel(name: "ntfy", sent: 3, failed: 0, lastError: "", lastSuccessAt: 0)
        let broken = AlertChannel(name: "telegram", sent: 0, failed: 2,
                                  lastError: "HTTPError: 401", lastSuccessAt: 0)
        XCTAssertTrue(healthy.isHealthy)
        XCTAssertFalse(broken.isHealthy)
    }

    func testAMissingHeartbeatTimestampStaysNil() throws {
        let heartbeat = try decode(HeartbeatStatus.self, #"""
        {"enabled": false, "interval_seconds": 0, "last_ping_at": null,
         "seconds_since_last_ping": null, "successes": 0, "failures": 0, "last_error": ""}
        """#)
        XCTAssertNil(heartbeat.lastPingAt)
        XCTAssertNil(heartbeat.secondsSinceLastPing)
    }

    // MARK: - Preferences

    func testPreferencesRoundTripThroughTheWireFormat() throws {
        let original = AlertPreferences(
            enabled: true, events: ["power_lost", "print_finished"],
            minPriority: "high", quietHoursEnabled: true,
            quietStartHour: 22, quietEndHour: 7
        )
        let data = try JSONEncoder().encode(original)

        // The keys the backend expects, not Swift's camelCase.
        let raw = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNotNil(raw["quiet_hours_enabled"])
        XCTAssertNotNil(raw["min_priority"])
        XCTAssertNil(raw["quietHoursEnabled"])

        XCTAssertEqual(try decode(AlertPreferences.self, String(decoding: data, as: UTF8.self)), original)
    }

    // MARK: - Outages

    func testOutageRecordCarriesTheArabicCauseAndAdvice() throws {
        let record = try decode(OutageRecord.self, #"""
        {"id": "abc123", "cause": "printer_power",
         "cause_ar": "الكهرباء اتقطعت عن الطابعة",
         "advice_ar": "الطباعة وقفت عند الطبقة 412/900 ومش هتكمّل",
         "detected_at": 1700000000.0, "was_printing": true,
         "snapshot": {"filename": "benchy.gcode", "started_at": 1699990000.0,
                      "updated_at": 1700000000.0, "progress": 0.45,
                      "current_layer": 412, "total_layer": 900,
                      "z_height": 82.4, "filament_used_mm": 12000.0},
         "detail": "device gone", "restored_at": null, "acknowledged": false}
        """#)

        XCTAssertEqual(record.id, "abc123")
        XCTAssertTrue(record.isPowerRelated)
        XCTAssertEqual(record.snapshot?.layerText, "412/900")
        XCTAssertEqual(record.systemImage, "bolt.slash.fill")
    }

    func testAKlipperShutdownIsNotReportedAsPowerRelated() throws {
        let record = try decode(OutageRecord.self, #"""
        {"id": "x", "cause": "klipper_shutdown", "cause_ar": "Klipper وقف",
         "advice_ar": "", "detected_at": 0, "was_printing": false,
         "snapshot": null, "detail": "", "restored_at": null, "acknowledged": false}
        """#)
        XCTAssertFalse(record.isPowerRelated)
        XCTAssertNotEqual(record.systemImage, "bolt.slash.fill")
    }

    func testLayerTextFallsBackWhenTheTotalIsUnknown() {
        var snapshot = OutageSnapshot()
        snapshot.currentLayer = 12
        XCTAssertEqual(snapshot.layerText, "12")

        snapshot.totalLayer = 0
        XCTAssertEqual(snapshot.layerText, "12", "a zero total is not a total")

        snapshot.totalLayer = 300
        XCTAssertEqual(snapshot.layerText, "12/300")
    }

    func testLayerTextIsEmptyWithoutALayer() {
        XCTAssertEqual(OutageSnapshot().layerText, "")
    }

    func testAnUnknownSerialPresenceStaysNil() throws {
        // The backend refuses to guess a cause with no MCU device to watch, and
        // the app must not turn that "unknown" into a "no".
        let status = try decode(OutageStatus.self, #"""
        {"enabled": true, "serial_path": "", "serial_present": null,
         "in_outage": false, "tracking": null, "last": null, "records": []}
        """#)
        XCTAssertNil(status.serialPresent)
    }

    // MARK: - Filament sensors

    func testFilamentSensorsDecodeFromThePrinterStatus() throws {
        let status = try decode(BackendPrinterStatus.self, #"""
        {"online": true, "klippy_state": "ready", "state": "printing",
         "filament_sensors": {
            "filament_sensor": {"name": "filament_sensor", "kind": "switch",
                                "enabled": true, "filament_detected": false}
         }}
        """#)
        let sensor = try XCTUnwrap(status.filamentSensors["filament_sensor"])
        XCTAssertEqual(sensor.kind, "switch")
        XCTAssertFalse(sensor.filamentDetected)
    }

    func testAStatusWithoutSensorsIsStillValid() throws {
        let status = try decode(BackendPrinterStatus.self, #"""
        {"online": true, "klippy_state": "ready", "state": "standby"}
        """#)
        XCTAssertTrue(status.filamentSensors.isEmpty)
    }

    // MARK: - Notification events

    func testEveryBackendEventKindMapsToANotificationEvent() {
        // These are the kinds app/notify/messages.py can emit. A kind the app
        // cannot decode is a notification that silently never appears.
        let backendKinds = [
            "ai_pause_failed", "anomaly", "auto_power_off", "auto_power_off_failed",
            "connected", "disconnected", "filament_runout",
            "first_layer_complete", "klipper_error", "power_lost",
            "power_restored", "print_failed", "print_finished",
            "print_halfway", "print_interrupted", "print_paused",
            "print_resumed", "print_started", "safety_blocked",
            "target_reached", "vision_alert",
        ]
        for kind in backendKinds {
            XCTAssertNotNil(
                NotificationManager.Event(rawValue: kind),
                "the app cannot decode the backend event '\(kind)'"
            )
        }
    }

    func testOnlyTheActionableEventsInterruptADoNotDisturb() {
        // Handing .timeSensitive to a progress update is how people end up
        // silencing the whole category, and then losing the one that mattered.
        XCTAssertTrue(NotificationManager.Event.powerLost.soundIsCritical)
        XCTAssertTrue(NotificationManager.Event.filamentRunout.soundIsCritical)
        XCTAssertTrue(NotificationManager.Event.printInterrupted.soundIsCritical)

        XCTAssertFalse(NotificationManager.Event.printHalfway.soundIsCritical)
        XCTAssertFalse(NotificationManager.Event.firstLayerComplete.soundIsCritical)
        XCTAssertFalse(NotificationManager.Event.powerRestored.soundIsCritical)
    }
}
