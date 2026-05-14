import Foundation
import Combine

struct SourceSnapshot: Identifiable, Equatable {
    let id: String          // tool name, used as identifier
    let tool: String        // "Claude", "Codex", "Cursor"
    var cwd: String?
    var model: String?
    var lastRole: String?   // "assistant" | "user"
    var lastText: String?
    var updatedAt: Date?
    var status: String?     // "ok" | "stale" | "no session" | "error: ..."

    var summaryLine: String {
        if let s = status, s != "ok" { return s }
        let head = lastRole.map { "[\($0)] " } ?? ""
        let body = (lastText ?? "—").replacingOccurrences(of: "\n", with: " ")
        return head + body
    }

    var subtitleLine: String {
        var parts: [String] = []
        if let cwd = cwd {
            parts.append((cwd as NSString).abbreviatingWithTildeInPath)
        }
        if let m = model { parts.append(m) }
        if let t = updatedAt {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .short
            parts.append(f.localizedString(for: t, relativeTo: Date()))
        }
        return parts.joined(separator: " · ")
    }
}

final class SessionModel: ObservableObject {
    @Published var snapshots: [SourceSnapshot] = []
    private var timer: Timer?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        let claude = ClaudeSource.read()
        let codex = CodexSource.read()
        let cursor = CursorSource.read()
        let next = [claude, codex, cursor]
        DispatchQueue.main.async { [weak self] in
            self?.snapshots = next
        }
    }
}
