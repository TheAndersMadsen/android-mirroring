import SwiftUI
import AppKit

@main
struct AndroidMirroringApp: App {

    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onAppear {
                    appDelegate.model = model
                    model.start()
                }
                .background(WindowConfigurator())
                .background(Color.clear)  // ensure no default background
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            TextEditingCommands()

            CommandMenu("Controls") {
                Button("Home Screen") { model.session.tapKey(code: ScrcpyWire.KeyCode.home) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("App Switcher") { model.session.tapKey(code: ScrcpyWire.KeyCode.appSwitch) }
                    .keyboardShortcut("2", modifiers: .command)
                Divider()
                Button("Notifications") {
                    model.session.send(ScrcpyWire.simple(ScrcpyWire.MessageType.expandNotificationPanel))
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Quick Settings") {
                    model.session.send(ScrcpyWire.simple(ScrcpyWire.MessageType.expandSettingsPanel))
                }
                .keyboardShortcut("q", modifiers: [.command, .shift])
                Divider()
                Button("Volume Up") { model.session.tapKey(code: ScrcpyWire.KeyCode.volumeUp) }
                    .keyboardShortcut("+", modifiers: [.command, .shift])
                Button("Volume Down") { model.session.tapKey(code: ScrcpyWire.KeyCode.volumeDown) }
                    .keyboardShortcut("-", modifiers: [.command, .shift])
                Divider()
                Button("Rotate Device") {
                    model.session.send(ScrcpyWire.simple(ScrcpyWire.MessageType.rotateDevice))
                }
                .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("Disconnect") { model.disconnect() }
                    .keyboardShortcut("w", modifiers: .command)
            }
        }
    }
}

/// Strips ALL window chrome and visual remnants.
/// The phone shape IS the window — nothing else visible.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        DispatchQueue.main.async {
            guard let window = view.window else { return }

            // Fully borderless
            window.styleMask = [.borderless]

            // Kill the system shadow — it renders as a visible outline
            // around borderless windows. We use SwiftUI .shadow() instead.
            window.hasShadow = false

            // Full transparency
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isMovableByWindowBackground = true
            window.animationBehavior = .documentWindow
            window.ignoresMouseEvents = false

            // Remove standard window buttons
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true

            // Strip any system content view backgrounds
            if let contentView = window.contentView {
                contentView.wantsLayer = true
                // Remove all system-provided views that add visual chrome
                for subview in contentView.subviews {
                    if subview is NSVisualEffectView || subview.className.contains("NSTitlebar") {
                        subview.removeFromSuperview()
                    }
                }
                // Ensure the content view itself is transparent
                if let layer = contentView.layer {
                    layer.backgroundColor = NSColor.clear.cgColor
                }
            }

            NSLog("AM-WINDOW borderless configured")
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Set by the app's root view; lets termination tear the session down.
    weak var model: AppModel?

    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `kill` and ^C should clean up like ⌘Q does, not strand the adb
        // forward and the server on the device.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stops the device-side server and removes the adb forward, which
        // would otherwise outlive the app.
        model?.session.stop(synchronously: true)
    }
}
