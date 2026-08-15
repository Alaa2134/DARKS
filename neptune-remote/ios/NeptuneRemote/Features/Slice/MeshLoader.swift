import Foundation
import SceneKit
import simd

/// Triangle mesh loaded from a model file, ready to hand to SceneKit.
struct LoadedMesh {
    var positions: [SCNVector3]
    var normals: [SCNVector3]
    var triangleCount: Int
    var minimum: SIMD3<Float>
    var maximum: SIMD3<Float>

    var size: SIMD3<Float> { maximum - minimum }
    var center: SIMD3<Float> { (maximum + minimum) / 2 }

    var boundingBoxDescription: String {
        String(format: "%.1f × %.1f × %.1f mm", size.x, size.y, size.z)
    }
}

enum MeshLoaderError: LocalizedError {
    case unsupportedFormat(String)
    case emptyMesh
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return L.t("preview.unsupported", ext)
        case .emptyMesh:
            return L.t("preview.empty")
        case .parseFailed(let detail):
            return "\(L.t("preview.failed")): \(detail)"
        }
    }
}

/// Parses STL (binary + ASCII), OBJ and 3MF entirely on device.
enum MeshLoader {

    static func load(data: Data, filename: String) throws -> LoadedMesh {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "stl":
            return try loadSTL(data: data)
        case "obj":
            return try loadOBJ(data: data)
        case "3mf":
            return try load3MF(data: data)
        default:
            throw MeshLoaderError.unsupportedFormat(ext.isEmpty ? "?" : ext)
        }
    }

    static var supportedExtensions: [String] { ["stl", "obj", "3mf"] }

    // MARK: - STL

    static func loadSTL(data: Data) throws -> LoadedMesh {
        if isASCIISTL(data) {
            return try loadASCIISTL(data: data)
        }
        return try loadBinarySTL(data: data)
    }

    private static func isASCIISTL(_ data: Data) -> Bool {
        guard data.count > 84 else { return true }
        let header = data.prefix(6)
        guard let text = String(data: header, encoding: .ascii)?.lowercased() else { return false }
        guard text.hasPrefix("solid") else { return false }
        // A binary STL can also start with "solid"; verify with the triangle count.
        let count = Int(readUInt32(data, at: 80))
        return data.count != 84 + count * 50
    }

    private static func loadBinarySTL(data: Data) throws -> LoadedMesh {
        guard data.count >= 84 else { throw MeshLoaderError.parseFailed("file too small") }
        let count = Int(readUInt32(data, at: 80))
        guard count > 0 else { throw MeshLoaderError.emptyMesh }
        guard data.count >= 84 + count * 50 else {
            throw MeshLoaderError.parseFailed("truncated binary STL")
        }

        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        positions.reserveCapacity(count * 3)
        normals.reserveCapacity(count * 3)

        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

        for index in 0..<count {
            let base = 84 + index * 50
            let nx = readFloat(data, at: base)
            let ny = readFloat(data, at: base + 4)
            let nz = readFloat(data, at: base + 8)
            let normal = SCNVector3(nx, ny, nz)

            for vertex in 0..<3 {
                let offset = base + 12 + vertex * 12
                let point = SIMD3<Float>(
                    readFloat(data, at: offset),
                    readFloat(data, at: offset + 4),
                    readFloat(data, at: offset + 8)
                )
                positions.append(SCNVector3(point.x, point.y, point.z))
                normals.append(normal)
                minimum = SIMD3(min(minimum.x, point.x), min(minimum.y, point.y), min(minimum.z, point.z))
                maximum = SIMD3(max(maximum.x, point.x), max(maximum.y, point.y), max(maximum.z, point.z))
            }
        }

        return LoadedMesh(
            positions: positions, normals: normals, triangleCount: count,
            minimum: minimum, maximum: maximum
        )
    }

    private static func loadASCIISTL(data: Data) throws -> LoadedMesh {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { throw MeshLoaderError.parseFailed("not readable text") }

        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var currentNormal = SCNVector3(0, 0, 1)

        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

        text.enumerateLines { line, _ in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let keyword = parts.first?.lowercased() else { return }

            if keyword == "facet", parts.count >= 5, parts[1].lowercased() == "normal" {
                currentNormal = SCNVector3(
                    Float(parts[2]) ?? 0, Float(parts[3]) ?? 0, Float(parts[4]) ?? 0
                )
            } else if keyword == "vertex", parts.count >= 4 {
                let point = SIMD3<Float>(
                    Float(parts[1]) ?? 0, Float(parts[2]) ?? 0, Float(parts[3]) ?? 0
                )
                positions.append(SCNVector3(point.x, point.y, point.z))
                normals.append(currentNormal)
                minimum = SIMD3(min(minimum.x, point.x), min(minimum.y, point.y), min(minimum.z, point.z))
                maximum = SIMD3(max(maximum.x, point.x), max(maximum.y, point.y), max(maximum.z, point.z))
            }
        }

        guard positions.count >= 3 else { throw MeshLoaderError.emptyMesh }
        return LoadedMesh(
            positions: positions, normals: normals, triangleCount: positions.count / 3,
            minimum: minimum, maximum: maximum
        )
    }

    // MARK: - OBJ

    static func loadOBJ(data: Data) throws -> LoadedMesh {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { throw MeshLoaderError.parseFailed("not readable text") }

        var vertices: [SIMD3<Float>] = []
        var faces: [[Int]] = []

        text.enumerateLines { line, _ in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let keyword = parts.first else { return }

            if keyword == "v", parts.count >= 4 {
                vertices.append(
                    SIMD3(Float(parts[1]) ?? 0, Float(parts[2]) ?? 0, Float(parts[3]) ?? 0)
                )
            } else if keyword == "f", parts.count >= 4 {
                // "f 1/1/1 2/2/2 3//3" - only the position index matters here.
                let indices: [Int] = parts.dropFirst().compactMap { token in
                    guard let first = token.split(separator: "/").first, let value = Int(first) else {
                        return nil
                    }
                    return value > 0 ? value - 1 : vertices.count + value
                }
                if indices.count >= 3 { faces.append(indices) }
            }
        }

        guard !vertices.isEmpty, !faces.isEmpty else { throw MeshLoaderError.emptyMesh }

        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

        for face in faces {
            // Triangulate the polygon as a fan.
            for index in 1..<(face.count - 1) {
                let triangle = [face[0], face[index], face[index + 1]]
                guard triangle.allSatisfy({ $0 >= 0 && $0 < vertices.count }) else { continue }
                let points = triangle.map { vertices[$0] }
                let normal = faceNormal(points[0], points[1], points[2])
                for point in points {
                    positions.append(SCNVector3(point.x, point.y, point.z))
                    normals.append(SCNVector3(normal.x, normal.y, normal.z))
                    minimum = SIMD3(min(minimum.x, point.x), min(minimum.y, point.y), min(minimum.z, point.z))
                    maximum = SIMD3(max(maximum.x, point.x), max(maximum.y, point.y), max(maximum.z, point.z))
                }
            }
        }

        guard positions.count >= 3 else { throw MeshLoaderError.emptyMesh }
        return LoadedMesh(
            positions: positions, normals: normals, triangleCount: positions.count / 3,
            minimum: minimum, maximum: maximum
        )
    }

    // MARK: - 3MF

    static func load3MF(data: Data) throws -> LoadedMesh {
        let archive: ZipArchive
        do {
            archive = try ZipArchive(data: data)
        } catch {
            throw MeshLoaderError.parseFailed(error.localizedDescription)
        }

        guard let entry = archive.entry(named: "3D/3dmodel.model")
            ?? archive.firstEntry(withSuffix: ".model")
        else { throw MeshLoaderError.parseFailed("no 3D model part inside the 3MF") }

        let xml: Data
        do {
            xml = try archive.extract(entry)
        } catch {
            throw MeshLoaderError.parseFailed(error.localizedDescription)
        }

        let parser = ThreeMFParser()
        guard let mesh = parser.parse(xml) else {
            throw MeshLoaderError.parseFailed("could not read the 3MF mesh")
        }
        return mesh
    }

    // MARK: - Helpers

    static func faceNormal(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> SIMD3<Float> {
        let normal = cross(b - a, c - a)
        let length = simd_length(normal)
        return length > 0 ? normal / length : SIMD3(0, 0, 1)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        var value: UInt32 = 0
        for index in (0..<4).reversed() {
            value = (value << 8) | UInt32(data[data.startIndex + offset + index])
        }
        return value
    }

    private static func readFloat(_ data: Data, at offset: Int) -> Float {
        Float(bitPattern: readUInt32(data, at: offset))
    }
}

/// Streaming XML reader for the `<mesh>` inside a 3MF model part.
private final class ThreeMFParser: NSObject, XMLParserDelegate {
    private var vertices: [SIMD3<Float>] = []
    private var triangles: [(Int, Int, Int)] = []

    func parse(_ data: Data) -> LoadedMesh? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse(), !vertices.isEmpty, !triangles.isEmpty else { return nil }

        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

        for triangle in triangles {
            let indices = [triangle.0, triangle.1, triangle.2]
            guard indices.allSatisfy({ $0 >= 0 && $0 < vertices.count }) else { continue }
            let points = indices.map { vertices[$0] }
            let normal = MeshLoader.faceNormal(points[0], points[1], points[2])
            for point in points {
                positions.append(SCNVector3(point.x, point.y, point.z))
                normals.append(SCNVector3(normal.x, normal.y, normal.z))
                minimum = SIMD3(min(minimum.x, point.x), min(minimum.y, point.y), min(minimum.z, point.z))
                maximum = SIMD3(max(maximum.x, point.x), max(maximum.y, point.y), max(maximum.z, point.z))
            }
        }

        guard positions.count >= 3 else { return nil }
        return LoadedMesh(
            positions: positions, normals: normals, triangleCount: positions.count / 3,
            minimum: minimum, maximum: maximum
        )
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        switch elementName.lowercased() {
        case "vertex":
            vertices.append(
                SIMD3(
                    Float(attributes["x"] ?? "0") ?? 0,
                    Float(attributes["y"] ?? "0") ?? 0,
                    Float(attributes["z"] ?? "0") ?? 0
                )
            )
        case "triangle":
            guard let v1 = Int(attributes["v1"] ?? ""),
                  let v2 = Int(attributes["v2"] ?? ""),
                  let v3 = Int(attributes["v3"] ?? "")
            else { return }
            triangles.append((v1, v2, v3))
        default:
            break
        }
    }
}
