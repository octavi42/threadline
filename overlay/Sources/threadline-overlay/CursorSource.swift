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

    static func read(scopeCwd: String? = nil) -> SourceSnapshot {
        var snap = SourceSnapshot(id: "cursor", tool: "Cursor", badge: "CUR")
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: basePath) else {
            snap.state = .none; snap.note = "no session"
            return snap
        }

        struct Candidate { let dir: String; let mtime: Date; let folder: String? }
        var all: [Candidate] = []
        for e in entries {
            let db = (basePath as NSString)
                .appendingPathComponent(e)
                .appending("/state.vscdb")
            guard let m = (try? fm.attributesOfItem(atPath: db))?[.modificationDate] as? Date else { continue }
            let wsJson = (basePath as NSString)
                .appendingPathComponent(e)
                .appending("/workspace.json")
            var folder: String?
            if let data = try? Data(contentsOf: URL(fileURLWithPath: wsJson)),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let raw = obj["folder"] as? String {
                folder = raw.replacingOccurrences(of: "file://", with: "")
                            .removingPercentEncoding ?? raw
            }
            all.append(Candidate(dir: e, mtime: m, folder: folder))
        }
        all.sort { $0.mtime > $1.mtime }

        // Scoped pick first, fall back to global newest.
        let pick: Candidate?
        if let scope = scopeCwd, !scope.isEmpty {
            pick = all.first { c in
                guard let f = c.folder else { return false }
                return f == scope || f.hasPrefix(scope + "/") || scope.hasPrefix(f + "/")
            } ?? all.first
        } else {
            pick = all.first
        }
        guard let chosen = pick else {
            snap.state = .none; snap.note = "no session"
            return snap
        }
        snap.updatedAt = chosen.mtime
        snap.cwd = chosen.folder
        snap.lastText = "workspace active"

        let ageSec = -chosen.mtime.timeIntervalSinceNow
        snap.state = ageSec > 300 ? .stale : .idle

        if let c = snap.cwd, let info = Git.info(cwd: c) {
            snap.branch = info.branch
            snap.dirtyCount = info.dirty
        }
        return snap
    }
}
