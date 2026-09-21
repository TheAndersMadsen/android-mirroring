import XCTest
@testable import AndroidMirroring

final class AudioJitterBufferTests: XCTestCase {

    /// Interleaved ramp: frame i → (i, -i). Any drop, repeat or channel
    /// swap shows up as a break in the sequence.
    private func ramp(from start: Int, frames: Int) -> [Float] {
        (start..<(start + frames)).flatMap { [Float($0), -Float($0)] }
    }

    private func pull(_ jb: AudioJitterBuffer, _ frames: Int) -> (l: [Float], r: [Float]) {
        var l = [Float](repeating: 99, count: frames)
        var r = [Float](repeating: 99, count: frames)
        jb.read(left: &l, right: &r, frames: frames)
        return (l, r)
    }

    func testHoldsSilenceUntilTargetThenPlaysEverySampleInOrder() {
        let jb = AudioJitterBuffer(sampleRate: 48000) // target 2880 frames
        jb.write(ramp(from: 0, frames: 1000), frames: 1000)
        XCTAssertEqual(pull(jb, 512).l, [Float](repeating: 0, count: 512), "played before target was reached")

        // Bursty arrival against a steady 512-frame pull, wrapping the ring
        // several times. Arrival averages the pull rate, so no underruns.
        var written = 1000
        var played: [Float] = []
        var playedR: [Float] = []
        for step in 0..<400 {
            if step % 4 == 0 {
                jb.write(ramp(from: written, frames: 2048), frames: 2048)
                written += 2048
            }
            let out = pull(jb, 512)
            played += out.l
            playedR += out.r
        }
        let firstNonSilent = played.firstIndex { $0 != 0 } ?? 0
        let body = Array(played[firstNonSilent...])
        XCTAssertEqual(body.first, 1) // frame 0 is value 0, indistinguishable from silence
        for (i, v) in body.enumerated() {
            guard v == Float(i + 1) else { return XCTFail("discontinuity at \(i): \(v)") }
        }
        XCTAssertEqual(Array(playedR[firstNonSilent...]), body.map { -$0 })
        let stats = jb.takeStats()
        XCTAssertEqual(stats.underruns, 0)
        XCTAssertEqual(stats.skips, 0)
    }

    func testUnderrunRebuffersOnceInsteadOfStuttering() {
        let jb = AudioJitterBuffer(sampleRate: 48000)
        jb.write(ramp(from: 1, frames: 3000), frames: 3000)
        _ = pull(jb, 2900)
        let tail = pull(jb, 512) // only 100 left
        XCTAssertEqual(Array(tail.l[..<100]), (2901...3000).map(Float.init))
        XCTAssertEqual(Array(tail.l[100...]), [Float](repeating: 0, count: 412))

        // A trickle below target must stay silent, not leak out in fragments.
        jb.write(ramp(from: 3001, frames: 500), frames: 500)
        XCTAssertEqual(pull(jb, 256).l, [Float](repeating: 0, count: 256))
        jb.write(ramp(from: 3501, frames: 2400), frames: 2400)
        XCTAssertEqual(pull(jb, 4).l, [3001, 3002, 3003, 3004])
        XCTAssertEqual(jb.takeStats().underruns, 1)
    }

    func testBacklogIsSkippedBackToTarget() {
        let jb = AudioJitterBuffer(sampleRate: 48000) // max 8640, target 2880
        jb.write(ramp(from: 1, frames: 9000), frames: 9000)
        XCTAssertEqual(pull(jb, 2).l, [6121, 6122]) // newest 2880 frames kept
        XCTAssertEqual(jb.takeStats().skips, 1)
    }
}

final class AudioStreamParserTests: XCTestCase {

    /// A 1 kHz stereo sine as the device would send it (codec id, a config
    /// packet that must be ignored, then s16le packets), delivered in
    /// awkward chunk sizes. Output must be the same sine, sample for sample.
    func testRawStreamSurvivesArbitraryChunking() {
        func be(_ v: UInt64, _ bytes: Int) -> Data {
            Data((0..<bytes).reversed().map { UInt8(truncatingIfNeeded: v >> (UInt64($0) * 8)) })
        }
        let frames = 4800
        var expected: [Int16] = []
        for i in 0..<frames {
            let v = Int16(sin(Double(i) * 2 * .pi * 1000 / 48000) * 20000)
            expected += [v, -v] // L, R
        }
        var stream = be(UInt64(AudioStreamParser.rawCodecId), 4)
        stream += be(1 << 62, 8) + be(3, 4) + Data([1, 2, 3]) // config packet
        var i = 0
        var pts: UInt64 = 0
        while i < expected.count {
            let n = min(1024 * 2, expected.count - i)
            var payload = Data()
            for v in expected[i..<(i + n)] { withUnsafeBytes(of: v.littleEndian) { payload.append(contentsOf: $0) } }
            stream += be(pts, 8) + be(UInt64(payload.count), 4) + payload
            i += n
            pts += 21_333
        }

        for chunk in [1, 7, 1000, stream.count] {
            let parser = AudioStreamParser()
            var got: [Float] = []
            parser.onSamples = { samples, frames in
                XCTAssertEqual(samples.count, frames * 2)
                got += samples
            }
            var o = 0
            while o < stream.count {
                parser.feed(stream.subdata(in: o..<min(o + chunk, stream.count)))
                o += chunk
            }
            XCTAssertEqual(got, expected.map { Float($0) / 32768 }, "chunk size \(chunk)")
        }
    }
}
