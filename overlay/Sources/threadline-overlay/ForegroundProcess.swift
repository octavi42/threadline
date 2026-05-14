import Darwin
import Foundation

/// Identifies the AI coding tool running under a given shell.
///
/// We walk the shell's process *descendants* (not the foreground process's
/// ancestors), because tools like Codex CLI run as `node → codex` — the
/// foreground command's comm is `node`, but the real tool is a child of it.
/// `claude` is launched directly, so it's found at depth ≤ 2.
enum ForegroundProcess {
    static func toolName(shellPid: pid_t) -> String? {
        let children = ProcTable.childIndex()
        var queue: [pid_t] = [shellPid]
        var seen: Set<pid_t> = []
        while !queue.isEmpty {
            let p = queue.removeFirst()
            if !seen.insert(p).inserted { continue }
            for (childPid, comm) in children[p] ?? [] {
                switch comm {
                case "claude", "claude.exe":  return "Claude"
                case "codex":                 return "Codex"
                default:                      queue.append(childPid)
                }
            }
        }
        return nil
    }
}
