import SwiftUI
import AppKit
import AVFoundation

/// Hosts the decoder's display layer and translates Mac mouse/keyboard input
/// into scrcpy control messages — the same "your Mac input controls the
/// phone" contract iPhone Mirroring gives you.
struct PlayerView: NSViewRepresentable {
    @ObservedObject var session: MirrorSession
    /// Reports normalized mouse Y (0=top, 1=bottom) for chrome visibility.
    var onMouseY: ((CGFloat) -> Void)?

    func makeNSView(context: Context) -> MirrorNSView {
        let view = MirrorNSView(session: session)
        view.onMouseY = onMouseY
        return view
    }

    func updateNSView(_ nsView: MirrorNSView, context: Context) {
        nsView.onMouseY = onMouseY
    }
}

final class MirrorNSView: NSView {

    private let session: MirrorSession
    private var isTouching = false
    private var lastModifiers: NSEvent.ModifierFlags = []
    /// Reports normalized mouse Y (0=top, 1=bottom) for chrome visibility.
    var onMouseY: ((CGFloat) -> Void)?

    init(session: MirrorSession) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(session.displayLayer)
        updateTrackingArea()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// Mouse events here go to the phone — never to window movement.
    override var mouseDownCanMoveWindow: Bool { false }

    private var videoSize: CGSize { session.videoSize ?? .zero }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        session.displayLayer.frame = bounds
        CATransaction.commit()
        updateTrackingArea()
    }

    private var trackingArea: NSTrackingArea?
    private func updateTrackingArea() {
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.inVisibleRect, .activeAlways, .mouseMoved, .mouseEnteredAndExited, .enabledDuringMouseDrag],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // Normalized position within the video content (0...1, top-left origin).
    private func normalized(_ point: NSPoint) -> CGPoint {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        return CGPoint(
            x: min(max(point.x / bounds.width, 0), 1),
            y: min(max((bounds.height - point.y) / bounds.height, 0), 1))
    }

    // MARK: - Mouse → touch

    override func mouseDown(with event: NSEvent) {
        // ⌘+click anywhere = move the window (like iPhone Mirroring)
        if event.modifierFlags.contains(.command) {
            window?.performDrag(with: event)
            return
        }

        window?.makeFirstResponder(self)
        guard videoSize != .zero, event.buttonNumber == 0 else {
            // Middle-click (buttonNumber == 1) → Home
            if event.buttonNumber == 1 {
                session.tapKey(code: ScrcpyWire.KeyCode.home)
            }
            return
        }
        isTouching = true
        session.sendTouch(action: ScrcpyWire.actionDown,
                          viewPoint: normalized(convert(event.locationInWindow, from: nil)),
                          videoSize: videoSize)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTouching, videoSize != .zero else { return }
        session.sendTouch(action: ScrcpyWire.actionMove,
                          viewPoint: normalized(convert(event.locationInWindow, from: nil)),
                          videoSize: videoSize)
    }

    override func mouseUp(with event: NSEvent) {
        guard isTouching, videoSize != .zero else { return }
        isTouching = false
        session.sendTouch(action: ScrcpyWire.actionUp,
                          viewPoint: normalized(convert(event.locationInWindow, from: nil)),
                          videoSize: videoSize)
    }

    // Hover moves (for hover effects on Android) — only when not touching
    override func mouseMoved(with event: NSEvent) {
        // Report Y position for chrome visibility
        let point = convert(event.locationInWindow, from: nil)
        if bounds.height > 0 {
            onMouseY?(1.0 - point.y / bounds.height)  // 0=top, 1=bottom
        }

        guard !isTouching, videoSize != .zero else { return }
        session.sendTouch(action: ScrcpyWire.actionHoverMove,
                          viewPoint: normalized(convert(event.locationInWindow, from: nil)),
                          videoSize: videoSize)
    }

    // Right-click = Back (matches Android mouse conventions)
    override func rightMouseDown(with event: NSEvent) {
        session.tapKey(code: ScrcpyWire.KeyCode.back)
    }

    override func rightMouseUp(with event: NSEvent) {}

    // Cancel any stuck touch when leaving the view
    override func mouseExited(with event: NSEvent) {
        onMouseY?(2.0)  // signal: mouse left the view
        if isTouching, videoSize != .zero {
            isTouching = false
            session.sendTouch(action: ScrcpyWire.actionUp,
                              viewPoint: normalized(convert(event.locationInWindow, from: nil)),
                              videoSize: videoSize)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        // Middle click → Home
        if event.buttonNumber == 1 {
            session.tapKey(code: ScrcpyWire.KeyCode.home)
        }
    }

    // MARK: - Scroll

    override func scrollWheel(with event: NSEvent) {
        guard videoSize != .zero else { return }
        let point = normalized(convert(event.locationInWindow, from: nil))

        // Wire range [-1, 1] decodes to [-16, 16] Android scroll units, so one
        // unit is 1/16. Trackpads report points (many small events per
        // gesture); wheels report lines. Sending ±1 per event, as before,
        // meant 16 units per event.
        let unitsPerDelta: CGFloat = event.hasPreciseScrollingDeltas ? 1.0 / 40 : 1
        let h = Float(event.scrollingDeltaX * unitsPerDelta / 16)
        let v = Float(event.scrollingDeltaY * unitsPerDelta / 16)
        guard h != 0 || v != 0 else { return }

        session.sendScroll(viewPoint: point, videoSize: videoSize, h: h, v: v)
    }

    // MARK: - Clipboard (Edit menu / ⌘C ⌘X ⌘V ⌘A arrive as responder actions)

    /// Pushes the Mac clipboard to the device and pastes it there.
    @objc func paste(_ sender: Any?) {
        session.syncClipboardToDevice()
    }

    /// The device's new clipboard comes back over the control socket and
    /// lands on the Mac pasteboard (MirrorSession.syncClipboardFromDevice).
    @objc func copy(_ sender: Any?) {
        session.tapKey(code: ScrcpyWire.KeyCode.copy)
    }

    @objc func cut(_ sender: Any?) {
        session.tapKey(code: ScrcpyWire.KeyCode.cut)
    }

    override func selectAll(_ sender: Any?) {
        session.tapKey(code: ScrcpyWire.KeyCode.a, meta: ScrcpyWire.metaCtrl)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])

        // Plain printable text → inject_text
        if mods.subtracting([.shift]).isEmpty || mods.isEmpty,
           let chars = event.characters,
           let first = chars.unicodeScalars.first,
           first.value >= 32, first.value != 127 {
            session.sendText(chars)
            return
        }

        mapSpecial(event)?.forEach { session.tapKey(code: $0) }
    }

    /// Carbon-era key codes — stable across SDKs, unlike SpecialKey names.
    private func mapSpecial(_ event: NSEvent) -> [UInt32]? {
        switch Int(event.keyCode) {
        case 36, 76: return [ScrcpyWire.KeyCode.enter] // Return / keypad Enter
        case 48: return [ScrcpyWire.KeyCode.tab]
        case 53: return [ScrcpyWire.KeyCode.back] // Esc → Back, like Android
        case 51: return [ScrcpyWire.KeyCode.del] // Backspace / Delete
        case 117: return [ScrcpyWire.KeyCode.forwardDel]
        case 115: return [ScrcpyWire.KeyCode.moveHome]
        case 119: return [ScrcpyWire.KeyCode.moveEnd]
        case 116: return [ScrcpyWire.KeyCode.pageUp]
        case 121: return [ScrcpyWire.KeyCode.pageDown]
        case 126: return [ScrcpyWire.KeyCode.dpadUp]
        case 125: return [ScrcpyWire.KeyCode.dpadDown]
        case 123: return [ScrcpyWire.KeyCode.dpadLeft]
        case 124: return [ScrcpyWire.KeyCode.dpadRight]
        default: return nil
        }
    }
}
