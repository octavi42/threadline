import AppKit
import Darwin
import Foundation

/// One open AI tab — a (tool, pid, JSONL) tuple.
struct LiveSession: Hashable {
    let tool: String       // "Claude" | "Codex" | "Cursor"
    let pid: pid_t
    let jsonlPath: String
}

/// Per-tab discovery of active Claude / Codex / Cursor Agent sessions.
///
/// Codex keeps its session JSONL open for append, so we read its fd table
/// directly. Claude closes the fd between turns, so we instead match each
/// `claude.exe` process's `p_starttime` to the JSONL in its project
/// directory whose on-disk birth time is closest — within ±15 minutes.
/// Matching is greedy and injective (each JSONL maps to one PID).
enum LiveAgents {
    static func liveSessions() -> [LiveSession] {
        var sessions: [LiveSession] = []
        var usedPaths: Set<String> = []

        struct AgentProc { let pid: pid_t; let started: Date }
        var claudeByCwd: [String: [AgentProc]] = [:]

        for info in ProcTable.all() {
            let pid = info.kp_proc.p_pid
            let comm = ProcTable.commName(info)
            switch comm {
            case "claude", "claude.exe":
                if isNonInteractiveHelper(pid: pid, comm: comm) { continue }
                guard let cwd = procCwd(pid: pid) else { continue }
                claudeByCwd[cwd, default: []].append(
                    AgentProc(pid: pid, started: startTime(info: info))
                )
            case "codex":
                if isNonInteractiveHelper(pid: pid, comm: comm) { continue }
                let paths = openJSONLPaths(pid: pid)
                    .filter { $0.contains("/.codex/sessions/") }
                if let path = preferredCodexJSONLPath(from: paths),
                   !usedPaths.contains(path) {
                    sessions.append(LiveSession(tool: "Codex", pid: pid, jsonlPath: path))
                    usedPaths.insert(path)
                }
            case "node", "cursor-agent":
                if isNonInteractiveHelper(pid: pid, comm: comm) { continue }
                if let path = resolveCursorJSONL(pid: pid),
                   !usedPaths.contains(path),
                   CursorAgentSource.snapshot(forJSONL: path) != nil {
                    sessions.append(LiveSession(tool: "Cursor", pid: pid, jsonlPath: path))
                    usedPaths.insert(path)
                }
            default:
                continue
            }
        }

        // Pair each Claude PID with the JSONL whose birth time is closest.
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        for (cwd, procs) in claudeByCwd {
            let encoded = cwd.replacingOccurrences(of: "/", with: "-")
            let dir = "\(home)/.claude/projects/\(encoded)"
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            var available: [(path: String, birth: Date)] = []
            for f in files where f.hasSuffix(".jsonl") {
                let p = (dir as NSString).appendingPathComponent(f)
                if let attrs = try? fm.attributesOfItem(atPath: p),
                   let birth = attrs[.creationDate] as? Date {
                    available.append((p, birth))
                }
            }
            // Greedy match newest process first.
            for proc in procs.sorted(by: { $0.started > $1.started }) {
                let remaining = available.filter { !usedPaths.contains($0.path) }
                guard let pick = remaining.min(by: {
                    abs($0.birth.timeIntervalSince(proc.started)) <
                    abs($1.birth.timeIntervalSince(proc.started))
                }) else { continue }
                if abs(pick.birth.timeIntervalSince(proc.started)) <= 15 * 60 {
                    sessions.append(LiveSession(tool: "Claude",
                                                pid: proc.pid,
                                                jsonlPath: pick.path))
                    usedPaths.insert(pick.path)
                }
            }
        }

        return sessions
    }

    /// `/clear` may leave the previous Codex rollout fd open on the same PID.
    /// Only the newest rollout represents the conversation still active in the tab.
    static func preferredCodexJSONLPath(
        from paths: [String],
        createdAt: (String) -> Date? = codexSessionCreationDate
    ) -> String? {
        let uniquePaths = Set(paths)
        let dated = uniquePaths.compactMap { path -> (path: String, date: Date)? in
            guard let date = createdAt(path) else { return nil }
            return (path, date)
        }
        if let newest = dated.max(by: {
            if $0.date == $1.date { return $0.path < $1.path }
            return $0.date < $1.date
        }) {
            return newest.path
        }
        return uniquePaths.max()
    }

    /// The overlay can spawn CLI helpers to summarize sessions. Those helpers
    /// are not interactive agent tabs and must not be surfaced as live rows.
    private static func isNonInteractiveHelper(pid: pid_t, comm: String) -> Bool {
        let args = ProcTable.arguments(pid: pid)
        if args.isEmpty { return false }

        switch comm {
        case "claude", "claude.exe":
            return args.contains("-p")
                || args.contains("--print")
                || args.contains("--no-session-persistence")
        case "codex":
            return args.contains("exec")
        case "node", "cursor-agent":
            return !isCursorAgentProcess(args: args, comm: comm)
        default:
            return false
        }
    }

    private static func isCursorAgentProcess(args: [String], comm: String) -> Bool {
        if comm == "cursor-agent" {
            return args.contains("agent")
        }
        guard comm == "node", args.contains("agent") else { return false }
        if args.contains("worker-server") { return false }
        return args.contains { arg in
            arg.contains("cursor-agent/versions") || arg.contains("/.local/bin/cursor-agent")
        }
    }

    private static func resolveCursorJSONL(pid: pid_t) -> String? {
        CursorAgentSource.refreshSessionIndex()
        if let sessionID = openChatSessionID(pid: pid),
           let path = CursorAgentSource.jsonlPath(forSessionID: sessionID) {
            return path
        }
        for path in openJSONLPaths(pid: pid) where path.contains("/agent-transcripts/") {
            return path
        }
        return nil
    }

    private static func openChatSessionID(pid: pid_t) -> String? {
        for path in openFilePaths(pid: pid) where path.contains("/.cursor/chats/") {
            if path.hasSuffix("/store.db") || path.hasSuffix("store.db") {
                return URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
            }
        }
        return nil
    }

    private static func openFilePaths(pid: pid_t) -> [String] {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let probe = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard probe > 0 else { return [] }
        let count = Int(probe) / stride + 32
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let n = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(count * stride))
        guard n > 0 else { return [] }
        var out: [String] = []
        for i in 0..<Int(n) / stride {
            guard fds[i].proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { continue }
            var vi = vnode_fdinfowithpath()
            let r = proc_pidfdinfo(pid, Int32(fds[i].proc_fd),
                                   PROC_PIDFDVNODEPATHINFO,
                                   &vi,
                                   Int32(MemoryLayout<vnode_fdinfowithpath>.stride))
            guard r > 0 else { continue }
            let path = withUnsafePointer(to: &vi.pvip.vip_path) { p in
                p.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                    String(cString: $0)
                }
            }
            if !path.isEmpty { out.append(path) }
        }
        return out
    }

    /// Whether Cursor.app itself is running.
    static var cursorRunning: Bool {
        let cursorBundleIDs: Set<String> = [
            "com.todesktop.230313mzl4w4u92",
            "com.todesktop.230313mzl4w4u92-insider",
        ]
        return NSWorkspace.shared.runningApplications
            .contains { app in app.bundleIdentifier.map(cursorBundleIDs.contains) ?? false }
    }

    // MARK: - process helpers

    private static func startTime(info: kinfo_proc) -> Date {
        let tv = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970:
            TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
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

    private static func openJSONLPaths(pid: pid_t) -> [String] {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let probe = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard probe > 0 else { return [] }
        let count = Int(probe) / stride + 32
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let n = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(count * stride))
        guard n > 0 else { return [] }
        var out: [String] = []
        for i in 0..<Int(n) / stride {
            guard fds[i].proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { continue }
            var vi = vnode_fdinfowithpath()
            let r = proc_pidfdinfo(pid, Int32(fds[i].proc_fd),
                                   PROC_PIDFDVNODEPATHINFO,
                                   &vi,
                                   Int32(MemoryLayout<vnode_fdinfowithpath>.stride))
            guard r > 0 else { continue }
            let path = withUnsafePointer(to: &vi.pvip.vip_path) { p in
                p.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                    String(cString: $0)
                }
            }
            if path.hasSuffix(".jsonl") { out.append(path) }
        }
        return out
    }

    private static func codexSessionCreationDate(_ path: String) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return attributes?[.creationDate] as? Date
    }
}
