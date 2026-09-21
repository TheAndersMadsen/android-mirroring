import Foundation

/// Locates external tools (adb, scrcpy-server) at runtime, with sensible
/// discovery order: explicit env override → known Homebrew/SDK paths → $PATH.
enum ToolLocator {

    static func findADB() -> String? {
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["ANDROID_MIRRORING_ADB"], !env.isEmpty {
            candidates.append(env)
        }
        candidates += [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            NSHomeDirectory() + "/.local/share/device-safety/bin/adb",
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        // App may have a minimal PATH when launched from Finder; ask a login shell.
        let zsh = Process()
        zsh.executableURL = URL(fileURLWithPath: "/bin/zsh")
        zsh.arguments = ["-lc", "command -v adb 2>/dev/null"]
        let pipe = Pipe()
        zsh.standardOutput = pipe
        zsh.standardError = FileHandle.nullDevice
        if let _ = try? zsh.run() {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            zsh.waitUntilExit()
            if let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty,
               FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Returns the scrcpy server jar to push, plus the exact server version
    /// string that must be passed to `app_process` on the device.
    static func findServerJar() -> (path: String, version: String)? {
        // 1. Explicit overrides
        if let env = ProcessInfo.processInfo.environment["ANDROID_MIRRORING_SERVER"], !env.isEmpty {
            let version = ProcessInfo.processInfo.environment["ANDROID_MIRRORING_SERVER_VERSION"]
                ?? detectScrcpyVersion()
                ?? bundledServerVersion()
            if FileManager.default.isReadableFile(atPath: env) {
                return (env, version)
            }
        }
        // 2. Homebrew scrcpy install (jar + version stay in sync via the binary)
        for prefix in ["/opt/homebrew", "/usr/local"] {
            let jar = "\(prefix)/share/scrcpy/scrcpy-server"
            if FileManager.default.isReadableFile(atPath: jar) {
                return (jar, detectScrcpyVersion(prefix: prefix) ?? bundledServerVersion())
            }
        }
        // 3. Jar in this .app bundle's Resources (installed alongside the binary)
        let bundleJar = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/scrcpy-server")
        if FileManager.default.isReadableFile(atPath: bundleJar.path) {
            return (bundleJar.path, detectScrcpyVersion() ?? bundledServerVersion())
        }
        // 4. Jar bundled in this SPM module's resources, copied to Application Support
        if let bundled = bundledServerURL() {
            let dest = installBundledServer(from: bundled)
            if let dest {
                return (dest, bundledServerVersion())
            }
        }
        return nil
    }

    // MARK: - Internals

    private static func bundledServerURL() -> URL? {
        Bundle.module.url(forResource: "scrcpy-server", withExtension: nil)
    }

    private static func bundledServerVersion() -> String {
        // Must match the scrcpy-server jar shipped in Resources/.
        "4.1"
    }

    private static func installBundledServer(from src: URL) -> String? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AndroidMirroring", isDirectory: true)
        let dest = dir.appendingPathComponent("scrcpy-server")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.copyItem(at: src, to: dest)
            }
            return dest.path
        } catch {
            return nil
        }
    }

    private static func detectScrcpyVersion(prefix: String = "/opt/homebrew") -> String? {
        let bin = "\(prefix)/bin/scrcpy"
        guard FileManager.default.isExecutableFile(atPath: bin) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["--version"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard let _ = try? p.run() else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let first = String(data: data, encoding: .utf8)?
            .split(separator: "\n").first else { return nil }
        // e.g. "scrcpy 4.1 <https://github.com/Genymobile/scrcpy>"
        let parts = first.split(separator: " ")
        guard parts.count >= 2, let v = parts[1].split(separator: "-").first else { return nil }
        return String(v)
    }
}
