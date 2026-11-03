import Foundation

/// Runs a command-line tool to its end and collects what it printed. Both pipes are
/// drained before waiting for the exit: a tool that fills a pipe's 64 KB buffer would
/// otherwise block forever, and the thread waiting on it with it.
enum ProcessRunner {
    struct Output: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data

        /// What the tool said on standard error, trimmed.
        var errorMessage: String {
            (String(bytes: stderr, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    enum RunError: LocalizedError, Equatable {
        case timedOut(TimeInterval)
        case inputTooLarge

        var errorDescription: String? {
            switch self {
            case let .timedOut(seconds): "Didn't finish within \(Int(seconds)) seconds"
            case .inputTooLarge: "The input is too large to pass to the tool"
            }
        }
    }

    /// `input` goes to the tool's standard input, written in full before the tool starts,
    /// so it has to fit the pipe's buffer. Without it, standard input is empty. A tool still
    /// running after `timeout` is stopped, and the run throws `timedOut`; cancelling the
    /// calling task stops it too, and throws `CancellationError`.
    static func run(
        _ executableURL: URL,
        arguments: [String],
        input: Data? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> Output {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = try standardInput(input)

        let control = ProcessControl(process)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let gate = ResumeGate(continuation: continuation)
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        guard try control.launch() else {
                            gate.resume(with: .failure(CancellationError()))
                            return
                        }
                    } catch {
                        gate.resume(with: .failure(error))
                        return
                    }
                    let timeoutWorkItem = timeout.map { seconds in
                        let item = DispatchWorkItem {
                            gate.resume(with: .failure(RunError.timedOut(seconds)))
                            control.stop()
                        }
                        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
                        return item
                    }

                    let (outputData, errorData) = drain(stdoutPipe, stderrPipe)
                    process.waitUntilExit()
                    timeoutWorkItem?.cancel()

                    if control.wasStopped {
                        gate.resume(with: .failure(CancellationError()))
                    } else {
                        gate.resume(with: .success(
                            Output(status: process.terminationStatus, stdout: outputData, stderr: errorData)
                        ))
                    }
                }
            }
        } onCancel: {
            control.stop()
        }
    }

    /// Writing more than this before the tool reads could block on a full pipe.
    static let maxInputSize = 60000

    /// A pipe already holding `input`, or the null device without it. Our own read end
    /// stays open until the pipe goes away, so the write can't raise SIGPIPE; it only has
    /// to fit the buffer, as the tool isn't reading yet.
    private static func standardInput(_ input: Data?) throws -> Any {
        guard let input else { return FileHandle.nullDevice }
        guard input.count < maxInputSize else { throw RunError.inputTooLarge }
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: input)
        try pipe.fileHandleForWriting.close()
        return pipe
    }

    /// Reads both pipes to their end at once, so neither can fill up while the other is read.
    private static func drain(_ stdout: Pipe, _ stderr: Pipe) -> (Data, Data) {
        let readGroup = DispatchGroup()
        // Safe: readGroup.wait() below is a happens-before barrier against both writes.
        nonisolated(unsafe) var outputData = Data()
        nonisolated(unsafe) var errorData = Data()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            outputData = stdout.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }
        readGroup.wait()
        return (outputData, errorData)
    }
}

/// Starts and stops one process from any thread. `terminate()` on a process that never
/// launched raises an exception, so a stop that comes first only keeps it from launching.
private final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var launched = false
    private var stopped = false

    init(_ process: Process) {
        self.process = process
    }

    var wasStopped: Bool {
        lock.withLock { stopped }
    }

    /// Launches the process unless it was stopped already; false if it was.
    func launch() throws -> Bool {
        try lock.withLock {
            guard !stopped else { return false }
            try process.run()
            launched = true
            return true
        }
    }

    func stop() {
        lock.withLock {
            stopped = true
            if launched, process.isRunning {
                process.terminate()
            }
        }
    }
}
