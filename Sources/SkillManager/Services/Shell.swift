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

    /// Runs a command line through a login shell so the user's PATH applies (needed to find `claude`).
    static func runInLoginShell(
        _ commandLine: String,
        cwd: URL? = nil,
        stdin: String? = nil
    ) async throws -> ShellResult {
        try await run("/bin/zsh", ["-l", "-c", commandLine], cwd: cwd, stdin: stdin)
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
