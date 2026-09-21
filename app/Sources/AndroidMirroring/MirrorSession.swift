import Foundation
import Network
import AVFoundation
import AppKit
import Combine

/// Drives one mirroring session end-to-end over the scrcpy 4.1 protocol:
/// push server → adb forward → spawn server → video socket + control socket →
/// framed H.264 decode + control input. The connection choreography mirrors
/// iPhone Mirroring (push → start → handshake → live).
@MainActor
final class MirrorSession: ObservableObject {

    enum Phase: Equatable {
        case idle
        case pushingServer
        case startingServer
        case connecting
        case connected(String)
        case failed(String)

        var isLive: Bool {
            switch self {
            case .pushingServer, .startingServer, .connecting, .connected: return true
            case .idle, .failed: return false
            }
        }

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    @Published private(set) var phase: Phase = .idle {
        didSet { NSLog("AM-DIAG phase: %@ → %@", "\(oldValue)", "\(phase)") }
    }
    @Published private(set) var deviceName: String = ""
    @Published private(set) var videoSize: CGSize?
    /// Not @Published: nothing renders it, and publishing would re-render
    /// the whole window on every server log line.
    private(set) var serverLog: [String] = []

    let decoder = VideoDecoder()
    let parser = VideoStreamParser()
    let audioStreamer = AudioStreamer()

    private var adbPath: String?
    private var serverJarPath: String = ""
    private var serverVersion = "4.1"
    private(set) var serial = ""
    private var scid = ""
    private var forwardPort: UInt16 = 0
    private var shellProcess: Process?
    private var videoConn: NWConnection?
    private var controlConn: NWConnection?
    /// Bumped by every start()/stop(). Callbacks from sockets, the parser and
    /// the connection flow carry the generation they were created under, so
    /// stragglers from a torn-down session can't touch the current one.
    private var generation = 0

    var displayLayer: AVSampleBufferDisplayLayer { decoder.displayLayer }

    // MARK: - Lifecycle

    func start(serial: String, adb: String, serverJar: String, version: String) {
        stop()
        let gen = generation
        self.serial = serial
        adbPath = adb
        serverJarPath = serverJar
        serverVersion = version
        wireParser(gen)
        decoder.onDimensions = { [weak self] size in
            Task { @MainActor in
                guard let self, self.isCurrent(gen) else { return }
                self.videoSize = size
            }
        }
        phase = .pushingServer
        Task { await runFlow(gen) }
    }

    /// `synchronously`: remove the adb forward before returning (app exit).
    func stop(synchronously: Bool = false) {
        generation += 1
        videoConn?.cancel()
        controlConn?.cancel()
        videoConn = nil
        controlConn = nil
        audioStreamer.stop()
        if let p = shellProcess, p.isRunning {
            p.interrupt()
        }
        shellProcess = nil
        if let adb = adbPath, forwardPort != 0 {
            let port = forwardPort
            forwardPort = 0
            if synchronously {
                Shell.runBlocking(adb, ["forward", "--remove", "tcp:\(port)"])
            } else {
                Task.detached {
                    _ = try? await Shell.run(adb, ["forward", "--remove", "tcp:\(port)"])
                }
            }
        }
        parser.reset()
        deviceMsgBuffer = Data()
        phase = .idle
        deviceName = ""
        videoSize = nil
        decoder.reset()
    }

    private func isCurrent(_ gen: Int) -> Bool { gen == generation }

    private func wireParser(_ gen: Int) {
        parser.onDeviceName = { [weak self] name in
            Task { @MainActor in
                guard let self, self.isCurrent(gen) else { return }
                self.deviceName = name
            }
        }
        parser.onVideoSize = { [weak self] size in
            Task { @MainActor in
                guard let self, self.isCurrent(gen) else { return }
                self.videoSize = size
            }
        }
        // Only the first media packet needs to reach the main actor (to flip
        // the phase); don't spawn a task per frame after that.
        var announced = false // parser queue only
        parser.onPacket = { [weak self] payload, pts, config in
            self?.decoder.pushPacket(payload, ptsUs: pts, config: config)
            guard !announced, !config else { return }
            announced = true
            Task { @MainActor in
                guard let self, self.isCurrent(gen), !self.phase.isConnected else { return }
                self.phase = .connected(self.deviceName)
            }
        }
        parser.onError = { [weak self] message in
            Task { @MainActor in
                self?.failSession(message, gen)
            }
        }
    }

    private func failSession(_ message: String, _ gen: Int) {
        guard isCurrent(gen) else { return }
        stop()
        phase = .failed(message)
    }

    // MARK: - Connection flow

    private func runFlow(_ gen: Int) async {
        do {
            guard let adb = adbPath else { throw SessionError("adb not found") }

            // 1. Reserve a random scid + local forward port.
            scid = String(format: "%08x", UInt32.random(in: 0...0x7FFF_FFFF))
            let fwd = try await Shell.run(adb, ["-s", serial, "forward", "tcp:0", "localabstract:scrcpy_" + scid])
            guard fwd.isSuccess,
                  let port = UInt16(fwd.out.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw SessionError("adb forward failed: \(fwd.err)")
            }
            guard isCurrent(gen) else {
                // Superseded while adb ran: this forward belongs to nobody.
                _ = try? await Shell.run(adb, ["forward", "--remove", "tcp:\(port)"])
                return
            }
            forwardPort = port

            // 2. Push the server jar under a per-session name right before
            //    spawning (scrcpy's own pattern: fresh push every run).
            let remoteJar = "/data/local/tmp/am-server-\(scid).jar"
            let push = try await Shell.run(adb, ["-s", serial, "push", serverJarPath, remoteJar])
            NSLog("AM-DIAG push code=%d err=%@", push.code, push.err)
            guard push.isSuccess else { throw SessionError("Failed to push server: \(push.err)") }
            guard isCurrent(gen) else { return }

            // 3. Spawn the server on the device.
            phase = .startingServer
            let args = ["-s", serial, "shell",
                        "CLASSPATH=\(remoteJar)",
                        "app_process", "/", "com.genymobile.scrcpy.Server", serverVersion] + serverParameters()
            let shell = try Shell.startStreaming(adb, args) { [weak self] line in
                NSLog("AM-SERVER %@", line)
                Task { @MainActor in self?.appendServerLog(line) }
            }
            guard isCurrent(gen) else {
                shell.interrupt()
                return
            }
            shellProcess = shell

            // 4. Open sockets in order: video → audio → control.
            phase = .connecting
            let video = try await openVideoSocket(port: port, gen: gen)
            guard isCurrent(gen) else { video.cancel(); return }
            videoConn = video
            parser.skipDummy() // dummy byte was consumed by the readiness probe

            // Audio socket (2nd when audio=true)
            let audioConn = try await openSocket(port: port, label: "audio")
            guard isCurrent(gen) else { audioConn.cancel(); return }
            audioStreamer.start()
            let audio = audioStreamer
            // No strong ref kept: the pending receive retains the connection,
            // and it ends with the server process on stop().
            receiveLoop(on: audioConn, gen: gen) { audio.feed($0) }

            // Control socket (3rd)
            let control = try await openSocket(port: port, label: "control")
            guard isCurrent(gen) else { control.cancel(); return }
            controlConn = control
            let parser = parser
            receiveLoop(on: video, gen: gen) { parser.feed($0) }
            // Device→client messages (clipboard sync etc.). main.async rather
            // than Task so chunks are handled strictly in arrival order.
            receiveLoop(on: control, gen: gen) { [weak self] data in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.isCurrent(gen) else { return }
                        self.parseDeviceMessages(data)
                    }
                }
            }
            // Phase flips to .connected once the video handshake completes.
        } catch {
            NSLog("AM-DIAG runFlow error: %@", String(describing: error))
            failSession(String(describing: error), gen)
        }
    }

    private func serverParameters() -> [String] {
        [
            "log_level=info",
            "video=true",
            "audio=true",
            "audio_codec=raw",
            "control=true",
            "video_source=display",
            "display_id=0",
            "video_codec=h264",
            "video_bit_rate=8000000",
            "max_size=0",
            "max_fps=0",
            "stay_awake=true",
            "power_on=true",
            "tunnel_forward=true",
            "send_dummy_byte=true",
            "send_device_meta=true",
            "cleanup=true",
            "scid=\(scid)",
        ]
    }

    // MARK: - Sockets

    private func openSocket(port: UInt16, label: String) async throws -> NWConnection {
        var lastError: Error = SessionError("unreachable")
        for _ in 0..<60 {
            do {
                return try await connectOnce(port: port, label: label)
            } catch {
                lastError = error
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        throw SessionError("\(label) socket: \(lastError)")
    }

    /// The video socket isn't "up" until the server's dummy byte arrives:
    /// with adb forward the TCP connect succeeds before the server exists
    /// and then EOFs, so retry the whole connect until real data flows.
    private func openVideoSocket(port: UInt16, gen: Int) async throws -> NWConnection {
        for _ in 0..<80 {
            guard isCurrent(gen) else { throw SessionError("cancelled") }
            guard let c = try? await connectOnce(port: port, label: "video") else {
                try? await Task.sleep(nanoseconds: 250_000_000)
                continue
            }
            if await firstByte(of: c) != nil {
                return c
            }
            c.cancel()
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        throw SessionError("server did not come up on the device")
    }

    private func firstByte(of c: NWConnection) async -> UInt8? {
        await withCheckedContinuation { (cont: CheckedContinuation<UInt8?, Never>) in
            final class Once: @unchecked Sendable { var resumed = false } // receive queue only
            let once = Once()
            c.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, isComplete, error in
                guard !once.resumed else { return }
                once.resumed = true
                if let data, !data.isEmpty, error == nil {
                    cont.resume(returning: data[data.startIndex])
                } else {
                    _ = isComplete
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private func connectOnce(port: UInt16, label: String) async throws -> NWConnection {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<NWConnection, Error>) in
            final class Box: @unchecked Sendable { var resumed = false } // connection queue only
            let box = Box()
            let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            c.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard !box.resumed else { return }
                    box.resumed = true
                    cont.resume(returning: c)
                case .failed(let error):
                    guard !box.resumed else { return }
                    box.resumed = true
                    c.cancel()
                    cont.resume(throwing: error)
                case .cancelled:
                    guard !box.resumed else { return }
                    box.resumed = true
                    cont.resume(throwing: SessionError("\(label) socket cancelled"))
                default:
                    break
                }
            }
            c.start(queue: DispatchQueue(label: "android-mirroring.\(label)"))
        }
    }

    private nonisolated func receiveLoop(on conn: NWConnection, gen: Int, handler: @escaping (Data) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                handler(data)
            }
            if error != nil || isComplete {
                Task { @MainActor in self?.handleDisconnect(gen) }
                return
            }
            self?.receiveLoop(on: conn, gen: gen, handler: handler)
        }
    }

    private var deviceMsgBuffer = Data()

    private func parseDeviceMessages(_ data: Data) {
        deviceMsgBuffer.append(data)

        while !deviceMsgBuffer.isEmpty {
            guard deviceMsgBuffer.count >= 1 else { return }
            let type = deviceMsgBuffer[deviceMsgBuffer.startIndex]

            switch type {
            case 0: // clipboard
                guard deviceMsgBuffer.count >= 5 else { return }
                let len = Int(deviceMsgBuffer[deviceMsgBuffer.startIndex + 1]) << 24
                    | Int(deviceMsgBuffer[deviceMsgBuffer.startIndex + 2]) << 16
                    | Int(deviceMsgBuffer[deviceMsgBuffer.startIndex + 3]) << 8
                    | Int(deviceMsgBuffer[deviceMsgBuffer.startIndex + 4])
                guard deviceMsgBuffer.count >= 5 + len else { return }
                let textData = deviceMsgBuffer.subdata(in: (deviceMsgBuffer.startIndex + 5)..<(deviceMsgBuffer.startIndex + 5 + len))
                deviceMsgBuffer.removeFirst(5 + len)
                if let text = String(data: textData, encoding: .utf8) {
                    syncClipboardFromDevice(text)
                }
            case 1: // clipboard ack: u64 sequence
                guard deviceMsgBuffer.count >= 9 else { return }
                deviceMsgBuffer.removeFirst(9)
            case 2: // UHID output: u16 id, u16 size, data
                guard deviceMsgBuffer.count >= 5 else { return }
                let len = Int(deviceMsgBuffer[deviceMsgBuffer.startIndex + 3]) << 8
                    | Int(deviceMsgBuffer[deviceMsgBuffer.startIndex + 4])
                guard deviceMsgBuffer.count >= 5 + len else { return }
                deviceMsgBuffer.removeFirst(5 + len)
            default:
                // Unknown type: framing is lost, so drop what we have rather
                // than misread payload bytes as message headers.
                NSLog("AM-DIAG unknown device message type %d", type)
                deviceMsgBuffer = Data()
            }
        }
    }

    private func syncClipboardFromDevice(_ text: String) {
        let pasteboard = NSPasteboard.general
        // Only update if different (avoid loops)
        if pasteboard.string(forType: .string) != text {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }

    /// Send Mac clipboard to device
    func syncClipboardToDevice() {
        guard phase.isConnected else { return }
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        guard !text.isEmpty else { return }
        var d = Data()
        d.append(ScrcpyWire.MessageType.setClipboard)
        d.appendBE(UInt64(0)) // sequence
        d.append(UInt8(1))    // paste = true
        let utf8 = Data(text.utf8)
        d.appendBE(UInt32(utf8.count))
        d.append(utf8)
        send(d)
    }

    private func handleDisconnect(_ gen: Int) {
        guard isCurrent(gen), phase.isLive else { return }
        let wasConnected = phase.isConnected
        stop()
        phase = wasConnected ? .idle : .failed("Connection interrupted")
    }

    private func appendServerLog(_ line: String) {
        for l in line.split(separator: "\n", omittingEmptySubsequences: true) {
            serverLog.append(String(l))
            if serverLog.count > 200 { serverLog.removeFirst(serverLog.count - 200) }
        }
    }

    // MARK: - Control input (called from the mirror view / menus)

    /// Synchronous on the main actor so down/move/up and key events reach
    /// the socket in exactly the order they were generated.
    func send(_ message: Data) {
        guard phase.isConnected, let conn = controlConn else { return }
        conn.send(content: message, completion: .contentProcessed { _ in })
    }

    func sendKey(code: UInt32, action: UInt8, meta: UInt32 = 0) {
        send(ScrcpyWire.injectKeycode(action: action, keycode: code, meta: meta))
    }

    func tapKey(code: UInt32, meta: UInt32 = 0) {
        sendKey(code: code, action: ScrcpyWire.actionDown, meta: meta)
        sendKey(code: code, action: ScrcpyWire.actionUp, meta: meta)
    }

    func sendText(_ text: String) {
        send(ScrcpyWire.injectText(text))
    }

    func sendTouch(action: UInt8, viewPoint: CGPoint, videoSize: CGSize) {
        guard videoSize.width > 0, videoSize.height > 0 else { return }
        let isHover = action == ScrcpyWire.actionHoverMove
        let msg = ScrcpyWire.injectTouch(
            action: action,
            x: Int(viewPoint.x * videoSize.width),
            y: Int(viewPoint.y * videoSize.height),
            screenW: UInt16(videoSize.width), screenH: UInt16(videoSize.height),
            pressure: isHover || action == ScrcpyWire.actionUp ? 0 : 1,
            actionButton: isHover ? 0 : 1,
            buttons: isHover ? 0 : 1)
        send(msg)
    }

    func sendScroll(viewPoint: CGPoint, videoSize: CGSize, h: Float, v: Float) {
        guard videoSize.width > 0, videoSize.height > 0 else { return }
        let msg = ScrcpyWire.injectScroll(
            x: Int(viewPoint.x * videoSize.width),
            y: Int(viewPoint.y * videoSize.height),
            screenW: UInt16(videoSize.width), screenH: UInt16(videoSize.height),
            hscroll: h, vscroll: v)
        send(msg)
    }
}

struct SessionError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}
