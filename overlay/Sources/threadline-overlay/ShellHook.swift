import Foundation

/// Manages the shell-prompt hook that pings the daemon with the current cwd
/// on every prompt. Idempotent: append-only to .zshrc / .bashrc, identified
/// by a sentinel marker block.
enum ShellHook {
    static let beginMarker = "# >>> threadline-overlay >>>"
    static let endMarker   = "# <<< threadline-overlay <<<"

    static func snippet(binaryPath: String) -> String {
        """
        \(beginMarker)
        # Pings the threadline daemon on every prompt so the panel knows which
        # tab/cwd is focused. Drop-and-disown so it never slows a prompt down.
        __threadline_touch() {
            "\(binaryPath)" touch --cwd "$PWD" --pid $$ --tty "$(tty 2>/dev/null || true)" >/dev/null 2>&1 &
            disown >/dev/null 2>&1 || true
        }
        if [ -n "${ZSH_VERSION:-}" ]; then
            typeset -ga precmd_functions
            (( ${precmd_functions[(I)__threadline_touch]} )) || precmd_functions+=(__threadline_touch)
        elif [ -n "${BASH_VERSION:-}" ]; then
            case ";${PROMPT_COMMAND:-};" in
                *";__threadline_touch;"*) ;;
                *) PROMPT_COMMAND="__threadline_touch${PROMPT_COMMAND:+; $PROMPT_COMMAND}" ;;
            esac
        fi
        \(endMarker)
        """
    }

    /// Append the marker block to .zshrc and .bashrc if missing.
    /// Returns the list of files that were modified.
    @discardableResult
    static func install(binaryPath: String) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let targets = ["\(home)/.zshrc", "\(home)/.bashrc"]
        var modified: [String] = []
        let block = snippet(binaryPath: binaryPath)
        for path in targets {
            // Read existing contents (or treat missing as empty file).
            let existing: String = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            if existing.contains(beginMarker) {
                // Replace the block in place — handles binary-path updates.
                if let replaced = replaceBlock(in: existing, with: block) {
                    if replaced != existing {
                        try? replaced.write(toFile: path, atomically: true, encoding: .utf8)
                        modified.append(path)
                    }
                }
                continue
            }
            let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
            let next = existing + separator + "\n" + block + "\n"
            do {
                try next.write(toFile: path, atomically: true, encoding: .utf8)
                modified.append(path)
            } catch {
                FileHandle.standardError.write(Data("could not write \(path): \(error)\n".utf8))
            }
        }
        return modified
    }

    /// Strip the marker block from .zshrc / .bashrc.
    @discardableResult
    static func uninstall() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let targets = ["\(home)/.zshrc", "\(home)/.bashrc"]
        var modified: [String] = []
        for path in targets {
            guard let existing = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            if !existing.contains(beginMarker) { continue }
            if let stripped = stripBlock(from: existing) {
                try? stripped.write(toFile: path, atomically: true, encoding: .utf8)
                modified.append(path)
            }
        }
        return modified
    }

    private static func replaceBlock(in text: String, with block: String) -> String? {
        guard let r1 = text.range(of: beginMarker),
              let r2 = text.range(of: endMarker, range: r1.upperBound..<text.endIndex)
        else { return nil }
        var end = r2.upperBound
        if end < text.endIndex, text[end] == "\n" {
            end = text.index(after: end)
        }
        return text.replacingCharacters(in: r1.lowerBound..<end, with: block + "\n")
    }

    private static func stripBlock(from text: String) -> String? {
        guard let r1 = text.range(of: beginMarker),
              let r2 = text.range(of: endMarker, range: r1.upperBound..<text.endIndex)
        else { return nil }
        var end = r2.upperBound
        if end < text.endIndex, text[end] == "\n" {
            end = text.index(after: end)
        }
        var start = r1.lowerBound
        if start > text.startIndex {
            let prev = text.index(before: start)
            if text[prev] == "\n" { start = prev }
        }
        return text.replacingCharacters(in: start..<end, with: "")
    }
}
