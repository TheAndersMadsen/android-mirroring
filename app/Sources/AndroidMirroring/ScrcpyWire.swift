import Foundation

/// scrcpy v4.1 wire protocol encoder, transcribed byte-for-byte from the
/// server sources (ControlMessage.java / ControlMessageReader.java /
/// Streamer.java / DesktopConnection.java at tag v4.1).
///
/// Wire facts (v4.1, tunnel_forward, video+control, no audio):
///  - two sockets, opened in order: 1) video, 2) control
///  - video socket: server sends 1 dummy byte, 64-byte device name,
///    u32 codec-id ("h264"), then packets:
///      session packet: [u32 flags = 0x8000_0000 | clientResized?1][u32 w][u32 h]
///      media packet:   [u64 ptsAndFlags][u32 size][payload]
///        bit63 = 1 ⟺ session packet; bit62 = config (SPS/PPS); bit61 = key frame;
///        low 61 bits = PTS in µs
///  - control socket: raw big-endian messages, no length prefix:
///      type u8 + payload per ControlMessageReader
///    device→client messages also arrive on this socket (drained).
enum ScrcpyWire {

    static let h264CodecId: UInt32 = 0x6832_3634 // "h264" big-endian ASCII

    // MARK: - Control message types (ControlMessage.java)

    enum MessageType {
        static let injectKeycode: UInt8 = 0
        static let injectText: UInt8 = 1
        static let injectTouch: UInt8 = 2
        static let injectScroll: UInt8 = 3
        static let backOrScreenOn: UInt8 = 4
        static let expandNotificationPanel: UInt8 = 5
        static let expandSettingsPanel: UInt8 = 6
        static let collapsePanels: UInt8 = 7
        static let getClipboard: UInt8 = 8
        static let setClipboard: UInt8 = 9
        static let setDisplayPower: UInt8 = 10
        static let rotateDevice: UInt8 = 11
        static let uhidCreate: UInt8 = 12
        static let uhidInput: UInt8 = 13
        static let uhidDestroy: UInt8 = 14
        static let openHardKeyboardSettings: UInt8 = 15
        static let startApp: UInt8 = 16
        static let resetVideo: UInt8 = 17
        static let cameraSetTorch: UInt8 = 18
        static let cameraZoomIn: UInt8 = 19
        static let cameraZoomOut: UInt8 = 20
        static let resizeDisplay: UInt8 = 21
        static let scanFile: UInt8 = 22
    }

    // Android keycodes (framework KeyEvent)
    enum KeyCode {
        static let home: UInt32 = 3
        static let back: UInt32 = 4
        static let volumeUp: UInt32 = 24
        static let volumeDown: UInt32 = 25
        static let power: UInt32 = 26
        static let menu: UInt32 = 82
        static let dpadUp: UInt32 = 19
        static let dpadDown: UInt32 = 20
        static let dpadLeft: UInt32 = 21
        static let dpadRight: UInt32 = 22
        static let enter: UInt32 = 66
        static let del: UInt32 = 67
        static let tab: UInt32 = 61
        static let escape: UInt32 = 111
        static let appSwitch: UInt32 = 187
        static let a: UInt32 = 29
        static let forwardDel: UInt32 = 112
        static let moveHome: UInt32 = 122
        static let moveEnd: UInt32 = 123
        static let pageUp: UInt32 = 92
        static let pageDown: UInt32 = 93
        static let cut: UInt32 = 277
        static let copy: UInt32 = 278
    }

    /// KeyEvent.META_CTRL_ON | META_CTRL_LEFT_ON
    static let metaCtrl: UInt32 = 0x1000 | 0x2000

    // Android MotionEvent actions
    static let actionDown: UInt8 = 0
    static let actionUp: UInt8 = 1
    static let actionMove: UInt8 = 2
    static let actionHoverMove: UInt8 = 7
    /// pointer id scrcpy's client uses for the mouse ("virtual finger")
    static let pointerIdMouse: UInt64 = 0xFFFF_FFFF_FFFF_FFFF

    // MARK: - Encoders (client → server)

    /// action u8, keycode i32, repeat i32, metaState i32
    static func injectKeycode(action: UInt8, keycode: UInt32, repeatCount: UInt32 = 0, meta: UInt32 = 0) -> Data {
        var d = Data()
        d.append(MessageType.injectKeycode)
        d.appendBE(action)
        d.appendBE(keycode)
        d.appendBE(repeatCount)
        d.appendBE(meta)
        return d
    }

    /// type u8, u32 length, UTF-8 bytes
    static func injectText(_ text: String) -> Data {
        let utf8 = Data(text.utf8)
        var d = Data()
        d.append(MessageType.injectText)
        d.appendBE(UInt32(utf8.count))
        d.append(utf8)
        return d
    }

    /// action u8, pointerId i64, x i32, y i32, screenW u16, screenH u16,
    /// pressure u16 fixed-point, actionButton i32, buttons i32.
    /// x/y are device pixel coordinates.
    static func injectTouch(action: UInt8,
                            pointerId: UInt64 = pointerIdMouse,
                            x: Int, y: Int,
                            screenW: UInt16, screenH: UInt16,
                            pressure: Float,
                            actionButton: UInt32 = 1,
                            buttons: UInt32 = 1) -> Data {
        var d = Data()
        d.append(MessageType.injectTouch)
        d.appendBE(action)
        d.appendBE(pointerId)
        d.appendBE(Int32(x))
        d.appendBE(Int32(y))
        d.appendBE(screenW)
        d.appendBE(screenH)
        d.appendBE(u16FixedPoint(pressure))
        d.appendBE(actionButton)
        d.appendBE(buttons)
        return d
    }

    /// position(x i32, y i32, screenW u16, screenH u16),
    /// hScroll i16 fixed-point, vScroll i16 fixed-point, buttons i32.
    /// Server multiplies the decoded [-1,1] floats by 16.
    static func injectScroll(x: Int, y: Int,
                             screenW: UInt16, screenH: UInt16,
                             hscroll: Float, vscroll: Float,
                             buttons: UInt32 = 0) -> Data {
        var d = Data()
        d.append(MessageType.injectScroll)
        d.appendBE(Int32(x))
        d.appendBE(Int32(y))
        d.appendBE(screenW)
        d.appendBE(screenH)
        d.appendBE(i16FixedPoint(hscroll))
        d.appendBE(i16FixedPoint(vscroll))
        d.appendBE(buttons)
        return d
    }

    /// type u8, action u8
    static func backOrScreenOn(action: UInt8) -> Data {
        var d = Data()
        d.append(MessageType.backOrScreenOn)
        d.appendBE(action)
        return d
    }

    /// Messages with no payload (panels, rotate, reset video, …)
    static func simple(_ type: UInt8) -> Data {
        Data([type])
    }

    // MARK: - Fixed point helpers (Binary.java equivalents)

    private static func u16FixedPoint(_ v: Float) -> UInt16 {
        UInt16(clamping: Int((max(0, min(1, v)) * 0xFFFF).rounded()))
    }

    private static func i16FixedPoint(_ v: Float) -> Int16 {
        Int16(clamping: Int((max(-1, min(1, v)) * 32767).rounded()))
    }
}

// MARK: - Big-endian packing

extension Data {
    mutating func appendBE(_ v: UInt8) {
        append(v)
    }

    mutating func appendBE(_ v: UInt16) {
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8(v & 0xFF))
    }

    mutating func appendBE(_ v: UInt32) {
        append(UInt8((v >> 24) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8(v & 0xFF))
    }

    mutating func appendBE(_ v: UInt64) {
        appendBE(UInt32(truncatingIfNeeded: v >> 32))
        appendBE(UInt32(truncatingIfNeeded: v))
    }

    mutating func appendBE(_ v: Int32) {
        appendBE(UInt32(bitPattern: v))
    }

    mutating func appendBE(_ v: Int16) {
        appendBE(UInt16(bitPattern: v))
    }
}
