import SwiftUI
import AppKit

/// A transparent strip at the top of the mirror window that allows
/// dragging to move the window — matching iPhone Mirroring's behavior
/// where you can grab the top area (near the traffic lights) to drag.
struct DragHandleView: NSViewRepresentable {
    var height: CGFloat = 28

    func makeNSView(context: Context) -> DragHandleNSView {
        let view = DragHandleNSView()
        view.setHeight(height)
        return view
    }

    func updateNSView(_ nsView: DragHandleNSView, context: Context) {
        nsView.setHeight(height)
    }
}

final class DragHandleNSView: NSView {
    private var handleHeight: CGFloat = 28

    func setHeight(_ h: CGFloat) {
        handleHeight = h
        needsLayout = true
    }

    override var acceptsFirstResponder: Bool { false }

    /// Any mouse down in this view starts a window drag.
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Invisible — just a hit-test area
    }
}
