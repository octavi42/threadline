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
        let terminal = TerminalIdentityResolver.resolve(shellPid: pid, cwd: cwd, tty: normalizedTTY)
        lock.lock(); defer { lock.unlock() }
        entries[pid] = Entry(pid: pid,
                             cwd: cwd,
                             tty: normalizedTTY,
                             terminal: terminal,
                             touchedAt: touchedAt)
        prune()
        savePersisted()
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

    func scope(terminal: TerminalIdentity) -> Scope? {
        lock.lock(); defer { lock.unlock() }
        prune()
        let sorted = entries.values.sorted { $0.touchedAt > $1.touchedAt }
        if let surfaceID = terminal.surfaceID,
           let match = sorted.first(where: { $0.terminal?.surfaceID == surfaceID }) {
            return Scope(shellPid: match.pid,
                         cwd: match.cwd,
                         tty: match.tty,
                         terminal: match.terminal)
        }
        if let tty = TerminalIdentityResolver.normalizeTTY(terminal.tty),
           let match = sorted.first(where: { TerminalIdentityResolver.normalizeTTY($0.tty) == tty }) {
            return Scope(shellPid: match.pid,
                         cwd: match.cwd,
                         tty: match.tty,
                         terminal: match.terminal)
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

    /// Direct lookup for a shell PID that has reported via the prompt hook.
    func shell(forShellPid pid: pid_t) -> Scope? {
        lock.lock(); defer { lock.unlock() }
        prune()
        guard let entry = entries[pid] else { return nil }
        return Scope(shellPid: entry.pid,
                     cwd: entry.cwd,
                     tty: entry.tty,
                     terminal: entry.terminal)
    }

    /// Most recent terminal identity recorded for an exact TTY match.
    func terminalIdentity(matchingTTY tty: String?) -> TerminalIdentity? {
        guard let want = TerminalIdentityResolver.normalizeTTY(tty) else { return nil }
        lock.lock(); defer { lock.unlock() }
        prune()
        let sorted = entries.values.sorted { $0.touchedAt > $1.touchedAt }
        for entry in sorted {
            if TerminalIdentityResolver.normalizeTTY(entry.tty) == want {
                return entry.terminal
            }
            if TerminalIdentityResolver.normalizeTTY(entry.terminal?.tty) == want {
                return entry.terminal
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
            let terminal = terminalIdentity(from: item)
            entries[pid] = Entry(pid: pid,
                                 cwd: cwd,
                                 tty: item["tty"] as? String,
                                 terminal: terminal,
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
            if let terminal = entry.terminal {
                item["terminal_bundle_id"] = terminal.bundleID
                item["terminal_app_pid"] = Int(terminal.appPID)
                if let tty = terminal.tty { item["terminal_tty"] = tty }
                if let cwd = terminal.cwd { item["terminal_cwd"] = cwd }
                if let surfaceID = terminal.surfaceID { item["terminal_surface_id"] = surfaceID }
                if let windowID = terminal.windowID { item["terminal_window_id"] = windowID }
                if let tabID = terminal.tabID { item["terminal_tab_id"] = tabID }
            }
            return item
        }
        guard let data = try? JSONSerialization.data(withJSONObject: arr, options: []) else {
            return
        }
        try? data.write(to: URL(fileURLWithPath: storePath), options: .atomic)
    }

    private func terminalIdentity(from item: [String: Any]) -> TerminalIdentity? {
        guard let bundleID = item["terminal_bundle_id"] as? String,
              let appPIDNum = item["terminal_app_pid"] as? Int
        else { return nil }
        return TerminalIdentity(bundleID: bundleID,
                                appPID: pid_t(appPIDNum),
                                tty: item["terminal_tty"] as? String,
                                cwd: item["terminal_cwd"] as? String,
                                surfaceID: item["terminal_surface_id"] as? String,
                                windowID: item["terminal_window_id"] as? String,
                                tabID: item["terminal_tab_id"] as? String)
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
