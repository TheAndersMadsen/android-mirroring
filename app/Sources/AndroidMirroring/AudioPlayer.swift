import AVFoundation
import Foundation

/// Streams raw PCM audio from the scrcpy audio socket.
/// Uses AVAudioEngine for low-latency playback.
final class AudioStreamer {

    /// scrcpy's raw audio is fixed: 48 kHz, stereo, interleaved s16le.
    private static let sampleRate: Double = 48000
    private static let channels = 2
    /// Drop incoming audio once this much is queued unplayed, so a stall
    /// turns into a short gap instead of permanently growing latency.
    private static let maxQueuedFrames = Int(sampleRate * 0.25)

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat

    // All mutable state below lives on parseQueue.
    private let parseQueue = DispatchQueue(label: "android-mirroring.audio-parser")
    private var isRunning = false
    private var epoch = 0
    private var queuedFrames = 0
    private var buffer = Data()
    private var codecId: UInt32 = 0
    private var codecRead = false

    init() {
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                               sampleRate: Self.sampleRate,
                               channels: AVAudioChannelCount(Self.channels),
                               interleaved: false)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func start() {
        parseQueue.sync {
            guard !isRunning else { return }
            do {
                engine.prepare()
                try engine.start()
                player.play()
                isRunning = true
            } catch {
                NSLog("AM-AUDIO engine start failed: %@", String(describing: error))
            }
        }
    }

    func stop() {
        parseQueue.sync {
            epoch += 1
            queuedFrames = 0
            buffer = Data()
            codecRead = false
            guard isRunning else { return }
            player.stop()
            engine.stop()
            isRunning = false
        }
    }

    /// Feed raw bytes from the audio socket.
    func feed(_ data: Data) {
        parseQueue.async { [weak self] in
            self?.parse(data)
        }
    }

    private func parse(_ data: Data) {
        buffer.append(data)

        // Read codec id first
        if !codecRead {
            guard buffer.count >= 4 else { return }
            codecId = readU32(at: 0)
            buffer.removeFirst(4)
            codecRead = true

            switch codecId {
            case 0x0072_6177: // "raw"
                NSLog("AM-AUDIO raw PCM 48kHz stereo")
            case 0x0061_6163: // "aac"
                NSLog("AM-AUDIO AAC (not yet supported)")
            case 0x6F70_7573: // "opus"
                NSLog("AM-AUDIO Opus (not yet supported)")
            default:
                NSLog("AM-AUDIO unknown codec 0x%x", codecId)
            }
        }

        // Parse framed packets (same format as video)
        guard codecId == 0x0072_6177 else { return }  // raw only for now

        while buffer.count >= 12 {
            let first64 = readU64(at: 0)
            // Session packets not expected for audio
            guard first64 & (1 << 63) == 0 else {
                buffer.removeFirst(12)
                continue
            }
            let size = Int(readU32(at: 8))
            guard buffer.count - 12 >= size else { return }

            let pcmData = Data(buffer[(buffer.startIndex + 12)..<(buffer.startIndex + 12 + size)])
            buffer.removeFirst(12 + size)

            playPCM(pcmData)
        }
    }

    private func playPCM(_ data: Data) {
        let frames = data.count / (2 * Self.channels)
        guard isRunning, frames > 0 else { return }
        guard queuedFrames + frames <= Self.maxQueuedFrames else { return }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format,
                                               frameCapacity: AVAudioFrameCount(frames)),
              let out = pcmBuffer.floatChannelData else { return }
        pcmBuffer.frameLength = AVAudioFrameCount(frames)

        // Interleaved s16le → planar f32. Socket data isn't guaranteed to be
        // 2-byte aligned, so read unaligned.
        data.withUnsafeBytes { raw in
            for f in 0..<frames {
                for ch in 0..<Self.channels {
                    let s = raw.loadUnaligned(fromByteOffset: (f * Self.channels + ch) * 2, as: Int16.self)
                    out[ch][f] = Float(Int16(littleEndian: s)) / 32768.0
                }
            }
        }

        queuedFrames += frames
        let epoch = epoch
        player.scheduleBuffer(pcmBuffer, completionCallbackType: .dataConsumed) { [weak self] _ in
            self?.parseQueue.async {
                guard let self, self.epoch == epoch else { return }
                self.queuedFrames -= frames
            }
        }
    }

    private func readU32(at offset: Int) -> UInt32 {
        var v: UInt32 = 0
        for i in 0..<4 {
            guard buffer.startIndex + offset + i < buffer.endIndex else { return 0 }
            v = (v << 8) | UInt32(buffer[buffer.startIndex + offset + i])
        }
        return v
    }

    private func readU64(at offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 {
            guard buffer.startIndex + offset + i < buffer.endIndex else { return 0 }
            v = (v << 8) | UInt64(buffer[buffer.startIndex + offset + i])
        }
        return v
    }
}
