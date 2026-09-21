import XCTest
@testable import AndroidMirroring

final class VideoStreamParserTests: XCTestCase {

    private func be32(_ v: UInt32) -> Data { var d = Data(); d.appendBE(v); return d }
    private func be64(_ v: UInt64) -> Data { var d = Data(); d.appendBE(v); return d }

    /// Whole handshake + session + config + media packet, delivered one byte
    /// at a time and then in a single chunk: results must be identical.
    func testStreamParsesRegardlessOfChunking() {
        var stream = Data([0]) // dummy byte
        var name = Data("Pixel 9".utf8)
        name.append(Data(count: 64 - name.count))
        stream.append(name)
        stream.append(be32(ScrcpyWire.h264CodecId))
        stream.append(be32(0x8000_0000)); stream.append(be32(1080)); stream.append(be32(2400)) // session
        stream.append(be64(1 << 62)); stream.append(be32(3)); stream.append(Data([1, 2, 3]))   // config
        stream.append(be64(123_456)); stream.append(be32(2)); stream.append(Data([9, 8]))      // media

        for chunk in [1, stream.count] {
            let parser = VideoStreamParser()
            let done = expectation(description: "media packet, chunk \(chunk)")
            var events: [String] = []
            parser.onDeviceName = { events.append("name:\($0)") }
            parser.onVideoSize = { events.append("size:\(Int($0.width))x\(Int($0.height))") }
            parser.onPacket = { payload, pts, config in
                events.append("packet:\([UInt8](payload)):\(pts):\(config)")
                if !config { done.fulfill() }
            }
            parser.onError = { XCTFail($0) }
            var i = 0
            while i < stream.count {
                parser.feed(stream.subdata(in: i..<min(i + chunk, stream.count)))
                i += chunk
            }
            wait(for: [done], timeout: 2)
            XCTAssertEqual(events, ["name:Pixel 9", "size:1080x2400",
                                    "packet:[1, 2, 3]:0:true", "packet:[9, 8]:123456:false"])
        }
    }

    func testUnsupportedCodecFailsOnceAndIgnoresTheRest() {
        let parser = VideoStreamParser()
        parser.skipDummy()
        let failed = expectation(description: "error")
        parser.onError = { _ in failed.fulfill() } // over-fulfil = test failure
        parser.onPacket = { _, _, _ in XCTFail("packet after failure") }
        var stream = Data(count: 64)
        stream.append(be32(0x6832_3635)) // "h265"
        stream.append(Data(count: 64))
        parser.feed(stream)
        parser.feed(Data(count: 64))
        wait(for: [failed], timeout: 2)
    }
}

final class ScrcpyWireTests: XCTestCase {

    func testInjectTouchLayout() {
        let d = ScrcpyWire.injectTouch(action: ScrcpyWire.actionDown, x: 100, y: 200,
                                       screenW: 1080, screenH: 2400, pressure: 1)
        XCTAssertEqual([UInt8](d), [
            2, 0,
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            0, 0, 0, 100, 0, 0, 0, 200,
            0x04, 0x38, 0x09, 0x60,
            0xFF, 0xFF,
            0, 0, 0, 1, 0, 0, 0, 1,
        ])
    }

    func testScrollIsClampedAndSigned() {
        let d = [UInt8](ScrcpyWire.injectScroll(x: 0, y: 0, screenW: 1, screenH: 1, hscroll: -5, vscroll: 1.0 / 16))
        XCTAssertEqual(d.count, 21)
        XCTAssertEqual(Array(d[13..<15]), [0x80, 0x01]) // -32767
        XCTAssertEqual(Array(d[15..<17]), [0x08, 0x00]) // one scroll unit
    }
}

final class DeviceMonitorTests: XCTestCase {

    func testParseDevicesOutput() {
        let out = """
        List of devices attached
        R58N1234ABC         device usb:0-1 product:panther model:Pixel_7 device:panther transport_id:16
        emulator-5554          offline
        ABC123                 unauthorized usb:1-1 transport_id:2
        * daemon started successfully

        """
        let devices = DeviceMonitor.parse(out)
        XCTAssertEqual(devices.map(\.serial), ["R58N1234ABC", "emulator-5554", "ABC123"])
        XCTAssertEqual(devices[0].model, "Pixel_7")
        XCTAssertEqual(devices.map(\.isReady), [true, false, false])
    }
}
