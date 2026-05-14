import AppKit
import Foundation

/// Resolves a terminal app's current background color by reading its config
/// file. Permission-free — no AppleScript automation, no Screen Recording.
/// Cached by file mtime so we re-parse only on change.
enum TerminalTheme {
    private struct CacheEntry {
        let color: NSColor
        let mtime: Date
        let path: String
    }

    private static var cache: [String: CacheEntry] = [:]
    private static let queue = DispatchQueue(label: "threadline.theme")

    /// Default background when the terminal can't be probed (fallback dark).
    static let fallback = NSColor(srgbRed: 0.06, green: 0.06, blue: 0.07, alpha: 1.0)

    static func backgroundColor(for bundleID: String) -> NSColor {
        switch bundleID {
        case "com.mitchellh.ghostty":
            return cached(bundleID, path: ghosttyConfigPath(),
                          parse: parseGhostty) ?? fallback
        case "io.alacritty", "org.alacritty":
            return cached(bundleID, path: alacrittyConfigPath(),
                          parse: parseAlacritty) ?? fallback
        case "net.kovidgoyal.kitty":
            return cached(bundleID, path: kittyConfigPath(),
                          parse: parseKitty) ?? fallback
        default:
            return fallback
        }
    }

    // MARK: - cache

    private static func cached(_ key: String,
                               path: String,
                               parse: (String) -> NSColor?) -> NSColor? {
        return queue.sync {
            let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            if let hit = cache[key], hit.path == path, hit.mtime == mtime {
                return hit.color
            }
            guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                  let color = parse(text) else {
                return nil
            }
            cache[key] = CacheEntry(color: color,
                                    mtime: mtime ?? Date(),
                                    path: path)
            return color
        }
    }

    // MARK: - paths

    private static func ghosttyConfigPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.config/ghostty/config"
    }

    private static func alacrittyConfigPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let toml = "\(home)/.config/alacritty/alacritty.toml"
        if FileManager.default.fileExists(atPath: toml) { return toml }
        return "\(home)/.config/alacritty/alacritty.yml"
    }

    private static func kittyConfigPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.config/kitty/kitty.conf"
    }

    // MARK: - parsers
    //
    // Each parser scans for the LAST occurrence of the relevant key, since
    // most of these configs allow overrides further down.

    /// Ghostty: `background = #010409` or `background = 010409`.
    static func parseGhostty(_ text: String) -> NSColor? {
        var last: NSColor?
        for line in text.split(whereSeparator: { $0 == "\n" }) {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard !s.hasPrefix("#") else { continue }   // comment
            guard let eq = s.firstIndex(of: "=") else { continue }
            let key = s[..<eq].trimmingCharacters(in: .whitespaces)
            guard key == "background" else { continue }
            let value = s[s.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let c = parseColor(value) { last = c }
        }
        return last
    }

    /// Alacritty (TOML): `[colors.primary]` then `background = "#1d1f21"`.
    /// Also handles the older YAML form (`colors:` / `  primary:` / `    background: '0x1d1f21'`).
    static func parseAlacritty(_ text: String) -> NSColor? {
        var inPrimary = false
        var last: NSColor?
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.isEmpty { continue }
            if line.hasPrefix("[") {
                inPrimary = (line == "[colors.primary]")
                continue
            }
            if line.contains("colors.primary") { inPrimary = true; continue }
            // Match `background = "#…"` or `background: "0x…"` style.
            guard line.lowercased().hasPrefix("background") else { continue }
            let splitChar: Character = line.contains("=") ? "=" : ":"
            guard let sep = line.firstIndex(of: splitChar) else { continue }
            let value = line[line.index(after: sep)...]
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            if (inPrimary || splitChar == "="), let c = parseColor(value) {
                last = c
            }
        }
        return last
    }

    /// kitty: `background #1d1f21` or `background 0x1d1f21`.
    static func parseKitty(_ text: String) -> NSColor? {
        var last: NSColor?
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.isEmpty { continue }
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, parts[0] == "background" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if let c = parseColor(value) { last = c }
        }
        return last
    }

    /// Accepts: `#rrggbb`, `rrggbb`, `0xrrggbb`, `#rgb`, `rrggbbaa`.
    static func parseColor(_ raw: String) -> NSColor? {
        var s = raw.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"';,"))
        if s.hasPrefix("#")  { s.removeFirst() }
        if s.hasPrefix("0x") { s.removeFirst(2) }
        let hex = s.unicodeScalars.filter { CharacterSet(charactersIn: "0123456789abcdef").contains($0) }
        guard hex.count == 3 || hex.count == 6 || hex.count == 8 else { return nil }
        let normalized: String
        if hex.count == 3 {
            // expand #abc → #aabbcc
            normalized = hex.map { "\($0)\($0)" }.joined()
        } else {
            normalized = String(String.UnicodeScalarView(hex))
        }
        guard let value = UInt32(normalized, radix: 16) else { return nil }
        let (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat)
        if normalized.count == 8 {
            r = CGFloat((value >> 24) & 0xFF) / 255.0
            g = CGFloat((value >> 16) & 0xFF) / 255.0
            b = CGFloat((value >>  8) & 0xFF) / 255.0
            a = CGFloat( value        & 0xFF) / 255.0
        } else {
            r = CGFloat((value >> 16) & 0xFF) / 255.0
            g = CGFloat((value >>  8) & 0xFF) / 255.0
            b = CGFloat( value        & 0xFF) / 255.0
            a = 1.0
        }
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
