import AVFoundation
import AppKit
import CoreMedia

/// Decodes scrcpy's Annex-B H.264 access units (delivered as complete,
/// framed packets by the v4.1 stream protocol) and renders them via
/// AVSampleBufferDisplayLayer.
final class VideoDecoder {

    let displayLayer = AVSampleBufferDisplayLayer()

    /// Called once the video dimensions are known (from SPS or session meta).
    var onDimensions: ((CGSize) -> Void)?

    private var formatDescription: CMVideoFormatDescription?
    private var sps = Data()
    private var pps = Data()
    private let queue = DispatchQueue(label: "android-mirroring.video-decoder")

    init() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
    }

    /// Feed one complete packet from the framed stream.
    /// `config` packets carry SPS/PPS (Annex-B); media packets carry one
    /// access unit (Annex-B) with a PTS in microseconds.
    func pushPacket(_ data: Data, ptsUs: UInt64, config: Bool) {
        queue.async { [weak self] in
            self?.push(data, ptsUs: ptsUs, config: config)
        }
    }

    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            formatDescription = nil
            sps = Data()
            pps = Data()
            displayLayer.flushAndRemoveImage()
        }
    }

    // MARK: - Decode path

    private func push(_ data: Data, ptsUs: UInt64, config: Bool) {
        let nals = NALScanner.ranges(in: data)
        // Config packets carry the parameter sets; key frames may repeat them.
        extractParameterSets(data, nals)
        guard !config, let fmt = formatDescription else { return }

        if displayLayer.status == .failed {
            NSLog("AM-DIAG display layer failed: %@", String(describing: displayLayer.error))
            displayLayer.flush()
        }

        let pts = CMTime(value: CMTimeValue(ptsUs), timescale: 1_000_000)
        if let sb = Self.makeSampleBuffer(annexB: data, nals: nals, format: fmt, pts: pts) {
            displayLayer.enqueue(sb)
        }
    }

    private func extractParameterSets(_ data: Data, _ nals: [Range<Int>]) {
        var updated = false
        for r in nals {
            switch data[r.lowerBound] & 0x1F {
            case 7:
                let nal = data.subdata(in: r)
                if nal != sps { sps = nal; updated = true }
            case 8:
                let nal = data.subdata(in: r)
                if nal != pps { pps = nal; updated = true }
            default:
                break
            }
        }
        if updated && !sps.isEmpty && !pps.isEmpty {
            formatDescription = Self.makeFormatDescription(sps: sps, pps: pps)
            if let fmt = formatDescription {
                let dims = CMVideoFormatDescriptionGetDimensions(fmt)
                let size = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
                NSLog("AM-DIAG video format %dx%d", dims.width, dims.height)
                DispatchQueue.main.async { [weak self] in
                    self?.onDimensions?(size)
                }
            }
        }
    }

    // MARK: - CM plumbing (static + internal so tests can decode the output)

    static func makeFormatDescription(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var formatDescription: CMVideoFormatDescription?
        var spsCopy = [UInt8](sps)
        var ppsCopy = [UInt8](pps)
        spsCopy.withUnsafeMutableBufferPointer { spsBuf in
            ppsCopy.withUnsafeMutableBufferPointer { ppsBuf in
                var sizes: [Int] = [spsBuf.count, ppsBuf.count]
                var pointers: [UnsafePointer<UInt8>] = [
                    UnsafePointer(spsBuf.baseAddress!),
                    UnsafePointer(ppsBuf.baseAddress!),
                ]
                sizes.withUnsafeMutableBufferPointer { sBuf in
                    pointers.withUnsafeMutableBufferPointer { pBuf in
                        _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pBuf.baseAddress!,
                            parameterSetSizes: sBuf.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &formatDescription)
                    }
                }
            }
        }
        return formatDescription
    }

    static func makeSampleBuffer(annexB: Data, nals: [Range<Int>],
                                  format: CMVideoFormatDescription, pts: CMTime) -> CMSampleBuffer? {
        guard !nals.isEmpty else { return nil }
        // Annex-B → AVCC: 4-byte big-endian length prefix per NAL, written
        // straight into the block the CMBlockBuffer takes ownership of.
        let total = nals.reduce(0) { $0 + 4 + $1.count }
        let block = malloc(total)!
        let dst = block.assumingMemoryBound(to: UInt8.self)
        annexB.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            var o = 0
            for r in nals {
                let n = UInt32(r.count)
                dst[o] = UInt8(truncatingIfNeeded: n >> 24)
                dst[o + 1] = UInt8(truncatingIfNeeded: n >> 16)
                dst[o + 2] = UInt8(truncatingIfNeeded: n >> 8)
                dst[o + 3] = UInt8(truncatingIfNeeded: n)
                memcpy(dst + o + 4, src.baseAddress! + (r.lowerBound - annexB.startIndex), r.count)
                o += 4 + r.count
            }
        }
        var blockBuffer: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: block,
            blockLength: total,
            blockAllocator: kCFAllocatorMalloc,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: total,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let bb = blockBuffer else {
            free(block)
            return nil
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid)
        var size = total

        var sampleBuffer: CMSampleBuffer?
        let created = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sampleBuffer)
        guard created == noErr, let sb = sampleBuffer else { return nil }

        // Mirroring wants the newest frame on screen now, not paced by PTS
        // against a clock (which only adds latency and drift).
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }
}

/// Splits an Annex-B byte stream into NAL units (without start codes).
enum NALScanner {
    /// Ranges are in `data`'s own index space (safe for slices).
    static func ranges(in data: Data) -> [Range<Int>] {
        var result: [Range<Int>] = []
        let base = data.startIndex
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            let n = bytes.count
            var i = 0
            var nalStart: Int? = nil
            while i + 2 < n {
                if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                    let scStart = (i > 0 && bytes[i - 1] == 0) ? i - 1 : i
                    if let s = nalStart, scStart > s {
                        result.append((base + s)..<(base + scStart))
                    }
                    nalStart = i + 3
                    i += 3
                } else {
                    i += 1
                }
            }
            if let s = nalStart, s < n {
                result.append((base + s)..<(base + n))
            }
        }
        return result
    }
}
