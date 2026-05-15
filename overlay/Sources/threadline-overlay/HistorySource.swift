import Foundation

/// Surfaces terminated agent sessions from the Python history store
/// (~/.local/state/threadline/snapshots/index.json) so the overlay can
/// show "what changed in past sessions" alongside live ones.
///
/// Only sessions whose snapshot_count >= 1 are returned — sessions that
/// were only registered (metadata, no file snapshots) are noise here.
enum HistorySource {
    private static var indexPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.local/state/threadline/snapshots/index.json"
    }

    /// Read history entries newer than `cutoff` whose session has at least
    /// one file snapshot. `liveIDs` is used to suppress sessions that are
    /// already surfaced by the live readers (Claude/Codex/Cursor).
    static func readAll(since cutoff: Date, excluding liveIDs: Set<String>) -> [SourceSnapshot] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: indexPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: indexPath)),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()

        var out: [SourceSnapshot] = []
        for entry in arr {
            guard let id = entry["id"] as? String, !liveIDs.contains(id) else { continue }
            let snapshotCount = (entry["snapshot_count"] as? Int) ?? 0
            guard snapshotCount >= 1 else { continue }

            let updated = (entry["updated_at"] as? String).flatMap { s in
                iso.date(from: s) ?? isoNoFrac.date(from: s)
            }
            guard let ts = updated, ts >= cutoff else { continue }

            let agent = (entry["agent"] as? String) ?? "?"
            var snap = SourceSnapshot(id: id, tool: "History", badge: agentBadge(agent))
            snap.cwd = entry["cwd"] as? String
            snap.updatedAt = ts
            snap.state = .stale  // terminated by definition
            snap.lastText = entry["first_prompt"] as? String
            snap.note = "history · \(snapshotCount) snapshot\(snapshotCount == 1 ? "" : "s")"
            out.append(snap)
        }
        return out
    }

    private static func agentBadge(_ agent: String) -> String {
        switch agent {
        case "claude": return "HCD"
        case "codex":  return "HCX"
        case "cursor": return "HCU"
        default:       return "HIS"
        }
    }
}
