import Foundation

/// A real mesh for demo mode.
///
/// Demo models used to have no geometry at all, so in demo mode the slicer's
/// preview and the library's 3D viewer opened onto an empty placeholder - the
/// one place someone trying the app out would most want to see something. This
/// builds an actual printable object instead: a twisted, rippled vase, the same
/// wave motif as the icon, as a binary STL the real loader reads like any file.
///
/// Generated rather than bundled: a few hundred kilobytes of maths beats a
/// few hundred kilobytes of asset, and it can never go missing from the build.
enum DemoMesh {
    /// Built once, on first use.
    static let waveVase: Data = makeWaveVase()

    private static func makeWaveVase(
        segments: Int = 72,
        rings: Int = 64,
        height: Float = 120,
        baseRadius: Float = 34
    ) -> Data {
        // The outer surface, ring by ring from the base up.
        func radius(_ angle: Float, _ z: Float) -> Float {
            let t = z / height
            // Swells, pinches at the waist, flares at the lip.
            let profile = baseRadius * (1 + 0.35 * sin(t * .pi * 1.15) - 0.18 * t)
            let ripple = 1 + 0.07 * sin(angle * 6 + t * 7.5)
            return profile * ripple
        }

        var grid: [[SIMD3<Float>]] = []
        for ring in 0...rings {
            let z = height * Float(ring) / Float(rings)
            var row: [SIMD3<Float>] = []
            for segment in 0..<segments {
                let angle = 2 * Float.pi * Float(segment) / Float(segments)
                let r = radius(angle, z)
                row.append(SIMD3(r * cos(angle), r * sin(angle), z))
            }
            grid.append(row)
        }

        var triangles: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
        triangles.reserveCapacity(rings * segments * 2 + segments)
        for ring in 0..<rings {
            for segment in 0..<segments {
                let next = (segment + 1) % segments
                let a = grid[ring][segment], b = grid[ring][next]
                let c = grid[ring + 1][segment], d = grid[ring + 1][next]
                // Counter-clockwise seen from outside, so normals face out.
                triangles.append((a, b, d))
                triangles.append((a, d, c))
            }
        }
        // A closed base, so it reads as an object rather than a tube.
        let centre = SIMD3<Float>(0, 0, 0)
        for segment in 0..<segments {
            let next = (segment + 1) % segments
            triangles.append((centre, grid[0][next], grid[0][segment]))
        }

        var data = Data()
        var header = Array("NEPTUNE DEMO WAVE VASE".utf8)
        header += Array(repeating: 0, count: 80 - header.count)
        data.append(contentsOf: header)
        appendUInt32(&data, UInt32(triangles.count))
        for (a, b, c) in triangles {
            let normal = simd_normalize_safe(cross3(b - a, c - a))
            for value in [normal, a, b, c] {
                appendFloat(&data, value.x)
                appendFloat(&data, value.y)
                appendFloat(&data, value.z)
            }
            data.append(contentsOf: [0, 0])
        }
        return data
    }

    private static func cross3(_ u: SIMD3<Float>, _ v: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x)
    }

    private static func simd_normalize_safe(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let length = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        return length > 0 ? v / length : SIMD3(0, 0, 1)
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func appendFloat(_ data: inout Data, _ value: Float) {
        var little = value.bitPattern.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}
