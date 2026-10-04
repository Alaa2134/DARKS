import XCTest
@testable import NeptuneRemote

/// The demo is what someone trying the app sees first; these keep it whole.
final class DemoContentTests: XCTestCase {

    func testEveryDemoLibraryItemHasAPicture() throws {
        for item in DemoLibrary.items {
            let path = try XCTUnwrap(item.thumbnail, item.id)
            let url = try XCTUnwrap(DemoPictures.url(for: path), "no bundled picture for \(item.id)")
            XCTAssertTrue(url.isFileURL)
            XCTAssertGreaterThan((try? Data(contentsOf: url))?.count ?? 0, 1_000, item.id)
        }
    }

    func testDemoMediaIgnoresRealPaths() {
        XCTAssertNil(DemoPictures.url(for: "thumbnails/abc.png"))
    }

    func testPrintRiseSilhouettesStayInsideTheirBox() {
        for seed in ["trident_wave_vase.gcode", "bowl", "cable_box", "tower", "benchy.gcode", "x", ""] {
            let profile = PrintRise.profile(for: seed)
            for step in 0...40 {
                let radius = profile(Double(step) / 40)
                XCTAssertGreaterThan(radius, 0.1, seed)
                XCTAssertLessThanOrEqual(radius, 1.0, seed)
            }
        }
    }
}
