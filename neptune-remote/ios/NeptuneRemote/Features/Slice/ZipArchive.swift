import Compression
import Foundation

/// Read-only ZIP reader, just enough to open a 3MF (which is a ZIP container).
///
/// Supports the two methods 3MF files actually use: stored (0) and deflate (8).
/// Apple's `COMPRESSION_ZLIB` algorithm is raw DEFLATE, which is exactly what
/// ZIP entries contain.
struct ZipArchive {

    struct Entry {
        let name: String
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    enum ZipError: LocalizedError {
        case notAZip
        case corrupt(String)
        case unsupportedCompression(UInt16)

        var errorDescription: String? {
            switch self {
            case .notAZip: return "Not a ZIP/3MF archive"
            case .corrupt(let detail): return "Corrupt archive: \(detail)"
            case .unsupportedCompression(let method):
                return "Unsupported ZIP compression method \(method)"
            }
        }
    }

    let data: Data
    private(set) var entries: [Entry] = []

    init(data: Data) throws {
        self.data = data
        entries = try Self.readCentralDirectory(data)
    }

    func entry(named name: String) -> Entry? {
        entries.first { $0.name == name }
    }

    func firstEntry(withSuffix suffix: String) -> Entry? {
        entries.first { $0.name.lowercased().hasSuffix(suffix.lowercased()) }
    }

    func extract(_ entry: Entry) throws -> Data {
        let signature: UInt32 = try read(at: entry.localHeaderOffset)
        guard signature == 0x0403_4b50 else { throw ZipError.corrupt("bad local header") }

        let nameLength: UInt16 = try read(at: entry.localHeaderOffset + 26)
        let extraLength: UInt16 = try read(at: entry.localHeaderOffset + 28)
        let start = entry.localHeaderOffset + 30 + Int(nameLength) + Int(extraLength)
        let end = start + entry.compressedSize

        guard start >= 0, end <= data.count, start <= end else {
            throw ZipError.corrupt("entry data out of bounds")
        }
        let payload = data.subdata(in: start..<end)

        switch entry.compressionMethod {
        case 0:
            return payload
        case 8:
            return try Self.inflate(payload, expectedSize: entry.uncompressedSize)
        default:
            throw ZipError.unsupportedCompression(entry.compressionMethod)
        }
    }

    // MARK: - Parsing

    private static func readCentralDirectory(_ data: Data) throws -> [Entry] {
        guard data.count > 22 else { throw ZipError.notAZip }

        // Scan backwards for the End Of Central Directory record.
        let maxComment = min(data.count - 22, 65_535)
        var eocd = -1
        var offset = data.count - 22
        while offset >= data.count - 22 - maxComment, offset >= 0 {
            if scalar(UInt32.self, data, offset) == 0x0605_4b50 {
                eocd = offset
                break
            }
            offset -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }

        let count = Int(scalar(UInt16.self, data, eocd + 10))
        var cursor = Int(scalar(UInt32.self, data, eocd + 16))

        var result: [Entry] = []
        result.reserveCapacity(count)

        for _ in 0..<count {
            guard cursor + 46 <= data.count else { throw ZipError.corrupt("central directory truncated") }
            guard scalar(UInt32.self, data, cursor) == 0x0201_4b50 else {
                throw ZipError.corrupt("bad central directory signature")
            }

            let method = scalar(UInt16.self, data, cursor + 10)
            let compressedSize = Int(scalar(UInt32.self, data, cursor + 20))
            let uncompressedSize = Int(scalar(UInt32.self, data, cursor + 24))
            let nameLength = Int(scalar(UInt16.self, data, cursor + 28))
            let extraLength = Int(scalar(UInt16.self, data, cursor + 30))
            let commentLength = Int(scalar(UInt16.self, data, cursor + 32))
            let localOffset = Int(scalar(UInt32.self, data, cursor + 42))

            let nameStart = cursor + 46
            guard nameStart + nameLength <= data.count else {
                throw ZipError.corrupt("file name truncated")
            }
            let name = String(
                data: data.subdata(in: nameStart..<(nameStart + nameLength)),
                encoding: .utf8
            ) ?? ""

            result.append(
                Entry(
                    name: name,
                    compressionMethod: method,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localHeaderOffset: localOffset
                )
            )
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        return result
    }

    private func read<T: FixedWidthInteger>(at offset: Int) throws -> T {
        guard offset >= 0, offset + MemoryLayout<T>.size <= data.count else {
            throw ZipError.corrupt("read out of bounds")
        }
        return Self.scalar(T.self, data, offset)
    }

    /// Little-endian scalar read; ZIP is always little-endian.
    private static func scalar<T: FixedWidthInteger>(_ type: T.Type, _ data: Data, _ offset: Int) -> T {
        guard offset >= 0, offset + MemoryLayout<T>.size <= data.count else { return 0 }
        var value: T = 0
        for index in (0..<MemoryLayout<T>.size).reversed() {
            value = (value << 8) | T(data[data.startIndex + offset + index])
        }
        return value
    }

    static func inflate(_ payload: Data, expectedSize: Int) throws -> Data {
        guard !payload.isEmpty else { return Data() }
        // Some writers store 0 in the central directory; grow generously instead.
        var capacity = expectedSize > 0 ? expectedSize : max(payload.count * 8, 64 * 1024)

        for _ in 0..<4 {
            let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { destination.deallocate() }

            let written = payload.withUnsafeBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    destination, capacity, base, payload.count, nil, COMPRESSION_ZLIB
                )
            }

            if written > 0, written < capacity || written == expectedSize {
                return Data(bytes: destination, count: written)
            }
            if written == capacity, expectedSize > 0 {
                return Data(bytes: destination, count: written)
            }
            capacity *= 4
        }
        throw ZipError.corrupt("could not inflate entry")
    }
}
