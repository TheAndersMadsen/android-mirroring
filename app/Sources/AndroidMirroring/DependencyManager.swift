import Foundation
import AppKit

/// Manages discovery AND self-installation of dependencies (adb, scrcpy).
/// The app bootstraps itself: missing pieces are downloaded to
/// ~/Library/Application Support/AndroidMirroring — no admin required.
@MainActor
final class DependencyManager: ObservableObject {

    static let shared = DependencyManager()

    // MARK: - Published state

    @Published var adbPath: String?
    @Published var adbInstalling = false
    @Published var adbInstallError: String?

    @Published var serverJar: String?
    @Published var serverVersion: String?
    @Published var serverInstalling = false
    @Published var serverInstallError: String?

    @Published var scrcpyVersion: String = "4.1"

    // MARK: - Paths

    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AndroidMirroring", isDirectory: true)
    }

    static var localADB: URL { supportDir.appendingPathComponent("platform-tools/adb") }
    static var localServer: URL { supportDir.appendingPathComponent("scrcpy-server") }

    // MARK: - Scan

    func scan() {
        adbPath = Self.findADB()
        let server = Self.findServerJar()
        serverJar = server?.path
        serverVersion = server?.version
    }

    static func findADB() -> String? {
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["ANDROID_MIRRORING_ADB"], !env.isEmpty {
            candidates.append(env)
        }
        candidates += [
            localADB.path,                                        // self-installed
            "/opt/homebrew/bin/adb",                              // Homebrew
            "/usr/local/bin/adb",
            NSHomeDirectory() + "/.local/share/device-safety/bin/adb",
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        // PATH lookup via login shell (app may have minimal env from Finder)
        let zsh = Process()
        zsh.executableURL = URL(fileURLWithPath: "/bin/zsh")
        zsh.arguments = ["-lc", "command -v adb 2>/dev/null"]
        let pipe = Pipe()
        zsh.standardOutput = pipe
        zsh.standardError = FileHandle.nullDevice
        zsh.standardInput = FileHandle.nullDevice
        do {
            try zsh.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            zsh.waitUntilExit()
            if let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty,
               FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch {}
        return nil
    }

    static func findServerJar() -> (path: String, version: String)? {
        // 1. Explicit override
        if let env = ProcessInfo.processInfo.environment["ANDROID_MIRRORING_SERVER"], !env.isEmpty,
           FileManager.default.isReadableFile(atPath: env) {
            let v = ProcessInfo.processInfo.environment["ANDROID_MIRRORING_SERVER_VERSION"]
                ?? detectScrcpyVersion() ?? bundledServerVersion()
            return (env, v)
        }
        // 2. Self-installed (downloaded by this manager)
        if FileManager.default.isReadableFile(atPath: localServer.path) {
            return (localServer.path, detectScrcpyVersion() ?? bundledServerVersion())
        }
        // 3. Homebrew scrcpy
        for prefix in ["/opt/homebrew", "/usr/local"] {
            let jar = "\(prefix)/share/scrcpy/scrcpy-server"
            if FileManager.default.isReadableFile(atPath: jar) {
                return (jar, detectScrcpyVersion(prefix: prefix) ?? bundledServerVersion())
            }
        }
        // 4. This .app bundle's Resources
        let bundleJar = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/scrcpy-server")
        if FileManager.default.isReadableFile(atPath: bundleJar.path) {
            return (bundleJar.path, detectScrcpyVersion() ?? bundledServerVersion())
        }
        // 5. SPM module resources → copy to Application Support
        if let bundled = Bundle.module.url(forResource: "scrcpy-server", withExtension: nil) {
            do {
                try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: localServer.path) {
                    try FileManager.default.copyItem(at: bundled, to: localServer)
                }
                return (localServer.path, bundledServerVersion())
            } catch {}
        }
        return nil
    }

    private static func bundledServerVersion() -> String { "4.1" }

    private static func detectScrcpyVersion(prefix: String = "/opt/homebrew") -> String? {
        let bin = "\(prefix)/bin/scrcpy"
        guard FileManager.default.isExecutableFile(atPath: bin) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["--version"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard let _ = try? p.run() else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let first = String(data: data, encoding: .utf8)?
            .split(separator: "\n").first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2, let v = parts[1].split(separator: "-").first else { return nil }
        return String(v)
    }

    // MARK: - Install adb (platform-tools from Google)

    func installADB() async {
        guard !adbInstalling else { return }
        adbInstalling = true
        adbInstallError = nil
        defer { adbInstalling = false }

        do {
            try FileManager.default.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
            let zipDest = Self.supportDir.appendingPathComponent("platform-tools.zip")

            // Download official platform-tools from Google (~5 MB)
            let url = URL(string: "https://dl.google.com/android/repository/platform-tools-latest-darwin.zip")!
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else {
                throw InstallError("Download failed (status \((response as? HTTPURLResponse)?.statusCode ?? -1))")
            }
            try data.write(to: zipDest)

            // Unzip (strips to platform-tools/)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-o", zipDest.path, "-d", Self.supportDir.path]
            unzip.standardOutput = FileHandle.nullDevice
            unzip.standardError = FileHandle.nullDevice
            try unzip.run()
            unzip.waitUntilExit()
            guard unzip.terminationStatus == 0 else {
                throw InstallError("Unzip failed")
            }
            try? FileManager.default.removeItem(at: zipDest)

            // Make executable
            let adb = Self.localADB
            guard FileManager.default.isExecutableFile(atPath: adb.path) else {
                throw InstallError("adb not found after extraction")
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)

            // Kill any stale adb server so the new one takes over cleanly
            let _ = try? await Shell.run(adb.path, ["kill-server"])

            adbPath = adb.path
        } catch {
            adbInstallError = String(describing: error)
        }
    }

    // MARK: - Install scrcpy server

    func installServer() async {
        guard !serverInstalling else { return }
        serverInstalling = true
        serverInstallError = nil
        defer { serverInstalling = false }

        do {
            try FileManager.default.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)

            // Try bundled first (SPM resource), then download from GitHub releases
            if let bundled = Bundle.module.url(forResource: "scrcpy-server", withExtension: nil),
               FileManager.default.isReadableFile(atPath: bundled.path) {
                try FileManager.default.copyItem(at: bundled, to: Self.localServer)
                serverJar = Self.localServer.path
                serverVersion = Self.bundledServerVersion()
                return
            }

            // Download from scrcpy GitHub releases (Apache-2.0)
            let version = scrcpyVersion
            let url = URL(string: "https://github.com/Genymobile/scrcpy/releases/download/v\(version)/scrcpy-server-v\(version)")!
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else {
                throw InstallError("Download failed (status \((response as? HTTPURLResponse)?.statusCode ?? -1))")
            }
            try data.write(to: Self.localServer)
            serverJar = Self.localServer.path
            serverVersion = version
        } catch {
            serverInstallError = String(describing: error)
        }
    }
}

struct InstallError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}
