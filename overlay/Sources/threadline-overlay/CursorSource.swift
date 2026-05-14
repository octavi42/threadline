import Foundation

/// One snapshot per Cursor workspace whose `state.vscdb` is newer than `since`.
enum CursorSource {
    private static var basePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Cursor/User/workspaceStorage"
    }

    static func readAll(since cutoff: Date) -> [SourceSnapshot] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: basePath) else { return [] }

        var out: [SourceSnapshot] = []
        for entry in entries {
            let dbPath = (basePath as NSString)
                .appendingPathComponent(entry)
                .appending("/state.vscdb")
            guard let m = (try? fm.attributesOfItem(atPath: dbPath))?[.modificationDate] as? Date,
                  m >= cutoff
            else { continue }
            let wsJson = (basePath as NSString)
                .appendingPathComponent(entry)
                .appending("/workspace.json")
            var folder: String?
            if let data = try? Data(contentsOf: URL(fileURLWithPath: wsJson)),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let raw = obj["folder"] as? String {
                folder = raw.replacingOccurrences(of: "file://", with: "")
                            .removingPercentEncoding ?? raw
            }
            let id = "cursor:\(folder ?? entry)"
            var snap = SourceSnapshot(id: id, tool: "Cursor", badge: "CUR")
            snap.cwd = folder
            snap.updatedAt = m
            snap.lastText = "workspace active"
            let ageSec = -m.timeIntervalSinceNow
            snap.state = ageSec > 300 ? .stale : .idle
            if let c = folder, let info = Git.info(cwd: c) {
                snap.branch = info.branch
                snap.dirtyCount = info.dirty
            }
            out.append(snap)
        }
        return out
    }
}
