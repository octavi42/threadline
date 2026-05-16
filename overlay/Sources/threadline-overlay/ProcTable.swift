import Darwin
import Foundation

/// Cached snapshot of `sysctl(KERN_PROC_ALL)` shared by ForegroundProcess and
/// ShellDiscovery. TTL is short (1s) so we don't refork into the kernel every
/// 66 ms while still catching new processes promptly.
enum ProcTable {
    private static var cacheAt: Date = .distantPast
    private static var cached: [kinfo_proc] = []
    private static let lock = NSLock()
    private static let ttl: TimeInterval = 1.0

    static func all() -> [kinfo_proc] {
        lock.lock(); defer { lock.unlock() }
        if Date().timeIntervalSince(cacheAt) < ttl, !cached.isEmpty {
            return cached
        }
        cached = fetch() ?? []
        cacheAt = Date()
        return cached
    }

    private static func fetch() -> [kinfo_proc]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        if sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) != 0 { return nil }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: count + 16)
        size = buffer.count * MemoryLayout<kinfo_proc>.stride
        if sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) != 0 { return nil }
        let actual = size / MemoryLayout<kinfo_proc>.stride
        return Array(buffer.prefix(actual))
    }

    static func commName(_ info: kinfo_proc) -> String {
        var i = info
        return withUnsafePointer(to: &i.kp_proc.p_comm) { p in
            p.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN + 1)) {
                String(cString: $0)
            }
        }
    }

    /// `parent -> [(childPid, comm)]` index, built from `all()`.
    static func childIndex() -> [pid_t: [(pid_t, String)]] {
        var idx: [pid_t: [(pid_t, String)]] = [:]
        for info in all() {
            let pid = info.kp_proc.p_pid
            let ppid = pid_t(info.kp_eproc.e_ppid)
            let comm = commName(info)
            idx[ppid, default: []].append((pid, comm))
        }
        return idx
    }

    static func arguments(pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else {
            return []
        }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else {
            return []
        }
        if size < MemoryLayout<Int32>.size { return [] }

        let argc = buffer.withUnsafeBytes { raw -> Int32 in
            raw.load(as: Int32.self)
        }
        if argc <= 0 { return [] }

        var offset = MemoryLayout<Int32>.size
        while offset < size && buffer[offset] != 0 { offset += 1 } // executable path
        while offset < size && buffer[offset] == 0 { offset += 1 }

        var args: [String] = []
        while offset < size && args.count < Int(argc) {
            let start = offset
            while offset < size && buffer[offset] != 0 { offset += 1 }
            if offset > start {
                args.append(String(cString: Array(buffer[start..<offset]) + [0]))
            }
            while offset < size && buffer[offset] == 0 { offset += 1 }
        }
        return args
    }
}
