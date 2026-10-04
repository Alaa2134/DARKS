import XCTest
@testable import NeptuneRemote

/// The client half of importing from a link: what gets sent, and what the app
/// makes of what comes back.
final class ImportLinkTests: XCTestCase {

    // MARK: - What gets sent

    func testTheRequestEncodesWithTheKeysTheBackendReads() throws {
        let data = try JSONEncoder().encode(
            ImportRequestPayload(
                url: "https://example.com/part.stl",
                category: "tools",
                nameAR: "مسمار الرف",
                tags: ["رف"]
            )
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        // Snake case, matching raspberry-pi/app/schemas.py. A silent mismatch
        // here means a name the user typed never arrives.
        XCTAssertEqual(json["url"] as? String, "https://example.com/part.stl")
        XCTAssertEqual(json["name_ar"] as? String, "مسمار الرف")
        XCTAssertEqual(json["category"] as? String, "tools")
        XCTAssertEqual(json["tags"] as? [String], ["رف"])
    }

    // MARK: - What comes back

    func testASingleModelDecodes() throws {
        let json = """
        {
          "ok": true,
          "items": [{"id": "abc", "name_ar": "قطعة", "model_filename": "part.stl"}],
          "collection_id": "",
          "collection_name": "",
          "source_url": "https://example.com/part.stl",
          "needs_key": "",
          "notes_ar": []
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(ImportResult.self, from: json)

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items.first?.nameAR, "قطعة")
        XCTAssertTrue(result.collectionID.isEmpty)
    }

    func testAnArchiveArrivesAsOneCollection() throws {
        // The whole point of importing a ZIP as a project: the parts stay
        // together, and the screen has a name to show for them.
        let json = """
        {
          "ok": true,
          "items": [
            {"id": "a", "name_en": "base"},
            {"id": "b", "name_en": "lid"}
          ],
          "collection_id": "col1",
          "collection_name": "kit",
          "notes_ar": ["الملفات دخلت كمشروع واحد"]
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(ImportResult.self, from: json)

        XCTAssertEqual(result.items.count, 2)
        XCTAssertEqual(result.collectionID, "col1")
        XCTAssertEqual(result.collectionName, "kit")
        XCTAssertEqual(result.notesAr.count, 1)
    }

    func testAMissingKeyIsAnAnswerRatherThanAFailure() throws {
        // 200 with `needs_key`: something the user can fix, which an error
        // banner would not tell them.
        let json = """
        {"ok": false, "needs_key": "thingiverse", "items": [], "notes_ar": ["حط المفتاح"]}
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(ImportResult.self, from: json)

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.needsKey, "thingiverse")
        XCTAssertTrue(result.items.isEmpty)
    }

    func testAnOlderBackendWithoutTheNewFieldsStillDecodes() throws {
        let result = try JSONDecoder().decode(
            ImportResult.self, from: #"{"ok": true}"#.data(using: .utf8)!
        )

        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertTrue(result.needsKey.isEmpty)
    }

    // MARK: - Where a model came from

    func testAnItemRemembersItsSource() throws {
        let json = """
        {
          "id": "abc",
          "name_en": "bracket",
          "source_url": "https://example.com/bracket.stl",
          "author": "somebody",
          "licence": "CC-BY"
        }
        """.data(using: .utf8)!

        let item = try JSONDecoder().decode(LibraryItem.self, from: json)

        XCTAssertEqual(item.sourceURL, "https://example.com/bracket.stl")
        XCTAssertEqual(item.author, "somebody")
        XCTAssertEqual(item.licence, "CC-BY")
    }

    func testAnUploadedItemHasNoSourceRatherThanAMissingOne() throws {
        let item = try JSONDecoder().decode(
            LibraryItem.self, from: #"{"id": "abc"}"#.data(using: .utf8)!
        )

        XCTAssertEqual(item.sourceURL, "")
        XCTAssertEqual(item.author, "")
    }
}
