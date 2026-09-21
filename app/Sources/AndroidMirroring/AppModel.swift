import Foundation
import Combine

/// Composition root: device watch + active mirror session + dependency management.
@MainActor
final class AppModel: ObservableObject {

    let monitor = DeviceMonitor()
    let session = MirrorSession()
    let deps = DependencyManager.shared
    @Published var autoConnect = true

    /// Device the user explicitly disconnected from. Auto-connect leaves it
    /// alone until it's unplugged (or the user hits Connect), otherwise
    /// "Disconnect" would just reconnect half a second later.
    private var dismissedSerial: String?

    private var cancellables: Set<AnyCancellable> = []

    private var started = false

    func start() {
        // onAppear fires per window; only wire things up once.
        guard !started else { return }
        started = true
        deps.scan()
        monitor.start()

        // Auto-connect when a device shows up and dependencies are ready
        monitor.$devices
            .combineLatest(deps.$adbPath, deps.$serverJar)
            .receive(on: RunLoop.main)
            .sink { [weak self] devices, adb, server in
                guard let self, self.autoConnect else { return }
                self.tryAutoConnect(devices: devices, adb: adb, server: server)
            }
            .store(in: &cancellables)

        // Also reconnect when the session drops back to idle after a
        // disconnect — the combineLatest above won't re-fire because its
        // inputs didn't change.
        session.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                guard let self, self.autoConnect else { return }
                if case .idle = phase {
                    // Slight delay to let the old session fully tear down
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self, self.autoConnect else { return }
                        if case .idle = self.session.phase {
                            self.tryAutoConnect(
                                devices: self.monitor.devices,
                                adb: self.deps.adbPath,
                                server: self.deps.serverJar)
                        }
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func tryAutoConnect(devices: [AndroidDevice], adb: String?, server: String?) {
        guard autoConnect else { return }
        if let dismissed = dismissedSerial, !devices.contains(where: { $0.serial == dismissed }) {
            dismissedSerial = nil
        }
        if case .idle = session.phase {
            if let device = devices.first(where: { $0.isReady && $0.serial != dismissedSerial }),
               let adb, let server,
               let version = deps.serverVersion {
                session.start(
                    serial: device.serial,
                    adb: adb,
                    serverJar: server,
                    version: version)
            }
        }
    }

    func connect(to device: AndroidDevice) {
        guard let adb = deps.adbPath,
              let server = deps.serverJar,
              let version = deps.serverVersion else { return }
        dismissedSerial = nil
        session.start(serial: device.serial, adb: adb, serverJar: server, version: version)
    }

    func disconnect() {
        if session.phase.isLive {
            dismissedSerial = session.serial
        }
        session.stop()
    }

    func fixAll() {
        Task {
            if deps.adbPath == nil {
                await deps.installADB()
            }
            if deps.serverJar == nil {
                await deps.installServer()
            }
            deps.scan()
            monitor.refresh()
        }
    }
}
