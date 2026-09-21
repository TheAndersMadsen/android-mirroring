import SwiftUI

/// iPhone Mirroring-style onboarding + connect flow.
/// Three states: welcome (first run) → connect (normal) → confirmation.
/// Uses exact copy recovered from the ScreenContinuityUI binary.
struct ConnectScreen: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var monitor: DeviceMonitor
    @ObservedObject var session: MirrorSession
    @ObservedObject var deps = DependencyManager.shared
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        Group {
            if !hasCompletedOnboarding {
                OnboardingFlow(onComplete: {
                    hasCompletedOnboarding = true
                })
            } else {
                connectPane
            }
        }
    }

    // MARK: - Connect Pane (normal use)

    private var connectPane: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 28)

            HeroPhoneArt()
                .frame(width: 120, height: 155)
                .padding(.bottom, 14)

            Text("Connect to Your Android")
                .font(.system(size: 22, weight: .bold))
                .padding(.bottom, 4)

            Text(subtitleText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .padding(.bottom, 18)

            RequirementList(deps: deps)

            Spacer(minLength: 12)

            connectControl
                .padding(.bottom, 20)
        }
        .frame(minWidth: 540, minHeight: 560)
        .navigationTitle("Android Mirroring")
    }

    private var subtitleText: String {
        switch session.phase {
        case .pushingServer:
            return "Preparing Android Mirroring…"
        case .startingServer:
            return "Starting mirroring services…"
        case .connecting:
            return "Connecting to your Android…"
        default:
            return "Your Android will be fully accessible from this Mac when connected."
        }
    }

    @ViewBuilder
    private var connectControl: some View {
        switch session.phase {
        case .failed(let message):
            VStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 11))
                    .frame(maxWidth: 440)
                Button("Try Again") {
                    if let device = monitor.firstReadyDevice {
                        model.connect(to: device)
                    } else {
                        model.session.stop()
                    }
                }
            }
        case .pushingServer, .startingServer, .connecting:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(statusLine)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
            }
        case .connected:
            EmptyView()
        case .idle:
            if let device = monitor.firstReadyDevice {
                Button {
                    model.connect(to: device)
                } label: {
                    Text("Continue")
                        .frame(minWidth: 110)
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            } else if deps.adbPath == nil || deps.serverJar == nil {
                Button {
                    Task {
                        if deps.adbPath == nil { await deps.installADB() }
                        if deps.serverJar == nil { await deps.installServer() }
                        deps.scan()
                    }
                } label: {
                    Label("Fix Everything & Connect", systemImage: "wand.and.stars")
                        .frame(minWidth: 200)
                }
                .controlSize(.large)
                .disabled(deps.adbInstalling || deps.serverInstalling)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(monitor.hasCompletedFirstScan ? "No Android device detected" : "Looking for your Android…")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                }
            }
        }
    }

    private var statusLine: String {
        switch session.phase {
        case .pushingServer: return "Setting up…"
        case .startingServer: return "Starting services…"
        case .connecting: return "Connecting…"
        default: return ""
        }
    }
}

// MARK: - Onboarding Flow (first launch)

/// Matches iPhone Mirroring's onboarding sequence:
/// Welcome → Connect → Ready
private struct OnboardingFlow: View {
    @EnvironmentObject var model: AppModel
    let onComplete: () -> Void
    @State private var step = 0
    @State private var glowAnimation = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)

            // Step indicator
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule()
                        .fill(i <= step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: i == step ? 20 : 8, height: 3)
                        .animation(.spring(response: 0.3), value: step)
                }
            }
            .padding(.bottom, 30)

            // Step content
            Group {
                switch step {
                case 0: welcomeStep
                case 1: connectStep
                default: readyStep
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))

            Spacer(minLength: 30)
        }
        .frame(minWidth: 540, minHeight: 560)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: step)
    }

    // MARK: Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            HeroPhoneArt()
                .frame(width: 110, height: 142)

            Text("Welcome to Android Mirroring")
                .font(.system(size: 22, weight: .bold))

            VStack(alignment: .leading, spacing: 14) {
                OnboardingBullet(
                    icon: "hand.tap.fill",
                    title: "No need to reach for your Android",
                    subtitle: "Access your Android apps right from your Mac with just a click.")

                OnboardingBullet(
                    icon: "arrow.left.arrow.right",
                    title: "Move files between devices",
                    subtitle: "You can move photos, documents, and more from Android to Mac, or vice versa.")

                OnboardingBullet(
                    icon: "bell.badge.fill",
                    title: "Notifications at a glance",
                    subtitle: "Interact with your Android from notifications and the Dock.")
            }
            .padding(.horizontal, 40)

            Button {
                withAnimation { step = 1 }
            } label: {
                Text("Continue")
                    .frame(minWidth: 120)
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 10)
        }
    }

    // MARK: Step 2: Connect

    private var connectStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "cable.connector")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            Text("Connect to Your Android")
                .font(.system(size: 22, weight: .bold))

            Text("To set up Android Mirroring, make sure your Android is near this Mac, powered on, with USB debugging enabled and authorized.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            RequirementList(deps: model.deps)

            HStack(spacing: 12) {
                Button("Set Up Later") { onComplete() }
                Button {
                    withAnimation { step = 2 }
                } label: {
                    Text("Continue")
                        .frame(minWidth: 100)
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
    }

    // MARK: Step 3: Ready

    private var readyStep: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.1))
                    .frame(width: 90, height: 90)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
            }

            Text("Android Mirroring Is Ready to Use")
                .font(.system(size: 20, weight: .bold))

            Text("You're all set. When your Android is nearby and connected, you can seamlessly use it right from the desktop.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button {
                onComplete()
            } label: {
                Text("Get Started")
                    .frame(minWidth: 120)
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 10)
        }
    }
}

// MARK: - Onboarding Components

private struct OnboardingBullet: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 400, alignment: .leading)
    }
}

// MARK: - Requirements List

struct RequirementList: View {
    @ObservedObject var deps: DependencyManager
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            reqRow(
                ok: deps.adbPath != nil,
                installing: deps.adbInstalling,
                title: "Android Platform Tools",
                detail: deps.adbPath ?? "Not installed",
                installAction: deps.adbPath == nil ? { Task { await deps.installADB() } } : nil
            )
            divider
            reqRow(
                ok: deps.serverJar != nil,
                installing: deps.serverInstalling,
                title: "Mirroring Engine",
                detail: deps.serverVersion.map { "scrcpy \($0)" } ?? "Not installed",
                installAction: deps.serverJar == nil ? { Task { await deps.installServer() } } : nil
            )
            divider
            deviceRow
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quinary)
        )
        .frame(width: 400)
    }

    private var divider: some View {
        Divider().padding(.horizontal, 4)
    }

    private func reqRow(ok: Bool, installing: Bool, title: String, detail: String, installAction: (() -> Void)?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if installing {
                ProgressView().controlSize(.small).frame(width: 14)
            } else {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(ok ? .green : .orange)
                    .font(.system(size: 14))
                    .frame(width: 14)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(title).font(.system(size: 12, weight: .medium))
                    Spacer()
                    if let action = installAction, !installing {
                        Button("Install", action: action)
                            .controlSize(.mini)
                    }
                }
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 6)
    }

    private var deviceRow: some View {
        HStack(alignment: .top, spacing: 10) {
            if let _ = model.monitor.firstReadyDevice {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.system(size: 14)).frame(width: 14)
            } else if model.monitor.isScanning || !model.monitor.hasCompletedFirstScan {
                ProgressView().controlSize(.small).frame(width: 14)
            } else {
                Image(systemName: "smartphone")
                    .foregroundStyle(.secondary).font(.system(size: 14)).frame(width: 14)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(deviceTitle).font(.system(size: 12, weight: .medium))
                    Spacer()
                }
                Text(deviceDetail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private var deviceTitle: String {
        if let d = model.monitor.firstReadyDevice { return d.model }
        if !model.monitor.hasCompletedFirstScan { return "Scanning…" }
        return "No Android device detected"
    }

    private var deviceDetail: String {
        if let d = model.monitor.firstReadyDevice {
            return "Connected via \(d.serial.hasPrefix("192.168") ? "Wi-Fi" : "USB") · \(d.serial)"
        }
        return "Connect via USB and enable USB debugging"
    }
}

// MARK: - Hero Art

/// Animated phone hero for the connect/onboarding screens.
struct HeroPhoneArt: View {
    @State private var glow = false

    var body: some View {
        ZStack {
            // Glow effect
            Circle()
                .stroke(Color.accentColor.opacity(glow ? 0.25 : 0.05), lineWidth: 2)
                .frame(width: 130, height: 130)
                .scaleEffect(glow ? 1.15 : 0.85)
                .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: glow)

            Circle()
                .stroke(Color.accentColor.opacity(glow ? 0.12 : 0.03), lineWidth: 1)
                .frame(width: 160, height: 160)
                .scaleEffect(glow ? 1.25 : 0.75)

            // Phone shape
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.12), Color(white: 0.18)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: 10, y: 5)

            // Screen content placeholder
            VStack(spacing: 6) {
                Capsule()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 32, height: 7)
                    .padding(.top, 10)

                Spacer()

                Image(systemName: "smartphone")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(
                        LinearGradient(colors: [.blue, .cyan],
                                       startPoint: .top, endPoint: .bottom))
                    .opacity(glow ? 1 : 0.6)

                Spacer()

                Capsule()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 40, height: 4)
                    .padding(.bottom, 8)
            }
            .padding(8)
        }
        .onAppear { glow = true }
    }
}
