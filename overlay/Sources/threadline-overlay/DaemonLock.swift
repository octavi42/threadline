import Darwin
import Foundation

/// Exclusive lock so only one overlay daemon runs. Prevents a launchd instance
/// and a CLI-spawned instance from both registering the global hotkey.
enum DaemonLock {
    private static var fd: Int32 = -1

    static var lockPath: String {
        if let stateDir = ProcessInfo.processInfo.environment["THREADLINE_OVERLAY_STATE_DIR"],
           !stateDir.isEmpty {
            return (stateDir as NSString).appendingPathComponent("overlay.lock")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.threadline/overlay.lock"
    }

    /// Try to become the sole daemon. Returns false if another process holds the lock.
    static func acquire(retryAfterStale: Bool = true) -> Bool {
        IPC.ensureSocketDir()
        let path = lockPath
        let newFD = open(path, O_CREAT | O_RDWR, 0o600)
        guard newFD >= 0 else { return false }
        if flock(newFD, LOCK_EX | LOCK_NB) != 0 {
            close(newFD)
            if retryAfterStale, let holder = holderPID(), holder > 0, kill(holder, 0) != 0 {
                try? FileManager.default.removeItem(atPath: path)
                try? FileManager.default.removeItem(atPath: IPC.socketPath)
                return acquire(retryAfterStale: false)
            }
            return false
        }
        if fd >= 0 { close(fd) }
        fd = newFD
        truncateLockFile()
        return true
    }

    static func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    static func holderPID() -> pid_t? {
        guard let text = try? String(contentsOfFile: lockPath, encoding: .utf8) else {
            return nil
        }
        let line = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
        guard let pid = Int32(line.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0
        else { return nil }
        return pid
    }

    private static func truncateLockFile() {
        guard fd >= 0 else { return }
        let pidLine = "\(getpid())\n"
        _ = ftruncate(fd, 0)
        lseek(fd, 0, SEEK_SET)
        pidLine.withCString { ptr in
            _ = write(fd, ptr, strlen(ptr))
        }
    }
}
