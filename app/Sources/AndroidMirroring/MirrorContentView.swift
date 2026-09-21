import SwiftUI
import AppKit

/// Faithful replica of iPhone Mirroring's device window:
/// borderless phone-shaped floating window, thin black bezel,
/// dramatically rounded corners, auto-hiding toolbar.
/// Drag the bezel edge to move the window (like iPhone Mirroring).
struct MirrorContentView: View {
    @ObservedObject var session: MirrorSession
    @State private var chromeVisible = false
    @State private var scalePreset: WindowScalePreset = .actualSize
    @State private var showBlur = false
    @State private var wasConnected = false

    var body: some View {
        ZStack {
            screenContent
                .padding(bezelWidth)
        }
        .frame(width: totalSize.width, height: totalSize.height)
        .background(bezelShape)  // bezel behind the screen
        .animation(.spring(response: 0.35, dampingFraction: 0.88), value: scalePreset)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: session.videoSize)
        .onChange(of: session.phase) { _, newPhase in
            handlePhaseChange(newPhase)
        }
        .onAppear {
            wasConnected = session.phase.isConnected
        }
    }

    // MARK: - Bezel (grabbable for window movement)

    /// The bezel — solid black border around the screen.
    /// Click and drag it to move the window (uses isMovableByWindowBackground).
    private var bezelShape: some View {
        RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
            .fill(Color.black)
    }

    // MARK: - Screen

    private var screenContent: some View {
        ZStack {
            PlayerView(session: session) { mouseY in
                let shouldShow = mouseY < 0.22
                if shouldShow != chromeVisible {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        chromeVisible = shouldShow
                    }
                }
            }

            if startingUp {
                connectingOverlay
            }

            if chromeVisible && session.phase.isConnected {
                chromeBar
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if showBlur {
                disconnectBlur
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    // MARK: - Chrome Toolbar

    private var chromeBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                chromeBtn("house.fill", "Home") {
                    session.tapKey(code: ScrcpyWire.KeyCode.home)
                }
                chromeBtn("square.grid.2x2.fill", "Apps") {
                    session.tapKey(code: ScrcpyWire.KeyCode.appSwitch)
                }
                chromeBtn("arrow.counterclockwise", "Back") {
                    session.tapKey(code: ScrcpyWire.KeyCode.back)
                }

                Spacer()

                HStack(spacing: 4) {
                    scaleBtn("minus.magnifyingglass") { scalePreset = .smaller }
                    scaleBtn("1.magnifyingglass") { scalePreset = .actualSize }
                    scaleBtn("plus.magnifyingglass") { scalePreset = .larger }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.black.opacity(0.78))
            )
            .padding(.horizontal, 10)
            .padding(.top, 5)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func chromeBtn(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                Text(label)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .frame(minWidth: 38, minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func scaleBtn(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Overlays

    private var connectingOverlay: some View {
        ZStack {
            Color.black.opacity(0.75)
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                    .tint(.white)
                Text("Connecting to \(session.deviceName.isEmpty ? "your Android" : session.deviceName)…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .transition(.opacity)
    }

    private var disconnectBlur: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            VStack(spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Connection Interrupted")
                    .font(.system(size: 15, weight: .semibold))
                Text("Reconnecting…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                ProgressView().controlSize(.small)
            }
        }
        .transition(.opacity)
    }

    // MARK: - State

    private func handlePhaseChange(_ newPhase: MirrorSession.Phase) {
        let connected = newPhase.isConnected
        if wasConnected && !connected {
            withAnimation(.easeIn(duration: 0.15)) { showBlur = true }
        } else if !wasConnected && connected {
            withAnimation(.easeOut(duration: 0.5)) { showBlur = false }
        }
        wasConnected = connected
    }

    // MARK: - Sizing

    private var cornerRadius: CGFloat {
        max(16, screenSize.width * 0.145)
    }

    private var outerRadius: CGFloat {
        cornerRadius + bezelWidth * 0.5
    }

    /// Bezel width — thin but grabbable for window dragging
    private var bezelWidth: CGFloat { 10 }

    private var screenSize: CGSize {
        guard let s = session.videoSize, s.width > 0, s.height > 0 else {
            return CGSize(width: 302, height: 655)
        }
        // Scale by the LONGER edge so the visual size stays constant
        // whether the phone is portrait or landscape (like iPhone Mirroring).
        let maxEdge: CGFloat = 620 * scalePreset.multiplier
        let scale = maxEdge / max(s.width, s.height)
        return CGSize(width: (s.width * scale).rounded(), height: (s.height * scale).rounded())
    }

    private var totalSize: CGSize {
        CGSize(width: screenSize.width + bezelWidth * 2,
               height: screenSize.height + bezelWidth * 2)
    }

    private var startingUp: Bool {
        switch session.phase {
        case .pushingServer, .startingServer, .connecting: return true
        default: return false
        }
    }
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SessionRoot(model: model, session: model.session)
    }
}

private struct SessionRoot: View {
    let model: AppModel
    @ObservedObject var session: MirrorSession

    var body: some View {
        if sessionLive {
            MirrorContentView(session: session)
        } else {
            ConnectScreen(monitor: model.monitor, session: session)
        }
    }

    private var sessionLive: Bool {
        switch session.phase {
        case .pushingServer, .startingServer, .connecting, .connected:
            return true
        case .idle, .failed:
            return false
        }
    }
}
