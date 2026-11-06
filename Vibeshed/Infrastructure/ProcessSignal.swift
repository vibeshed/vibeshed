import Darwin

/// `pkill -x` without the subprocess: finds processes by name through libproc and signals
/// them directly. Running `pkill` through `ShellCommand`'s login shell took seconds while
/// a theme preview kept the machine busy; this takes well under a millisecond.
enum ProcessSignal {
    /// Sends `signal` to every process named exactly `name` (its command name, as with
    /// `pkill -x`) that this user may signal, never Vibeshed itself. Returns how many got it.
    @discardableResult
    static func send(_ signal: Int32, toProcessesNamed name: String) -> Int {
        pids(named: name).filter { kill($0, signal) == 0 }.count
    }

    static func pids(named name: String) -> [pid_t] {
        allPIDs().filter { $0 > 0 && $0 != getpid() && processName($0) == name }
    }

    private static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        // Headroom for processes started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count)))
    }

    private static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
