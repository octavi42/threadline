import Foundation

/// Serializes transcript reads and status evidence parsing.
enum JSONLAccess {
    private static let key = DispatchSpecificKey<Bool>()
    private static let queue: DispatchQueue = {
        let q = DispatchQueue(label: "threadline.overlay.jsonl-access", qos: .utility)
        q.setSpecific(key: key, value: true)
        return q
    }()

    static func sync<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: key) == true {
            return try work()
        }
        return try queue.sync(execute: work)
    }
}

enum OverlayLog {
    private static let lock = NSLock()
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(data)
    }
}
