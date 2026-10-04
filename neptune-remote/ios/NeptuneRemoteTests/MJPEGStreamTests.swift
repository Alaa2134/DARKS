import XCTest
@testable import NeptuneRemote

/// The frame assembler is the piece that decides whether the app stays
/// responsive while a camera is on screen, so it is tested on its own rather
/// than through a live stream.
final class MJPEGFrameAssemblerTests: XCTestCase {

    private let soi = Data([0xFF, 0xD8])
    private let eoi = Data([0xFF, 0xD9])

    /// A fake JPEG: correct markers, arbitrary payload. The assembler only ever
    /// looks at the markers - decoding is somebody else's job.
    private func frame(payload: UInt8, bytes: Int = 64) -> Data {
        var data = soi
        data.append(Data(repeating: payload, count: bytes))
        data.append(eoi)
        return data
    }

    private func boundary(_ text: String = "--frameboundary\r\nContent-Type: image/jpeg\r\n\r\n") -> Data {
        Data(text.utf8)
    }

    func testASingleWholeFrameComesBackIntact() {
        let assembler = MJPEGFrameAssembler()
        let expected = frame(payload: 0xAB)

        let result = assembler.consume(boundary() + expected)

        XCTAssertEqual(result, expected)
        XCTAssertEqual(assembler.dropped, 0)
    }

    func testAFrameSplitAcrossManyReadsIsReassembled() {
        let assembler = MJPEGFrameAssembler()
        let expected = frame(payload: 0x11, bytes: 500)
        let whole = boundary() + expected

        var result: Data?
        // Deliberately small reads, and one of them lands between the two bytes
        // of a marker - the case the resume-from-where-we-stopped search has to
        // get right, and the reason it backs up one byte.
        for chunk in stride(from: 0, to: whole.count, by: 7) {
            let end = min(chunk + 7, whole.count)
            if let frame = assembler.consume(whole.subdata(in: chunk..<end)) {
                result = frame
            }
        }

        XCTAssertEqual(result, expected)
    }

    func testOnlyTheNewestFrameInOneReadIsReturned() {
        let assembler = MJPEGFrameAssembler()
        let first = frame(payload: 0x01)
        let second = frame(payload: 0x02)
        let third = frame(payload: 0x03)

        let result = assembler.consume(boundary() + first + boundary() + second + boundary() + third)

        // The first two were about to be painted over. Decoding them is exactly
        // how a stream that falls behind once never catches up.
        XCTAssertEqual(result, third)
        XCTAssertEqual(assembler.dropped, 2)
    }

    func testSuccessiveReadsEachYieldTheirOwnFrame() {
        let assembler = MJPEGFrameAssembler()
        let first = frame(payload: 0x0A)
        let second = frame(payload: 0x0B)

        XCTAssertEqual(assembler.consume(boundary() + first), first)
        XCTAssertEqual(assembler.consume(boundary() + second), second)
        XCTAssertEqual(assembler.dropped, 0)
    }

    func testHeaderNoiseWithNoFrameDoesNotAccumulate() {
        let assembler = MJPEGFrameAssembler()

        // Multipart headers arriving without any image data must not be kept:
        // this is what made the buffer creep upwards over a long print.
        for _ in 0..<2_000 {
            XCTAssertNil(assembler.consume(boundary()))
        }

        // Still able to find the next real frame once it turns up.
        let expected = frame(payload: 0x7F)
        XCTAssertEqual(assembler.consume(expected), expected)
    }

    func testAStreamWithNoMarkersAtAllNeverGrows() {
        let assembler = MJPEGFrameAssembler()
        let junk = Data(repeating: 0x41, count: 1_000_000)   // "AAAA…", no markers

        for _ in 0..<40 {
            XCTAssertNil(assembler.consume(junk))
        }

        // Forty megabytes in, well past the 16 MB ceiling, and it has not had to
        // panic: with no start marker in sight there is nothing worth keeping,
        // so the buffer is trimmed on every read instead of filling up.
        XCTAssertFalse(assembler.overflowed)
    }

    func testAStartMarkerWithNoEndIsAbandonedAtTheBufferLimit() {
        let assembler = MJPEGFrameAssembler()
        // A start marker followed by bytes that never end - an H.264 stream that
        // happens to contain 0xFFD8 somewhere in it.
        _ = assembler.consume(soi)

        var reads = 0
        while !assembler.overflowed && reads < 64 {
            _ = assembler.consume(Data(repeating: 0x00, count: 1_000_000))
            reads += 1
        }

        XCTAssertTrue(assembler.overflowed, "an endless frame has to be abandoned, not buffered forever")

        // And it recovers: the next real frame still comes through.
        let expected = frame(payload: 0x5A)
        XCTAssertEqual(assembler.consume(expected), expected)
    }

    func testResetClearsAPartialFrame() {
        let assembler = MJPEGFrameAssembler()
        _ = assembler.consume(soi + Data(repeating: 0x22, count: 100))
        assembler.reset()

        let expected = frame(payload: 0x33)
        XCTAssertEqual(assembler.consume(expected), expected)
    }
}
