import Foundation
import Combine

struct AndroidDevice: Identifiable, Equatable {
    let serial: String
    let model: String
    let state: String
    var id: String { serial }
    var isReady: Bool { state == "device" }
}

/// Polls `adb devices -l` and publishes attached Android devices.
/// Uses DependencyManager for the adb path so self-installed adb works.
@MainActor
final class DeviceMonitor: ObservableObject {

    @Published private(set) var devices: [AndroidDevice] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastError: String?
    /// True once we've completed at least one successful adb scan.
    @Published private(set) var hasCompletedFirstScan = false

    private var timer: Timer?
    private var inFlight = false
    private var startupBurst = 0

    var adbPath: String? { DependencyManager.shared.adbPath }
    var server: (path: String, version: String)? {
        guard let p = DependencyManager.shared.serverJar,
              let v = DependencyManager.shared.serverVersion else { return nil }
        return (p, v)
    }

    var firstReadyDevice: AndroidDevice? { devices.first(where: \.isReady) }

    func start() {
        // Poll fast at startup (5× at 300ms) then settle to 1.5s.
        // This closes the "no device detected" gap while adb server warms up.
        startupBurst = 5
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !inFlight else { return }
        guard let adb = DependencyManager.shared.adbPath else {
            devices = []
            return
        }
        inFlight = true
        isScanning = true
        // If we're in the startup burst, schedule the next fast poll now.
        if startupBurst > 0 {
            startupBurst -= 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.refresh()
            }
        }
        Task.detached(priority: .utility) {
            let result = (try? await Shell.run(adb, ["devices", "-l"]))
                ?? Shell.Result(code: -1, out: "", err: "failed to run adb")
            await MainActor.run {
                defer {
                    self.inFlight = false
                    self.isScanning = false
                }
                if result.isSuccess {
                    self.lastError = nil
                    self.hasCompletedFirstScan = true
                    // Assigning an equal array still publishes; skip it so
                    // every 1.5 s poll doesn't re-render the UI.
                    let parsed = Self.parse(result.out)
                    if parsed != self.devices { self.devices = parsed }
                } else {
                    self.lastError = result.err.isEmpty ? "adb exited with \(result.code)" : result.err
                }
            }
        }
    }

    nonisolated static func parse(_ output: String) -> [AndroidDevice] {
        var found: [AndroidDevice] = []
        for line in output.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let serial = String(parts[0])
            let state = String(parts[1])
            guard state == "device" || state == "unauthorized" || state == "offline" else { continue }
            var model = serial
            for p in parts[2...] {
                if p.hasPrefix("model:") {
                    model = decodePercent(String(p.dropFirst("model:".count)))
                }
            }
            found.append(AndroidDevice(serial: serial, model: model, state: state))
        }
        return found
    }

    private nonisolated static func decodePercent(_ s: String) -> String {
        s.replacingOccurrences(of: "%20", with: " ")
         .replacingOccurrences(of: "%22", with: "\"")
         .replacingOccurrences(of: "%3A", with: ":")
    }
}
