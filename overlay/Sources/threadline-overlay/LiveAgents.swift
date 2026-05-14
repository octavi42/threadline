import AppKit
import Darwin
import Foundation

/// Detects which AI sessions are currently *open* (process is alive) by
/// walking the running-process table and matching their cwds back to the
/// SourceSnapshot IDs we generate.
enum LiveAgents {
    /// Snapshot IDs (e.g. `claude:-Users-foo-bar`, `codex:/Users/foo/bar`) of
    /// sessions whose underlying tool process is currently running.
    static func openSnapshotIDs() -> Set<String> {
        var ids: Set<String> = []
        for info in ProcTable.all() {
            let pid = info.kp_proc.p_pid
            let comm = ProcTable.commName(info)
            let prefix: String
            let encodeCwd: (String) -> String
            switch comm {
            case "claude", "claude.exe":
                prefix = "claude:"
                encodeCwd = { $0.replacingOccurrences(of: "/", with: "-") }
            case "codex":
                prefix = "codex:"
                encodeCwd = { $0 }
            default:
                continue
            }
            guard let cwd = procCwd(pid: pid) else { continue }
            ids.insert(prefix + encodeCwd(cwd))
        }
        return ids
    }

    /// Whether the Cursor IDE itself is running. Cursor doesn't fork per
    /// workspace, so process-matching by cwd doesn't work — we just gate on
    /// the app being alive.
    static var cursorRunning: Bool {
        let cursorBundleIDs: Set<String> = [
            "com.todesktop.230313mzl4w4u92",
            "com.todesktop.230313mzl4w4u92-insider",
        ]
        return NSWorkspace.shared.runningApplications
            .contains { app in app.bundleIdentifier.map(cursorBundleIDs.contains) ?? false }
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
