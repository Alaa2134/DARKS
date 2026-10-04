import XCTest
@testable import NeptuneRemote

final class SliceRequestTests: XCTestCase {

    private func encode(_ payload: SliceRequestPayload) throws -> [String: Any] {
        let data = try JSONEncoder().encode(payload)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testEncodesSnakeCaseKeysTheBackendExpects() throws {
        var payload = SliceRequestPayload(modelID: "abc123")
        payload.layerHeight = 0.16
        payload.infillPercent = 35
        payload.supports = true
        payload.supportStyle = "organic"
        payload.adhesion = "brim"
        payload.nozzleTemperature = 215
        payload.bedTemperature = 62
        payload.outputName = "cube.gcode"

        let json = try encode(payload)
        XCTAssertEqual(json["model_id"] as? String, "abc123")
        XCTAssertEqual(json["printer_profile"] as? String, "neptune3plus_0.4")
        XCTAssertEqual(json["filament_profile"] as? String, "pla")
        XCTAssertEqual(json["print_profile"] as? String, "standard")
        XCTAssertEqual(json["layer_height"] as? Double ?? 0, 0.16, accuracy: 0.0001)
        XCTAssertEqual(json["infill_percent"] as? Int, 35)
        XCTAssertEqual(json["supports"] as? Bool, true)
        XCTAssertEqual(json["support_style"] as? String, "organic")
        XCTAssertEqual(json["adhesion"] as? String, "brim")
        XCTAssertEqual(json["nozzle_temperature"] as? Int, 215)
        XCTAssertEqual(json["bed_temperature"] as? Int, 62)
        XCTAssertEqual(json["output_name"] as? String, "cube.gcode")
        XCTAssertEqual(json["upload_to_moonraker"] as? Bool, true)
    }

    func testNeverAutoStartsAPrint() throws {
        let json = try encode(SliceRequestPayload(modelID: "x"))
        XCTAssertEqual(json["start_print_after_upload"] as? Bool, false)
    }

    func testOmittedOptionalsAreLeftOutEntirely() throws {
        // JSONEncoder drops nil optionals rather than writing null, and the
        // backend's Pydantic model defaults them to None either way - so an
        // absent key and an explicit null mean the same thing to the slicer.
        // Asserting absence is what actually matches the wire format.
        let json = try encode(SliceRequestPayload(modelID: "x"))
        XCTAssertNil(json["layer_height"])
        XCTAssertNil(json["nozzle_temperature"])
        XCTAssertNil(json["infill_percent"])

        // The keys that carry a real default must still be present.
        XCTAssertNotNil(json["printer_profile"])
        XCTAssertNotNil(json["supports"])
        XCTAssertNotNil(json["start_print_after_upload"])
    }

    func testDefaultsMatchTheNeptune3Plus() {
        let payload = SliceRequestPayload(modelID: "x")
        XCTAssertEqual(payload.printerProfile, "neptune3plus_0.4")
        XCTAssertFalse(payload.supports)
        XCTAssertTrue(payload.uploadToMoonraker)
        XCTAssertFalse(payload.startPrintAfterUpload)
    }

    func testSliceJobDecoding() throws {
        let json = """
        {
          "id": "abc",
          "status": "done",
          "progress": 1.0,
          "stage": "Completed",
          "model_id": "m1",
          "model_filename": "cube.stl",
          "output_filename": "cube.gcode",
          "output_path": "/data/gcode/cube.gcode",
          "moonraker_path": "cube.gcode",
          "created_at": 1700000000.0,
          "started_at": 1700000001.0,
          "finished_at": 1700000060.0,
          "error": null,
          "logs": ["=> Exporting G-code"],
          "stats": {
            "estimated_time_seconds": 5053,
            "filament_grams": 12.88,
            "filament_meters": 4.32,
            "filament_cm3": 10.4,
            "layer_count": 118,
            "layer_height": 0.2,
            "object_height": 42.6,
            "gcode_size": 3400000
          },
          "engine": "prusaslicer"
        }
        """
        let job = try JSONDecoder().decode(SliceJob.self, from: Data(json.utf8))
        XCTAssertTrue(job.didSucceed)
        XCTAssertTrue(job.isFinished)
        XCTAssertFalse(job.isRunning)
        XCTAssertEqual(job.stats.layerCount, 118)
        XCTAssertEqual(job.stats.filamentGrams ?? 0, 12.88, accuracy: 0.001)
        XCTAssertEqual(job.moonrakerPath, "cube.gcode")
    }

    func testRunningJobFlags() throws {
        let json = """
        {"id":"a","status":"running","progress":0.4,"stage":"Infilling layers",
         "model_id":"m","model_filename":"a.stl","output_filename":"a.gcode","output_path":"",
         "created_at":1.0,"started_at":2.0,"finished_at":null,"error":null,"logs":[],
         "stats":{"estimated_time_seconds":null,"filament_grams":null,"filament_meters":null,
                  "filament_cm3":null,"layer_count":null,"layer_height":null,
                  "object_height":null,"gcode_size":null},
         "engine":"prusaslicer"}
        """
        let job = try JSONDecoder().decode(SliceJob.self, from: Data(json.utf8))
        XCTAssertTrue(job.isRunning)
        XCTAssertFalse(job.isFinished)
        XCTAssertFalse(job.didSucceed)
    }

    func testSliceProgressEventDecoding() throws {
        let json = """
        {"id":"a","status":"running","progress":0.55,"stage":"Infilling layers",
         "output_filename":"a.gcode","error":null,"log_tail":["=> Infilling layers"]}
        """
        let event = try JSONDecoder().decode(BackendSocket.SliceProgress.self, from: Data(json.utf8))
        XCTAssertEqual(event.progress, 0.55, accuracy: 0.0001)
        XCTAssertEqual(event.logTail.count, 1)
    }

    func testBackendProfilesDecoding() throws {
        let json = """
        {
          "printers": [{"id":"neptune3plus_0.4","name":"Neptune 3 Plus","kind":"printer",
                        "description":"","values":{"bed_shape":"0x0,320x0,320x320,0x320",
                                                    "max_print_height":"400"}}],
          "filaments": [],
          "prints": []
        }
        """
        let profiles = try JSONDecoder().decode(BackendProfiles.self, from: Data(json.utf8))
        XCTAssertEqual(profiles.printers.first?.values["max_print_height"], "400")
        XCTAssertTrue(profiles.filaments.isEmpty)
    }
}
