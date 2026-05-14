import Foundation

/// Cursor stores its chats across a workspace-keyed SQLite DB (state.vscdb) and a
/// global cursorDiskKV with bubble/composer rows. Parsing those into a usable
/// "last message" requires traversing internal references; v0 keeps it light:
/// we surface the most recently active workspace folder and when it was touched.
enum CursorSource {
    private static var basePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Cursor/User/workspaceStorage"
    }

    static func read() -> SourceSnapshot {
        var snap = SourceSnapshot(id: "cursor", tool: "Cursor", badge: "CUR")
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: basePath) else {
            snap.state = .none; snap.note = "no session"
            return snap
        }

        var best: (dir: String, mtime: Date)?
        for e in entries {
            let db = (basePath as NSString)
                .appendingPathComponent(e)
                .appending("/state.vscdb")
            if let m = (try? fm.attributesOfItem(atPath: db))?[.modificationDate] as? Date {
                if best == nil || m > best!.mtime { best = (e, m) }
            }
        }
        guard let pick = best else {
            snap.state = .none; snap.note = "no session"
            return snap
        }
        snap.updatedAt = pick.mtime

        let wsJson = (basePath as NSString)
            .appendingPathComponent(pick.dir)
            .appending("/workspace.json")
        if let data = try? Data(contentsOf: URL(fileURLWithPath: wsJson)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let folder = obj["folder"] as? String {
            snap.cwd = folder
                .replacingOccurrences(of: "file://", with: "")
                .removingPercentEncoding ?? folder
        }
        snap.lastText = "workspace active"

        let ageSec = -pick.mtime.timeIntervalSinceNow
        snap.state = ageSec > 300 ? .stale : .idle

        if let c = snap.cwd, let info = Git.info(cwd: c) {
            snap.branch = info.branch
            snap.dirtyCount = info.dirty
        }
        return snap
    }
}
