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
    /// calling task stops it too, and throws `CancellationError`. Either answers at once,
    /// without waiting for the tool to go: it gets SIGTERM, and SIGKILL if it's still there
    /// after `ProcessControl.killGrace`.
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
                control.onStop { gate.resume(with: .failure($0)) }
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        // Stopped before it started: `onStop` has answered already.
                        guard try control.launch() else { return }
                    } catch {
                        gate.resume(with: .failure(error))
                        return
                    }
                    let timeoutWorkItem = timeout.map { seconds in
                        let item = DispatchWorkItem { control.stop(because: RunError.timedOut(seconds)) }
                        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
                        return item
                    }

                    // After a stop this thread still drains and reaps the tool, but nobody is
                    // waiting on it: the stop answered, and the gate ignores this answer.
                    let (outputData, errorData) = drain(stdoutPipe, stderrPipe)
                    process.waitUntilExit()
                    timeoutWorkItem?.cancel()
                    gate.resume(with: .success(
                        Output(status: process.terminationStatus, stdout: outputData, stderr: errorData)
                    ))
                }
            }
        } onCancel: {
            control.stop(because: CancellationError())
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
    /// How long a stopped tool has to exit on SIGTERM before it gets SIGKILL.
    static let killGrace: TimeInterval = 1

    private let lock = NSLock()
    private let process: Process
    private var launched = false
    private var stopReason: Error?
    private var answerStop: ((Error) -> Void)?

    init(_ process: Process) {
        self.process = process
    }

    /// `answer` gets the reason of the first stop, right away if the run was stopped already.
    func onStop(_ answer: @escaping (Error) -> Void) {
        let reason: Error? = lock.withLock {
            if stopReason == nil {
                answerStop = answer
            }
            return stopReason
        }
        if let reason {
            answer(reason)
        }
    }

    /// Launches the process unless it was stopped already; false if it was.
    func launch() throws -> Bool {
        try lock.withLock {
            guard stopReason == nil else { return false }
            try process.run()
            launched = true
            return true
        }
    }

    /// Answers the run with `reason` and stops the process: SIGTERM now, SIGKILL if it's
    /// still running `killGrace` later. Only the first stop counts.
    func stop(because reason: Error) {
        let answer: ((Error) -> Void)? = lock.withLock {
            guard stopReason == nil else { return nil }
            stopReason = reason
            if launched, process.isRunning {
                process.terminate()
                let process = process
                let pid = process.processIdentifier
                DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGrace) {
                    if process.isRunning {
                        kill(pid, SIGKILL)
                    }
                }
            }
            defer { answerStop = nil }
            return answerStop
        }
        answer?(reason)
    }
}
