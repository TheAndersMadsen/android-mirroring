import Foundation

/// Async wrapper around Process for short-lived commands.
enum Shell {

    struct Result {
        let code: Int32
        let out: String
        let err: String
        var isSuccess: Bool { code == 0 }
    }

    static func run(_ executable: String, _ args: [String]) async throws -> Result {
        await Task.detached(priority: .userInitiated) {
            runBlocking(executable, args)
        }.value
    }

    /// Blocking variant, for app termination where no async work survives.
    @discardableResult
    static func runBlocking(_ executable: String, _ args: [String]) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return Result(code: -1, out: "", err: error.localizedDescription)
        }
        // Drain both pipes before waiting: a child that fills a pipe
        // buffer (64 KB) blocks forever if nobody is reading.
        var errData = Data()
        let errDone = DispatchGroup()
        errDone.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            errDone.leave()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        errDone.wait()
        p.waitUntilExit()
        return Result(code: p.terminationStatus,
                      out: String(data: outData, encoding: .utf8) ?? "",
                      err: String(data: errData, encoding: .utf8) ?? "")
    }

    /// Starts a long-lived process, streaming stderr lines to `onLine`
    /// (called on a background queue). Returns the running Process.
    static func startStreaming(_ executable: String,
                               _ args: [String],
                               onLine: @escaping (String) -> Void) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = outPipe
        p.standardInput = FileHandle.nullDevice
        let fh = outPipe.fileHandleForReading
        fh.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let s = String(data: chunk, encoding: .utf8) else {
                handle.readabilityHandler = nil
                return
            }
            onLine(s)
        }
        try p.run()
        return p
    }
}
