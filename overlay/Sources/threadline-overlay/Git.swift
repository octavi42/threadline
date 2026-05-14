import Foundation

/// Cached branch + dirty-file count probe. Spawns `git` at most once per cwd
/// per TTL window, so polling at 15Hz doesn't fork-bomb.
enum Git {
    struct Info: Equatable {
        let branch: String?
        let dirty: Int
    }

    private struct CacheEntry {
        let info: Info
        let at: Date
    }

    private static let ttl: TimeInterval = 4
    private static var cache: [String: CacheEntry] = [:]
    private static let lock = NSLock()

    static func info(cwd: String) -> Info? {
        lock.lock()
        if let hit = cache[cwd], Date().timeIntervalSince(hit.at) < ttl {
            lock.unlock()
            return hit.info
        }
        lock.unlock()

        let info = probe(cwd: cwd)
        lock.lock()
        if let i = info { cache[cwd] = CacheEntry(info: i, at: Date()) }
        lock.unlock()
        return info
    }

    private static func probe(cwd: String) -> Info? {
        guard FileManager.default.fileExists(atPath: cwd) else { return nil }
        let branch = runGit(["-C", cwd, "branch", "--show-current"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let b = branch, !b.isEmpty else { return nil }
        let status = runGit(["-C", cwd, "status", "--porcelain"]) ?? ""
        let dirty = status.split(separator: "\n").count
        return Info(branch: b, dirty: dirty)
    }

    private static func runGit(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
