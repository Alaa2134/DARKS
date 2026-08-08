import SceneKit
import XCTest
@testable import NeptuneRemote

final class MeshLoaderTests: XCTestCase {

    /// A single triangle written as a binary STL.
    private func binarySTL() -> Data {
        var data = Data(count: 80)                       // header
        var count: UInt32 = 1
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }

        func append(_ value: Float) {
            var bits = value.bitPattern
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }

        append(0); append(0); append(1)                  // normal
        append(0); append(0); append(0)                  // v1
        append(10); append(0); append(0)                 // v2
        append(0); append(20); append(5)                 // v3
        data.append(contentsOf: [0, 0])                  // attribute byte count
        return data
    }

    private let asciiSTL = """
    solid cube
      facet normal 0 0 1
        outer loop
          vertex 0 0 0
          vertex 10 0 0
          vertex 0 20 5
        endloop
      endfacet
    endsolid cube
    """

    private let objText = """
    # a single quad, which must be triangulated into two triangles
    v 0 0 0
    v 10 0 0
    v 10 20 0
    v 0 20 0
    f 1//1 2//2 3//3 4//4
    """

    func testBinarySTL() throws {
        let mesh = try MeshLoader.load(data: binarySTL(), filename: "cube.stl")
        XCTAssertEqual(mesh.triangleCount, 1)
        XCTAssertEqual(mesh.positions.count, 3)
        XCTAssertEqual(mesh.minimum.x, 0, accuracy: 0.001)
        XCTAssertEqual(mesh.maximum.x, 10, accuracy: 0.001)
        XCTAssertEqual(mesh.maximum.y, 20, accuracy: 0.001)
        XCTAssertEqual(mesh.maximum.z, 5, accuracy: 0.001)
        XCTAssertEqual(mesh.size.x, 10, accuracy: 0.001)
    }

    func testASCIISTL() throws {
        let mesh = try MeshLoader.load(data: Data(asciiSTL.utf8), filename: "cube.stl")
        XCTAssertEqual(mesh.triangleCount, 1)
        XCTAssertEqual(mesh.size.y, 20, accuracy: 0.001)
    }

    func testOBJQuadIsTriangulated() throws {
        let mesh = try MeshLoader.load(data: Data(objText.utf8), filename: "quad.obj")
        XCTAssertEqual(mesh.triangleCount, 2)
        XCTAssertEqual(mesh.positions.count, 6)
        XCTAssertEqual(mesh.size.x, 10, accuracy: 0.001)
        XCTAssertEqual(mesh.size.y, 20, accuracy: 0.001)
    }

    func testUnsupportedExtension() {
        XCTAssertThrowsError(try MeshLoader.load(data: Data([1, 2, 3]), filename: "model.step2")) { error in
            guard case MeshLoaderError.unsupportedFormat = error else {
                return XCTFail("expected unsupportedFormat, got \(error)")
            }
        }
    }

    func testEmptySTLThrows() {
        XCTAssertThrowsError(try MeshLoader.load(data: Data(), filename: "x.stl"))
    }

    func testBoundingBoxDescription() throws {
        let mesh = try MeshLoader.load(data: binarySTL(), filename: "cube.stl")
        XCTAssertTrue(mesh.boundingBoxDescription.contains("10.0"))
        XCTAssertTrue(mesh.boundingBoxDescription.contains("mm"))
    }

    func testFaceNormalIsUnitLength() {
        let normal = MeshLoader.faceNormal(
            SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)
        )
        XCTAssertEqual(simd_length(normal), 1, accuracy: 0.0001)
        XCTAssertEqual(normal.z, 1, accuracy: 0.0001)
    }

    func testDegenerateTriangleDoesNotProduceNaN() {
        let normal = MeshLoader.faceNormal(SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(0, 0, 0))
        XCTAssertFalse(normal.x.isNaN)
        XCTAssertFalse(normal.y.isNaN)
        XCTAssertFalse(normal.z.isNaN)
    }

    // MARK: - 3MF / ZIP

    func testStoredZipEntryIsExtracted() throws {
        // Build a tiny ZIP with one stored (uncompressed) entry.
        let name = "3D/3dmodel.model"
        let payload = Data("""
        <?xml version="1.0"?>
        <model><resources><object id="1"><mesh>
        <vertices>
        <vertex x="0" y="0" z="0"/><vertex x="10" y="0" z="0"/><vertex x="0" y="20" z="4"/>
        </vertices>
        <triangles><triangle v1="0" v2="1" v3="2"/></triangles>
        </mesh></object></resources></model>
        """.utf8)

        let zip = Self.makeStoredZip(name: name, payload: payload)
        let mesh = try MeshLoader.load(data: zip, filename: "part.3mf")
        XCTAssertEqual(mesh.triangleCount, 1)
        XCTAssertEqual(mesh.size.x, 10, accuracy: 0.001)
        XCTAssertEqual(mesh.size.z, 4, accuracy: 0.001)
    }

    func testNonZipIs3MFParseError() {
        XCTAssertThrowsError(try MeshLoader.load(data: Data("not a zip".utf8), filename: "x.3mf"))
    }

    /// Minimal ZIP writer (stored method) used only by these tests.
    private static func makeStoredZip(name: String, payload: Data) -> Data {
        let nameBytes = Data(name.utf8)
        let crc = crc32(payload)
        var data = Data()

        func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

        // Local file header
        let localOffset = UInt32(data.count)
        data.append(le32(0x0403_4b50))
        data.append(le16(20))                       // version needed
        data.append(le16(0))                        // flags
        data.append(le16(0))                        // stored
        data.append(le16(0)); data.append(le16(0))  // time, date
        data.append(le32(crc))
        data.append(le32(UInt32(payload.count)))
        data.append(le32(UInt32(payload.count)))
        data.append(le16(UInt16(nameBytes.count)))
        data.append(le16(0))
        data.append(nameBytes)
        data.append(payload)

        // Central directory
        let centralOffset = UInt32(data.count)
        data.append(le32(0x0201_4b50))
        data.append(le16(20)); data.append(le16(20))
        data.append(le16(0)); data.append(le16(0))
        data.append(le16(0)); data.append(le16(0))
        data.append(le32(crc))
        data.append(le32(UInt32(payload.count)))
        data.append(le32(UInt32(payload.count)))
        data.append(le16(UInt16(nameBytes.count)))
        data.append(le16(0)); data.append(le16(0))
        data.append(le16(0)); data.append(le16(0))
        data.append(le32(0))
        data.append(le32(localOffset))
        data.append(nameBytes)
        let centralSize = UInt32(data.count) - centralOffset

        // End of central directory
        data.append(le32(0x0605_4b50))
        data.append(le16(0)); data.append(le16(0))
        data.append(le16(1)); data.append(le16(1))
        data.append(le32(centralSize))
        data.append(le32(centralOffset))
        data.append(le16(0))
        return data
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
            }
            table[index] = value
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
