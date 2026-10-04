import XCTest
@testable import NeptuneRemote

/// A filename made into something a person would call the print.
final class PrintNameTests: XCTestCase {
    func testUnderscoresAndExtensionGo() {
        XCTAssertEqual(Format.printName("trident_wave_vase.gcode"), "trident wave vase")
    }

    func testDashesBecomeSpacesAndRunsCollapse() {
        XCTAssertEqual(Format.printName("phone--stand_v2.gcode"), "phone stand v2")
    }

    func testTheExtensionIsMatchedWhateverItsCase() {
        XCTAssertEqual(Format.printName("Benchy.GCODE"), "Benchy")
    }

    func testAFolderPathKeepsOnlyTheFile() {
        XCTAssertEqual(Format.printName("parts/clip_a.gcode"), "clip a")
    }

    func testArabicNamesSurviveUntouched() {
        XCTAssertEqual(Format.printName("مزهرية_موج.gcode"), "مزهرية موج")
    }

    func testANameThatWouldBeEmptyFallsBackToTheFilename() {
        XCTAssertEqual(Format.printName("___.gcode"), "___.gcode")
    }
}
