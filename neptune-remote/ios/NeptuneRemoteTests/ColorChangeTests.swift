import XCTest
@testable import NeptuneRemote

/// Multi-colour printing on a single-nozzle machine.
///
/// The two halves tested here are the wire format the backend expects, and the
/// reading of the colour out of the printer's own display message - which is
/// what turns an ordinary pause into "the printer is waiting for red".
final class ColorChangeTests: XCTestCase {

    // MARK: - The request

    private func encode(_ payload: SliceRequestPayload) throws -> [String: Any] {
        let data = try JSONEncoder().encode(payload)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testColorChangesAreSentUnderTheKeyTheBackendReads() throws {
        var payload = SliceRequestPayload(modelID: "abc")
        payload.colorChanges = [
            ColorChange(layer: 20, color: "أحمر"),
            ColorChange(layer: 45, color: "أزرق")
        ]

        let json = try encode(payload)
        let changes = try XCTUnwrap(json["color_changes"] as? [[String: Any]])
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes[0]["layer"] as? Int, 20)
        XCTAssertEqual(changes[0]["color"] as? String, "أحمر")
    }

    func testAPlainSliceSendsAnEmptyListRatherThanNothing() throws {
        // Present and empty, not absent: the backend's field is a list with a
        // default, so both work - but an explicit [] is what says "one colour"
        // rather than "this app does not know about colours".
        let json = try encode(SliceRequestPayload(modelID: "x"))
        XCTAssertEqual((json["color_changes"] as? [[String: Any]])?.count, 0)
    }

    // MARK: - Reading a file's plan back

    func testAFileWithoutAPlanDecodesFine() throws {
        // Every G-code listed before this feature existed, and every backend
        // that has not been updated yet. A missing key must cost the colour
        // plan, not the whole file list.
        let json = """
        {"path": "a.gcode", "filename": "a.gcode", "size": 10, "modified": 1,
         "source": "moonraker"}
        """.data(using: .utf8)!
        let file = try JSONDecoder().decode(BackendGCodeFile.self, from: json)
        XCTAssertTrue(file.colorChanges.isEmpty)
    }

    func testAFileWithAPlanCarriesTheHeights() throws {
        let json = """
        {"path": "a.gcode", "filename": "a.gcode", "size": 10, "modified": 1,
         "source": "backend",
         "color_changes": [{"layer": 20, "color": "أحمر", "z": 4.1}]}
        """.data(using: .utf8)!
        let file = try JSONDecoder().decode(BackendGCodeFile.self, from: json)
        XCTAssertEqual(file.colorChanges.first?.layer, 20)
        XCTAssertEqual(file.colorChanges.first?.color, "أحمر")
        XCTAssertEqual(file.colorChanges.first?.z ?? 0, 4.1, accuracy: 0.001)
    }

    // MARK: - Knowing why the printer stopped

    func testTheColourIsReadOutOfTheDisplayMessage() {
        // Written by the M117 the slicer places next to every stop. Matching on
        // the message rather than on our own bookkeeping is what makes this
        // work for a file this app did not slice.
        XCTAssertEqual(PrinterStore.colorFromDisplay("COLOR: أحمر"), "أحمر")
        XCTAssertEqual(PrinterStore.colorFromDisplay("  COLOR:Light Blue  "), "Light Blue")
    }

    func testAnOrdinaryPauseIsNotMistakenForAColourChange() {
        // The difference matters: one of these means "go and change the spool",
        // the other means "you pressed pause".
        XCTAssertNil(PrinterStore.colorFromDisplay("Printing 42%"))
        XCTAssertNil(PrinterStore.colorFromDisplay(""))
        XCTAssertNil(PrinterStore.colorFromDisplay("COLOR:"))
    }
}
