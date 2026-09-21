import AVFoundation
import Foundation
import os

/// Jitter buffer between the audio socket (bursty, device clock) and the
/// output device (steady, Mac clock). Interleaved stereo float frames.
///
/// - Playback holds until `target` frames are queued, so ordinary arrival
///   jitter never reaches the speaker.
/// - An underrun plays out what's left, then re-buffers to `target` once,
///   instead of stuttering on every late packet.
/// - If the queue grows past `maxLatency` (clock drift, a stall that
///   flushed at once), the oldest audio is skipped back down to `target`:
///   one small jump rather than ever-growing delay.
final class AudioJitterBuffer {

    static let channels = 2

    struct Stats {
        var underruns = 0
        var skips = 0
        var minLevel = Int.max
        var maxLevel = 0
    }

    let target: Int
    let maxLatency: Int

    private let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private var readIndex = 0   // frames
    private var count = 0       // frames
    private var buffering = true
    private var stats = Stats()
    // Held only for a memcpy on either side, so the render thread never
    // waits on anything slow.
    private let lock = OSAllocatedUnfairLock()

    init(sampleRate: Double, targetSeconds: Double = 0.06, maxLatencySeconds: Double = 0.18) {
        target = Int(sampleRate * targetSeconds)
        maxLatency = Int(sampleRate * maxLatencySeconds)
        capacity = Int(sampleRate) // 1 s
        storage = .allocate(capacity: capacity * Self.channels)
        storage.initialize(repeating: 0, count: capacity * Self.channels)
    }

    deinit { storage.deallocate() }

    func reset() {
        lock.withLockUnchecked {
            readIndex = 0
            count = 0
            buffering = true
            stats = Stats()
        }
    }

    func takeStats() -> Stats {
        lock.withLockUnchecked {
            let s = stats
            stats = Stats()
            return s
        }
    }

    /// Producer side. `samples` is interleaved, `frames * channels` long.
    func write(_ samples: UnsafePointer<Float>, frames: Int) {
        var src = samples
        var n = frames
        if n > capacity { // keep the newest second
            src += (n - capacity) * Self.channels
            n = capacity
        }
        lock.withLockUnchecked {
            if count + n > capacity {
                drop(count + n - capacity)
            }
            var w = (readIndex + count) % capacity
            var left = n
            var p = src
            while left > 0 {
                let chunk = min(left, capacity - w)
                memcpy(storage + w * Self.channels, p, chunk * Self.channels * MemoryLayout<Float>.size)
                p += chunk * Self.channels
                w = (w + chunk) % capacity
                left -= chunk
            }
            count += n
            if count > maxLatency {
                drop(count - target)
                stats.skips += 1
            }
            stats.maxLevel = max(stats.maxLevel, count)
        }
    }

    /// Consumer side (render thread). Fills planar `left`/`right` with
    /// `frames` frames, silence where there's nothing to play.
    func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        var got = 0
        lock.withLockUnchecked {
            if buffering {
                guard count >= target else { return }
                buffering = false
            }
            stats.minLevel = min(stats.minLevel, count)
            got = min(frames, count)
            var r = readIndex
            for i in 0..<got {
                left[i] = storage[r * Self.channels]
                right[i] = storage[r * Self.channels + 1]
                r += 1
                if r == capacity { r = 0 }
            }
            readIndex = r
            count -= got
            if got < frames {
                buffering = true
                stats.underruns += 1
            }
        }
        if got < frames {
            (left + got).update(repeating: 0, count: frames - got)
            (right + got).update(repeating: 0, count: frames - got)
        }
    }

    private func drop(_ frames: Int) { // lock held
        readIndex = (readIndex + frames) % capacity
        count -= frames
    }
}

/// Parses scrcpy's audio socket: u32 codec id, then framed packets
/// ([u64 pts+flags][u32 size][payload]) of 48 kHz stereo interleaved s16le.
/// Not thread-safe: call from one queue.
final class AudioStreamParser {

    static let rawCodecId: UInt32 = 0x0072_6177 // "raw"

    /// Interleaved float samples for one packet; valid only during the call.
    var onSamples: ((UnsafeBufferPointer<Float>, _ frames: Int) -> Void)?

    private var buffer = Data()
    private var codecId: UInt32?
    private var scratch: [Float] = []

    func reset() {
        buffer = Data()
        codecId = nil
    }

    func feed(_ data: Data) {
        buffer.append(data)

        if codecId == nil {
            guard buffer.count >= 4 else { return }
            let id = UInt32(readBE(at: 0, bytes: 4))
            buffer.removeFirst(4)
            codecId = id
            if id == Self.rawCodecId {
                NSLog("AM-AUDIO raw PCM 48kHz stereo")
            } else {
                // 0 = audio disabled by the device (e.g. Android < 11), 1 = error.
                NSLog("AM-AUDIO no playable stream (codec 0x%x)", id)
            }
        }
        guard codecId == Self.rawCodecId else {
            buffer = Data()
            return
        }

        while buffer.count >= 12 {
            let header = readBE(at: 0, bytes: 8)
            if header & (1 << 63) != 0 { // session packet: fixed 12 bytes, no payload
                buffer.removeFirst(12)
                continue
            }
            let size = Int(readBE(at: 8, bytes: 4))
            guard buffer.count - 12 >= size else { return }
            let start = buffer.startIndex + 12
            // bit 62 = config packet: codec setup, never PCM.
            if header & (1 << 62) == 0 {
                emit(buffer[start..<(start + size)])
            }
            buffer.removeFirst(12 + size)
        }
    }

    private func emit(_ pcm: Data) {
        let channels = AudioJitterBuffer.channels
        let frames = pcm.count / (2 * channels)
        guard frames > 0 else { return }
        let samples = frames * channels
        if scratch.count < samples { scratch = [Float](repeating: 0, count: samples) }
        // Socket data isn't guaranteed to be 2-byte aligned: read unaligned.
        pcm.withUnsafeBytes { raw in
            for i in 0..<samples {
                let s = raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)
                scratch[i] = Float(Int16(littleEndian: s)) / 32768.0
            }
        }
        scratch.withUnsafeBufferPointer {
            onSamples?(UnsafeBufferPointer(rebasing: $0[..<samples]), frames)
        }
    }

    private func readBE(at offset: Int, bytes: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<bytes { v = (v << 8) | UInt64(buffer[buffer.startIndex + offset + i]) }
        return v
    }
}

/// Plays the audio socket. The output device pulls from a jitter buffer;
/// nothing is scheduled per packet.
final class AudioStreamer {

    private static let sampleRate: Double = 48000

    private let engine = AVAudioEngine()
    private let jitter = AudioJitterBuffer(sampleRate: sampleRate)
    private let source: AVAudioSourceNode

    // All mutable state below lives on parseQueue.
    private let parseQueue = DispatchQueue(label: "android-mirroring.audio-parser")
    private let parser = AudioStreamParser()
    private var isRunning = false
    private var lastStats = Date()
    private var peak: Float = 0
    private let logStats = ProcessInfo.processInfo.environment["ANDROID_MIRRORING_AUDIO_STATS"] != nil

    init() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: Self.sampleRate,
                                   channels: AVAudioChannelCount(AudioJitterBuffer.channels),
                                   interleaved: false)!
        let jitter = jitter
        source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard abl.count == 2,
                  let l = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            jitter.read(left: l, right: r, frames: Int(frameCount))
            return noErr
        }
        engine.attach(source)
        // The mixer resamples if the output device isn't running at 48 kHz.
        engine.connect(source, to: engine.mainMixerNode, format: format)

        parser.onSamples = { [unowned self] samples, frames in
            guard isRunning else { return }
            if logStats {
                for s in samples { peak = max(peak, abs(s)) }
            }
            jitter.write(samples.baseAddress!, frames: frames)
        }
    }

    func start() {
        parseQueue.sync {
            guard !isRunning else { return }
            jitter.reset()
            do {
                engine.prepare()
                try engine.start()
                isRunning = true
            } catch {
                NSLog("AM-AUDIO engine start failed: %@", String(describing: error))
            }
        }
    }

    func stop() {
        parseQueue.sync {
            parser.reset()
            guard isRunning else { return }
            engine.stop()
            jitter.reset()
            isRunning = false
        }
    }

    /// Feed raw bytes from the audio socket.
    func feed(_ data: Data) {
        parseQueue.async { [weak self] in
            guard let self else { return }
            parser.feed(data)
            if logStats, Date().timeIntervalSince(lastStats) >= 2 {
                lastStats = Date()
                let s = jitter.takeStats()
                let ms = 1000.0 / Self.sampleRate
                NSLog("AM-AUDIO stats peak=%.3f underruns=%d skips=%d level=%.0f…%.0f ms",
                      peak, s.underruns, s.skips,
                      s.minLevel == .max ? 0 : Double(s.minLevel) * ms, Double(s.maxLevel) * ms)
                peak = 0
            }
        }
    }
}
