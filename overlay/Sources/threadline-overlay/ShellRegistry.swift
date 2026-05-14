import Darwin
import Foundation

/// Registry of recently-active shells, keyed by PID. Updated by the shell's
/// prompt hook calling `threadline-overlay touch …`. The daemon uses this to
/// answer "which cwd is the focused tab in?" by finding the most-recent touch
/// from a shell that is a descendant of the frontmost terminal app's PID.
final class ShellRegistry {
    static let shared = ShellRegistry()

    private struct Entry {
        let pid: pid_t
        let cwd: String
        let touchedAt: Date
    }

    private var entries: [pid_t: Entry] = [:]
    private let lock = NSLock()

    /// Entries older than this are pruned on each operation.
    private let ttl: TimeInterval = 30 * 60

    func touch(pid: pid_t, cwd: String) {
        lock.lock(); defer { lock.unlock() }
        entries[pid] = Entry(pid: pid, cwd: cwd, touchedAt: Date())
        prune()
    }

    struct Scope {
        let shellPid: pid_t
        let cwd: String
    }

    /// The most recently-active shell descended from `terminalPid`.
    /// Returns nil if no live touch matches.
    func scope(terminalPid: pid_t) -> Scope? {
        lock.lock(); defer { lock.unlock() }
        prune()
        let sorted = entries.values.sorted { $0.touchedAt > $1.touchedAt }
        for entry in sorted {
            if isDescendant(pid: entry.pid, ancestor: terminalPid) {
                return Scope(shellPid: entry.pid, cwd: entry.cwd)
            }
        }
        return nil
    }

    /// Compatibility shortcut: cwd only.
    func scopeCwd(terminalPid: pid_t) -> String? {
        scope(terminalPid: terminalPid)?.cwd
    }

    func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-ttl)
        entries = entries.filter { $0.value.touchedAt >= cutoff }
    }

    // MARK: - process tree walk

    /// Public ancestry probe so `ShellDiscovery` can reuse the same logic.
    func isDescendantOf(pid: pid_t, ancestor: pid_t) -> Bool {
        isDescendant(pid: pid, ancestor: ancestor)
    }

    private func isDescendant(pid: pid_t, ancestor: pid_t) -> Bool {
        if pid == ancestor { return true }
        var current = pid
        for _ in 0..<32 {           // bounded walk; should never realistically exceed this
            let parent = parentPID(of: current)
            if parent <= 1 { return false }
            if parent == ancestor { return true }
            current = parent
        }
        return false
    }

    /// `sysctl(KERN_PROC_PID)` reports the parent correctly even for session
    /// leaders like `login`, which `proc_pidinfo(PROC_PIDTBSDINFO)` reports
    /// as having ppid=0. This matters because Ghostty spawns shells via
    /// `login`, so the shell's grandparent is the terminal.
    private func parentPID(of pid: pid_t) -> pid_t {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var size = 0
        if sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) != 0 { return 0 }
        var info = kinfo_proc()
        size = MemoryLayout<kinfo_proc>.stride
        if sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) != 0 { return 0 }
        return info.kp_eproc.e_ppid
    }
}
