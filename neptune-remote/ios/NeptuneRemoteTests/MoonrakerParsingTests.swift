import XCTest
@testable import NeptuneRemote

final class MoonrakerParsingTests: XCTestCase {

    private let statusJSON = """
    {
      "result": {
        "eventtime": 1234.5,
        "status": {
          "print_stats": {
            "filename": "benchy.gcode",
            "total_duration": 1200.0,
            "print_duration": 1100.0,
            "filament_used": 2345.6,
            "state": "printing",
            "message": "",
            "info": { "total_layer": 120, "current_layer": 42 }
          },
          "display_status": { "progress": 0.35, "message": null },
          "virtual_sdcard": { "progress": 0.34, "is_active": true, "file_position": 12345 },
          "toolhead": {
            "position": [10.0, 20.0, 0.6, 55.0],
            "homed_axes": "xyz",
            "max_velocity": 300.0,
            "max_accel": 3000.0,
            "square_corner_velocity": 5.0
          },
          "extruder": { "temperature": 209.8, "target": 210.0, "power": 0.4 },
          "heater_bed": { "temperature": 59.6, "target": 60.0, "power": 0.2 },
          "fan": { "speed": 0.75, "rpm": null },
          "gcode_move": {
            "speed": 6000.0,
            "speed_factor": 1.25,
            "extrude_factor": 0.98,
            "gcode_position": [10.0, 20.0, 0.6, 55.0]
          },
          "webhooks": { "state": "ready", "state_message": "Printer is ready" }
        }
      }
    }
    """

    private func decodeObjects() throws -> PrinterObjects {
        let data = Data(statusJSON.utf8)
        return try JSONDecoder()
            .decode(MoonrakerEnvelope<PrinterObjectsQueryResult>.self, from: data)
            .result
            .status
    }

    func testDecodesEveryDashboardField() throws {
        let snapshot = PrinterSnapshot.make(objects: try decodeObjects(), serverInfo: nil)

        XCTAssertTrue(snapshot.isOnline)
        XCTAssertEqual(snapshot.state, .printing)
        XCTAssertEqual(snapshot.klippy, .ready)
        XCTAssertEqual(snapshot.filename, "benchy.gcode")
        XCTAssertEqual(snapshot.progress, 0.35, accuracy: 0.0001)
        XCTAssertEqual(snapshot.printDuration, 1100, accuracy: 0.001)
        XCTAssertEqual(snapshot.nozzleActual, 209.8, accuracy: 0.001)
        XCTAssertEqual(snapshot.nozzleTarget, 210, accuracy: 0.001)
        XCTAssertEqual(snapshot.bedActual, 59.6, accuracy: 0.001)
        XCTAssertEqual(snapshot.bedTarget, 60, accuracy: 0.001)
        XCTAssertEqual(snapshot.position, [10, 20, 0.6])
        XCTAssertEqual(snapshot.homedAxes, "xyz")
        XCTAssertEqual(snapshot.speedFactor, 1.25, accuracy: 0.001)
        XCTAssertEqual(snapshot.extrudeFactor, 0.98, accuracy: 0.001)
        XCTAssertEqual(snapshot.fanSpeed, 0.75, accuracy: 0.001)
        XCTAssertEqual(snapshot.currentLayer, 42)
        XCTAssertEqual(snapshot.totalLayer, 120)
        XCTAssertEqual(snapshot.maxVelocity, 300, accuracy: 0.001)
        XCTAssertEqual(snapshot.maxAcceleration, 3000, accuracy: 0.001)
    }

    func testEstimatedTimeLeftMatchesFileProgress() throws {
        let snapshot = PrinterSnapshot.make(objects: try decodeObjects(), serverInfo: nil)
        // 1100 s elapsed at 35 % -> total 3142.9 s -> 2042.9 s remaining
        XCTAssertEqual(snapshot.estimatedTimeLeft ?? 0, 2042.857, accuracy: 0.01)
    }

    func testEstimatedTimeLeftIsNilBeforeProgressIsMeaningful() {
        var snapshot = PrinterSnapshot()
        snapshot.state = .printing
        snapshot.progress = 0.005
        snapshot.printDuration = 10
        XCTAssertNil(snapshot.estimatedTimeLeft)
    }

    func testProgressFallsBackToVirtualSDCard() throws {
        var objects = try decodeObjects()
        objects.displayStatus = nil
        let snapshot = PrinterSnapshot.make(objects: objects, serverInfo: nil)
        XCTAssertEqual(snapshot.progress, 0.34, accuracy: 0.0001)
    }

    func testPartialStatusUpdateMerges() throws {
        var objects = try decodeObjects()
        let deltaJSON = """
        { "extruder": { "temperature": 215.4 }, "print_stats": { "state": "paused" } }
        """
        let delta = try JSONDecoder().decode(PrinterObjects.self, from: Data(deltaJSON.utf8))
        objects.merge(delta)

        // Updated fields change, untouched fields survive.
        XCTAssertEqual(objects.extruder?.temperature ?? 0, 215.4, accuracy: 0.001)
        XCTAssertEqual(objects.extruder?.target ?? 0, 210, accuracy: 0.001)
        XCTAssertEqual(objects.printStats?.state, "paused")
        XCTAssertEqual(objects.printStats?.filename, "benchy.gcode")
    }

    func testServerInfoDecodesMissingFields() throws {
        let json = "{\"klippy_connected\": true, \"klippy_state\": \"ready\"}"
        let info = try JSONDecoder().decode(MoonrakerServerInfo.self, from: Data(json.utf8))
        XCTAssertTrue(info.klippyConnected)
        XCTAssertEqual(info.klippyState, "ready")
        XCTAssertNil(info.moonrakerVersion)
    }

    func testFileListDecodingAndThumbnailPath() throws {
        let json = """
        [{
          "path": "subdir/benchy.gcode",
          "modified": 1700000000.0,
          "size": 4312000,
          "estimated_time": 5053,
          "filament_total": 4321.5,
          "filament_weight_total": 12.88,
          "layer_height": 0.2,
          "filament_type": "PLA",
          "slicer": "PrusaSlicer",
          "thumbnails": [
            {"width": 32, "height": 32, "size": 900, "relative_path": ".thumbs/benchy-32x32.png"},
            {"width": 300, "height": 300, "size": 9000, "relative_path": ".thumbs/benchy-300x300.png"}
          ]
        }]
        """
        let files = try JSONDecoder().decode([MoonrakerFile].self, from: Data(json.utf8))
        let file = try XCTUnwrap(files.first)
        XCTAssertEqual(file.filename, "benchy.gcode")
        XCTAssertEqual(file.estimatedTime, 5053)
        // Largest thumbnail, resolved relative to the file's directory.
        XCTAssertEqual(file.thumbnailPath, "subdir/.thumbs/benchy-300x300.png")
    }

    func testMetadataUsesFilenameKey() throws {
        let json = "{\"filename\": \"a/b.gcode\", \"size\": 12}"
        let file = try JSONDecoder().decode(MoonrakerFile.self, from: Data(json.utf8))
        XCTAssertEqual(file.path, "a/b.gcode")
        XCTAssertEqual(file.filename, "b.gcode")
    }

    func testPowerDeviceStateExtraction() {
        let json = Data("{\"result\": {\"printer\": \"on\"}}".utf8)
        XCTAssertEqual(MoonrakerClient.extractDeviceState(data: json, device: "printer"), "on")
        XCTAssertNil(MoonrakerClient.extractDeviceState(data: json, device: "other"))
    }

    func testOfflineSnapshotIsSafeToRender() {
        let snapshot = PrinterSnapshot.offline(error: "boom")
        XCTAssertFalse(snapshot.isOnline)
        XCTAssertEqual(snapshot.state, .unknown)
        XCTAssertFalse(snapshot.isActive)
        XCTAssertNil(snapshot.estimatedTimeLeft)
        XCTAssertEqual(snapshot.x, 0)
    }
}
