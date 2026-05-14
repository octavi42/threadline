import Darwin
import Foundation

/// Passive fallback for `ShellRegistry`: when no touch has been received yet
/// for the focused terminal (e.g. shell hook not yet sourced, or daemon
/// restarted mid-session), enumerate the terminal's descendant shells via
/// `sysctl(KERN_PROC_ALL)` and identify any whose TTY foreground process is
/// `claude` or `codex`. Cached briefly so we don't scan the proc table 15× a
/// second.
enum ShellDiscovery {
    struct Match {
        let shellPid: pid_t
        let cwd: String
        let activeTool: String   // "Claude" | "Codex"
        let ttyMtime: Date       // most recent activity on the shell's tty
    }

    private static var cacheKey: pid_t = 0
    private static var cacheAt: Date = .distantPast
    private static var cacheResults: [Match] = []
    private static let lock = NSLock()
    private static let ttl: TimeInterval = 2.0

    /// Returns shells under `terminalPid` whose foreground is an AI tool.
    static func activeMatches(under terminalPid: pid_t) -> [Match] {
        lock.lock()
        if cacheKey == terminalPid, Date().timeIntervalSince(cacheAt) < ttl {
            let r = cacheResults
            lock.unlock()
            return r
        }
        lock.unlock()
        let r = scan(under: terminalPid)
        lock.lock()
        cacheKey = terminalPid
        cacheAt = Date()
        cacheResults = r
        lock.unlock()
        return r
    }

    // MARK: - scan

    private static func scan(under terminalPid: pid_t) -> [Match] {
        let shellNames: Set<String> = ["bash", "zsh", "fish", "-bash", "-zsh", "-fish"]
        var matches: [Match] = []
        for info in ProcTable.all() {
            let pid = info.kp_proc.p_pid
            let comm = ProcTable.commName(info)
            guard shellNames.contains(comm) else { continue }
            guard ShellRegistry.shared.isDescendantOf(pid: pid, ancestor: terminalPid) else { continue }
            guard let tool = ForegroundProcess.toolName(shellPid: pid) else { continue }
            guard let cwd = procCwd(pid: pid) else { continue }
            let mtime = ttyMtime(of: info) ?? Date(timeIntervalSince1970: 0)
            matches.append(Match(shellPid: pid, cwd: cwd, activeTool: tool, ttyMtime: mtime))
        }
        // Most recently-active TTY first → that's the focused tab in the
        // common case (output / input keeps the device's mtime fresh).
        matches.sort { $0.ttyMtime > $1.ttyMtime }
        return matches
    }

    private static func ttyMtime(of info: kinfo_proc) -> Date? {
        let dev = info.kp_eproc.e_tdev
        guard dev != -1 else { return nil }
        guard let cstr = devname(dev, mode_t(S_IFCHR)) else { return nil }
        let path = "/dev/" + String(cString: cstr)
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private static func procCwd(pid: pid_t) -> String? {
        var vpi = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.stride
        let r = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, Int32(size))
        guard r > 0 else { return nil }
        let cwd = withUnsafePointer(to: &vpi.pvi_cdir.vip_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
        return cwd.isEmpty ? nil : cwd
    }
}
