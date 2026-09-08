import Foundation

struct ShellResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { exitCode == 0 }
    var combinedOutput: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

enum ShellError: LocalizedError {
    case failed(command: String, result: ShellResult)

    var errorDescription: String? {
        switch self {
        case .failed(let command, let result):
            return "`\(command)` exited \(result.exitCode): \(result.combinedOutput.prefix(500))"
        }
    }
}

enum Shell {
    /// Runs an executable directly (no shell interpretation of arguments).
    static func run(
        _ executable: String,
        _ arguments: [String],
        cwd: URL? = nil,
        stdin: String? = nil
    ) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let cwd { process.currentDirectoryURL = cwd }

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            if let stdin {
                let inPipe = Pipe()
                process.standardInput = inPipe
                inPipe.fileHandleForWriting.write(Data(stdin.utf8))
                inPipe.fileHandleForWriting.closeFile()
            }

            process.terminationHandler = { proc in
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let result = ShellResult(
                    exitCode: proc.terminationStatus,
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? ""
                )
                continuation.resume(returning: result)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Like `run`, but delivers stdout line by line while the process is still
    /// alive. `onLine` fires on a background queue, in order, once per complete
    /// line (the trailing fragment, if any, is delivered at exit). The returned
    /// result still carries the full stdout/stderr.
    ///
    /// When `handle` is passed, it is attached to the live `Process` as soon as
    /// it launches, so the caller can `terminate()` it from outside this call.
    static func stream(
        _ executable: String,
        _ arguments: [String],
        cwd: URL? = nil,
        stdin: String? = nil,
        handle: ShellHandle? = nil,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let cwd { process.currentDirectoryURL = cwd }

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            let inPipe: Pipe? = stdin == nil ? nil : Pipe()
            if let inPipe { process.standardInput = inPipe }

            let collector = StreamCollector(onLine: onLine)
            let group = DispatchGroup()

            // Blocking reads on background queues: `availableData` returns as
            // soon as bytes arrive and returns empty at EOF.
            for (handle, isStdout) in [
                (outPipe.fileHandleForReading, true),
                (errPipe.fileHandleForReading, false)
            ] {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    while true {
                        let data = handle.availableData
                        if data.isEmpty { break }
                        if isStdout {
                            collector.appendStdout(data)
                        } else {
                            collector.appendStderr(data)
                        }
                    }
                    group.leave()
                }
            }

            let exitCode = Atomic<Int32>(-1)
            group.enter()
            process.terminationHandler = { proc in
                exitCode.value = proc.terminationStatus
                group.leave()
            }

            group.notify(queue: .global(qos: .userInitiated)) {
                continuation.resume(returning: collector.finish(exitCode: exitCode.value))
            }

            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
                return
            }
            handle?.attach(process)

            // Written after launch so a prompt larger than the pipe buffer
            // cannot deadlock against a child that is not reading yet.
            if let inPipe, let stdin {
                DispatchQueue.global(qos: .utility).async {
                    let handle = inPipe.fileHandleForWriting
                    try? handle.write(contentsOf: Data(stdin.utf8))
                    try? handle.close()
                }
            }
        }
    }

    /// Runs a command line through a login shell so the user's PATH applies (needed to find `claude`).
    static func runInLoginShell(
        _ commandLine: String,
        cwd: URL? = nil,
        stdin: String? = nil
    ) async throws -> ShellResult {
        try await run("/bin/zsh", ["-l", "-c", commandLine], cwd: cwd, stdin: stdin)
    }

    /// Streaming counterpart of `runInLoginShell`.
    static func streamInLoginShell(
        _ commandLine: String,
        cwd: URL? = nil,
        stdin: String? = nil,
        handle: ShellHandle? = nil,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> ShellResult {
        try await stream(
            "/bin/zsh", ["-l", "-c", commandLine],
            cwd: cwd, stdin: stdin, handle: handle, onLine: onLine
        )
    }

    @discardableResult
    static func runChecked(
        _ executable: String,
        _ arguments: [String],
        cwd: URL? = nil
    ) async throws -> ShellResult {
        let result = try await run(executable, arguments, cwd: cwd)
        guard result.succeeded else {
            throw ShellError.failed(
                command: ([executable] + arguments).joined(separator: " "),
                result: result
            )
        }
        return result
    }
}

/// Lets a caller stop a `stream`/`streamInLoginShell` invocation from outside
/// the `async` call. Create one, pass it in via `handle:`, and call
/// `terminate()` once the process should be killed. A `terminate()` that
/// arrives before the process has actually launched is remembered and applied
/// as soon as it does, so there is no race between "cancel tapped" and
/// "process started".
final class ShellHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var terminateRequested = false

    func terminate() {
        lock.lock()
        let proc = process
        terminateRequested = true
        lock.unlock()
        proc?.terminate()
    }

    fileprivate func attach(_ process: Process) {
        lock.lock()
        let shouldTerminate = terminateRequested
        self.process = process
        lock.unlock()
        if shouldTerminate { process.terminate() }
    }
}

/// Accumulates a child process's output and splits stdout into whole lines.
/// Touched from two reader queues plus the termination handler, so every
/// mutation is behind a lock.
private final class StreamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let onLine: @Sendable (String) -> Void
    private var pending = Data()
    private var stdoutText = ""
    private var stderrText = ""

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func appendStdout(_ data: Data) {
        var lines: [String] = []
        lock.lock()
        pending.append(data)
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...newline)
            stdoutText += line + "\n"
            lines.append(line)
        }
        lock.unlock()
        // Outside the lock: the callback hops to the main actor.
        for line in lines { onLine(line) }
    }

    func appendStderr(_ data: Data) {
        lock.lock()
        stderrText += String(decoding: data, as: UTF8.self)
        lock.unlock()
    }

    /// Flushes a trailing line without a newline and returns the full result.
    func finish(exitCode: Int32) -> ShellResult {
        lock.lock()
        var trailing: String?
        if !pending.isEmpty {
            let line = String(decoding: pending, as: UTF8.self)
            pending.removeAll()
            stdoutText += line
            trailing = line
        }
        let result = ShellResult(exitCode: exitCode, stdout: stdoutText, stderr: stderrText)
        lock.unlock()
        if let trailing { onLine(trailing) }
        return result
    }
}

/// Minimal lock-guarded box, used to hand the exit code from the termination
/// handler to the queue that resumes the continuation.
private final class Atomic<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}
