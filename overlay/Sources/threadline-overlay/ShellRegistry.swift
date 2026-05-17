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
        let tty: String?
        let terminal: TerminalIdentity?
        let touchedAt: Date
    }

    private var entries: [pid_t: Entry] = [:]
    private let lock = NSLock()

    /// Entries older than this are pruned on each operation.
    private let ttl: TimeInterval = 30 * 60

    private var storePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.threadline/shells.json"
    }

    private init() {
        loadPersisted()
    }

    func touch(pid: pid_t, cwd: String, tty: String? = nil) {
        let normalizedTTY = TerminalIdentityResolver.normalizeTTY(tty)
        let touchedAt = Date()
        lock.lock(); defer { lock.unlock() }
        entries[pid] = Entry(pid: pid,
                             cwd: cwd,
                             tty: normalizedTTY,
                             terminal: nil,
                             touchedAt: touchedAt)
        prune()
        savePersisted()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let terminal = TerminalIdentityResolver.resolve(shellPid: pid, cwd: cwd, tty: normalizedTTY)
            self?.updateTerminal(pid: pid, touchedAt: touchedAt, terminal: terminal)
        }
    }

    struct Scope {
        let shellPid: pid_t
        let cwd: String
        let tty: String?
        let terminal: TerminalIdentity?
    }

    /// The most recently-active shell descended from `terminalPid`.
    /// Returns nil if no live touch matches.
    func scope(terminalPid: pid_t) -> Scope? {
        lock.lock(); defer { lock.unlock() }
        prune()
        let sorted = entries.values.sorted { $0.touchedAt > $1.touchedAt }
        for entry in sorted {
            if isDescendant(pid: entry.pid, ancestor: terminalPid) {
                return Scope(shellPid: entry.pid,
                             cwd: entry.cwd,
                             tty: entry.tty,
                             terminal: entry.terminal)
            }
        }
        return nil
    }

    /// The most recent registered shell that is an ancestor of `pid`.
    /// For an agent process, this usually resolves to the shell prompt that
    /// launched it, giving us the TTY needed for exact tab focusing.
    func shell(forDescendant pid: pid_t) -> Scope? {
        lock.lock(); defer { lock.unlock() }
        prune()
        let sorted = entries.values.sorted { $0.touchedAt > $1.touchedAt }
        for entry in sorted {
            if isDescendant(pid: pid, ancestor: entry.pid) {
                return Scope(shellPid: entry.pid,
                             cwd: entry.cwd,
                             tty: entry.tty,
                             terminal: entry.terminal)
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

    private func updateTerminal(pid: pid_t, touchedAt: Date, terminal: TerminalIdentity?) {
        lock.lock(); defer { lock.unlock() }
        guard let existing = entries[pid],
              existing.touchedAt == touchedAt
        else { return }
        entries[pid] = Entry(pid: existing.pid,
                             cwd: existing.cwd,
                             tty: existing.tty,
                             terminal: terminal,
                             touchedAt: existing.touchedAt)
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-ttl)
        entries = entries.filter { $0.value.touchedAt >= cutoff }
    }

    private func loadPersisted() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: storePath)),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return }
        let cutoff = Date().addingTimeInterval(-ttl)
        for item in arr {
            guard let pidNum = item["pid"] as? Int,
                  let cwd = item["cwd"] as? String,
                  let touchedAtSec = item["touched_at"] as? Double
            else { continue }
            let touchedAt = Date(timeIntervalSince1970: touchedAtSec)
            guard touchedAt >= cutoff else { continue }
            let pid = pid_t(pidNum)
            entries[pid] = Entry(pid: pid,
                                 cwd: cwd,
                                 tty: item["tty"] as? String,
                                 terminal: nil,
                                 touchedAt: touchedAt)
        }
    }

    private func savePersisted() {
        let dir = (storePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
        let arr = entries.values.map { entry -> [String: Any] in
            var item: [String: Any] = [
                "pid": Int(entry.pid),
                "cwd": entry.cwd,
                "touched_at": entry.touchedAt.timeIntervalSince1970,
            ]
            if let tty = entry.tty { item["tty"] = tty }
            return item
        }
        guard let data = try? JSONSerialization.data(withJSONObject: arr, options: []) else {
            return
        }
        try? data.write(to: URL(fileURLWithPath: storePath), options: .atomic)
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
