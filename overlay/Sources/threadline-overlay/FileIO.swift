import Foundation

/// Read the last `maxBytes` bytes of a file as UTF-8 (best-effort).
func tailOfFile(path: String, maxBytes: Int) -> String? {
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    let size: UInt64
    do { size = try fh.seekToEnd() } catch { return nil }
    let offset: UInt64 = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
    do { try fh.seek(toOffset: offset) } catch { return nil }
    let data = fh.availableData
    return String(data: data, encoding: .utf8)
}

/// Read the first `maxBytes` bytes of a file as UTF-8 (best-effort).
func headOfFile(path: String, maxBytes: Int) -> String? {
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    let data = fh.readData(ofLength: maxBytes)
    return String(data: data, encoding: .utf8)
}
