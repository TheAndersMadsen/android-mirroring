import Foundation

/// Serial, order-preserving parser for the scrcpy v4.1 video socket:
/// dummy byte → 64-byte device name → u32 codec-id → framed packets.
/// All state lives on `queue`; callbacks hop to the caller's context.
final class VideoStreamParser {

    enum Stage {
        case dummy
        case deviceMeta
        case codecId
        case packets
        case failed
    }

    var onDeviceName: ((String) -> Void)?
    var onVideoSize: ((CGSize) -> Void)?
    var onPacket: ((Data, UInt64, Bool) -> Void)? // payload, ptsUs, config
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "android-mirroring.stream-parser")
    private var buffer = Data()
    private var stage: Stage = .dummy

    func reset() {
        queue.async { [weak self] in
            self?.buffer = Data()
            self?.stage = .dummy
        }
    }

    /// The video socket's dummy byte is consumed while probing for server
    /// readiness, so parsing begins at the device-metadata stage.
    func skipDummy() {
        queue.async { [weak self] in
            self?.stage = .deviceMeta
        }
    }

    func feed(_ data: Data) {
        queue.async { [weak self] in
            self?.buffer.append(data)
            self?.parse()
        }
    }

    // MARK: - Parsing (queue only)

    private func parse() {
        switch stage {
        case .dummy:
            guard buffer.count >= 1 else { return }
            buffer.removeFirst(1)
            stage = .deviceMeta
            fallthrough
        case .deviceMeta:
            guard buffer.count >= 64 else { return }
            let meta = buffer.prefix(64)
            buffer.removeFirst(64)
            let name = String(data: Data(meta), encoding: .utf8)?
                .split(separator: "\0").first.map(String.init) ?? "Android"
            onDeviceName?(name)
            stage = .codecId
            fallthrough
        case .codecId:
            guard buffer.count >= 4 else { return }
            let codecId = readU32(at: 0)
            buffer.removeFirst(4)
            switch codecId {
            case ScrcpyWire.h264CodecId:
                stage = .packets
            case 0:
                fail("Device disabled the video stream")
                return
            case 1:
                fail("Device reported a configuration error")
                return
            default:
                fail("Unsupported codec id 0x\(String(codecId, radix: 16))")
                return
            }
            fallthrough
        case .packets:
            parsePackets()
        case .failed:
            buffer = Data()
        }
    }

    private func fail(_ message: String) {
        stage = .failed
        buffer = Data()
        onError?(message)
    }

    private func parsePackets() {
        while buffer.count >= 12 {
            let first64 = readU64(at: 0)
            if first64 & (1 << 63) != 0 {
                // Session packet: [flags u32 = 0x8000_0000 | resized][w u32][h u32]
                let width = UInt32(truncatingIfNeeded: first64)
                let height = readU32(at: 8)
                buffer.removeFirst(12)
                if width > 0, height > 0 {
                    onVideoSize?(CGSize(width: CGFloat(width), height: CGFloat(height)))
                }
            } else {
                let size = Int(readU32(at: 8))
                guard buffer.count - 12 >= size else { return } // wait for more
                let start = buffer.startIndex + 12
                let payload = Data(buffer[start..<(start + size)])
                buffer.removeFirst(12 + size)
                let config = first64 & (1 << 62) != 0
                let pts = first64 & ((1 << 61) - 1)
                onPacket?(payload, pts, config)
            }
        }
    }

    private func readU32(at offset: Int) -> UInt32 {
        var v: UInt32 = 0
        for i in 0..<4 {
            v = (v &<< 8) | UInt32(buffer[buffer.startIndex + offset + i])
        }
        return v
    }

    private func readU64(at offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 {
            v = (v &<< 8) | UInt64(buffer[buffer.startIndex + offset + i])
        }
        return v
    }
}
