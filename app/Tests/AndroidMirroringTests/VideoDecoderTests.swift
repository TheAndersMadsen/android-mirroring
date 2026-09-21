import XCTest
import CoreMedia
import VideoToolbox
@testable import AndroidMirroring

/// Runs a real H.264 Annex-B stream (ffmpeg testsrc, 320×240, baseline, one
/// slice per frame) through the same Annex-B → AVCC path the app uses and
/// decodes the result with VideoToolbox.
final class VideoDecoderTests: XCTestCase {

    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "testsrc", withExtension: "h264",
                                                  subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testScannerHandlesBothStartCodeLengthsAndSlices() {
        let bytes: [UInt8] = [0xAA, 0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 4, 5]
        let slice = Data(bytes).dropFirst() // startIndex == 1
        let nals = NALScanner.ranges(in: slice).map { [UInt8](slice[$0]) }
        XCTAssertEqual(nals, [[0x67, 1, 2], [0x68, 3], [0x65, 4, 5]])
    }

    func testFixtureDecodesToNonBlackFrames() throws {
        let stream = try fixture()
        let nals = NALScanner.ranges(in: stream)
        let type = { (r: Range<Int>) in stream[r.lowerBound] & 0x1F }

        let sps = try XCTUnwrap(nals.first { type($0) == 7 })
        let pps = try XCTUnwrap(nals.first { type($0) == 8 })
        let format = try XCTUnwrap(VideoDecoder.makeFormatDescription(sps: stream.subdata(in: sps),
                                                                      pps: stream.subdata(in: pps)))
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        XCTAssertEqual(dims.width, 320)
        XCTAssertEqual(dims.height, 240)

        var session: VTDecompressionSession?
        let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
        XCTAssertEqual(VTDecompressionSessionCreate(allocator: nil, formatDescription: format,
                                                    decoderSpecification: nil, imageBufferAttributes: attrs,
                                                    outputCallback: nil, decompressionSessionOut: &session), noErr)
        let vt = try XCTUnwrap(session)
        defer { VTDecompressionSessionInvalidate(vt) }

        var decoded = 0
        var sawColor = false
        // One VCL NAL per access unit in this fixture. Feed each as a slice of
        // the whole stream, so non-zero startIndex is exercised too.
        for (i, r) in nals.enumerated() where type(r) == 1 || type(r) == 5 {
            let au = stream[(r.lowerBound - 4)..<r.upperBound]
            let sb = try XCTUnwrap(VideoDecoder.makeSampleBuffer(
                annexB: au, nals: NALScanner.ranges(in: au), format: format,
                pts: CMTime(value: CMTimeValue(i), timescale: 30)))
            let status = VTDecompressionSessionDecodeFrame(vt, sampleBuffer: sb, flags: [], infoFlagsOut: nil) {
                status, _, image, _, _ in
                guard status == noErr, let image else { return }
                decoded += 1
                CVPixelBufferLockBaseAddress(image, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
                let p = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
                let mid = CVPixelBufferGetBytesPerRow(image) * 120 + 160 * 4
                if p[mid] > 32 || p[mid + 1] > 32 || p[mid + 2] > 32 { sawColor = true }
            }
            XCTAssertEqual(status, noErr)
        }
        VTDecompressionSessionWaitForAsynchronousFrames(vt)
        XCTAssertEqual(decoded, 8)
        XCTAssertTrue(sawColor, "decoded frames are black")
    }
}
