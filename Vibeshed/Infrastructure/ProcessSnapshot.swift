import Darwin
import Foundation

/// One process as the kernel reports it through `sysctl` (`KERN_PROC_PID`): enough to
/// tell whether a pid still belongs to the process a record was written by, and which
/// terminal it runs in. Needs no permission, even for other users' processes.
struct ProcessSnapshot: Sendable {
    let pid: pid_t
    let parentPID: pid_t
    /// The executable's name, cut to 16 characters ("iTermServer-3.7.").
    let name: String
    let startTime: Date
    /// The controlling terminal, e.g. "/dev/ttys003"; nil for a process without one.
    let tty: String?

    /// Nil when no process has `pid`. A zombie has exited, so it counts as none.
    init?(pid: pid_t) {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
              size > 0,
              Int32(info.kp_proc.p_stat) != SZOMB
        else { return nil }
        self.pid = pid
        parentPID = info.kp_eproc.e_ppid
        name = withUnsafeBytes(of: info.kp_proc.p_comm) { bytes in
            String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8) ?? ""
        }
        let start = info.kp_proc.p_starttime
        startTime = Date(
            timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        )
        tty = Self.ttyPath(info.kp_eproc.e_tdev)
    }

    /// The parent, its parent and so on, nearest first, stopping before launchd.
    func ancestors() -> [ProcessSnapshot] {
        var chain: [ProcessSnapshot] = []
        var next = parentPID
        // The cap guards against a loop of pids reused while walking.
        while next > 1, chain.count < 64, let parent = ProcessSnapshot(pid: next) {
            chain.append(parent)
            next = parent.parentPID
        }
        return chain
    }

    /// `NODEV` (-1) means no controlling terminal.
    private static func ttyPath(_ device: dev_t) -> String? {
        guard device != -1, let name = devname(device, S_IFCHR) else { return nil }
        let string = String(cString: name)
        return string.isEmpty || string == "??" ? nil : "/dev/\(string)"
    }
}
