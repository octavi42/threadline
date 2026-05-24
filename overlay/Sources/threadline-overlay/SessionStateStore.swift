import Foundation

enum SessionStateStore {
    struct Record: Codable, Equatable {
        let id: String
        let tool: String
        let cwd: String?
        let jsonlPath: String?
        let status: WorkStatus
        let state: SourceState
        let pid: Int?
        let updatedAt: Date?
        let lastText: String?
    }

    private static let maxAge: TimeInterval = 7 * 24 * 3600

    private static var directoryURL: URL {
        if let stateDir = ProcessInfo.processInfo.environment["THREADLINE_OVERLAY_STATE_DIR"],
           !stateDir.isEmpty {
            return URL(fileURLWithPath: stateDir, isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".threadline", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    static func load() -> [SourceSnapshot] {
        let dir = directoryURL
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir,
                                                                      includingPropertiesForKeys: nil)
        else { return [] }

        let now = Date()
        let records = urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Record? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(Record.self, from: data)
            }
            .filter { record in
                guard let updatedAt = record.updatedAt else { return true }
                return now.timeIntervalSince(updatedAt) <= maxAge
            }

        let snapshots = records
            .map(snapshot(from:))
            .filter(WorkStatusResolver.shouldDisplay)
            .sorted(by: WorkStatusResolver.sort)
        if !snapshots.isEmpty {
            OverlayLog.write("session state load count=\(snapshots.count)")
        }
        return snapshots
    }

    static func save(snapshots: [SourceSnapshot]) {
        guard !snapshots.isEmpty else { return }
        let records = snapshots.map(record(from:))
        let dir = directoryURL
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            for record in records {
                let data = try encoder.encode(record)
                try data.write(to: dir.appendingPathComponent(fileName(for: record.id)),
                               options: [.atomic])
            }
            prune(validIDs: Set(records.map(\.id)), in: dir)
            OverlayLog.write("session state save count=\(records.count)")
        } catch {
            OverlayLog.write("session state save failed \(error)")
        }
    }

    static func record(from snap: SourceSnapshot) -> Record {
        Record(id: snap.id,
               tool: snap.tool,
               cwd: snap.cwd,
               jsonlPath: snap.jsonlPath,
               status: snap.workState.status,
               state: snap.state,
               pid: nil,
               updatedAt: snap.updatedAt,
               lastText: snap.currentTask ?? snap.lastText ?? snap.note)
    }

    static func snapshot(from record: Record) -> SourceSnapshot {
        // Process identity and a running turn are only true in the daemon
        // instance that observed them. The live scan will restore either.
        let restoredState: SourceState = record.state == .running ? .idle : record.state
        var snap = SourceSnapshot(
            id: record.id,
            tool: record.tool,
            badge: badge(for: record.tool),
            state: restoredState,
            cwd: record.cwd,
            currentTask: record.lastText,
            lastText: record.lastText,
            updatedAt: record.updatedAt,
            jsonlPath: record.jsonlPath,
            livePid: nil,
            workState: workState(for: record, restoredState: restoredState)
        )
        snap.note = "Loaded from last known session state."
        return SourceSnapshot.withStructuralDerivedFields(snap)
    }

    private static func workState(for record: Record, restoredState: SourceState) -> WorkState {
        switch record.status {
        case .needsYou:
            return WorkState(status: .needsYou,
                             reason: "Last known state needs attention.",
                             nextAction: "Open the session.",
                             rank: 0)
        case .testsFailed:
            return WorkState(status: .testsFailed,
                             reason: "Last known state had failing tests.",
                             nextAction: "Review the session.",
                             rank: 1)
        case .stuck:
            return WorkState(status: .stuck,
                             reason: "Last known state was stuck.",
                             nextAction: "Inspect the transcript.",
                             rank: 2)
        case .risky:
            return WorkState(status: .risky,
                             reason: "Last known state had unresolved changes.",
                             nextAction: "Review before continuing.",
                             rank: 3)
        case .ready:
            return WorkState(status: .ready,
                             reason: "Last known state was ready.",
                             nextAction: "Review or commit.",
                             rank: 4)
        case .working:
            return WorkState(status: .done,
                             reason: restoredState == .idle
                                 ? "Previously active; refreshing."
                                 : "Last known state was active.",
                             nextAction: "Refresh",
                             rank: 6)
        case .done:
            return WorkState(status: .done,
                             reason: "Last known state was complete.",
                             nextAction: "No action needed.",
                             rank: 6)
        }
    }

    private static func badge(for tool: String) -> String {
        switch tool {
        case "Claude": return "CLD"
        case "Codex": return "CDX"
        case "Cursor": return "CUR"
        default: return String(tool.prefix(3)).uppercased()
        }
    }

    private static func prune(validIDs: Set<String>, in dir: URL) {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir,
                                                                      includingPropertiesForKeys: nil)
        else { return }
        for url in urls where url.pathExtension == "json" {
            let id = idFromFileName(url.deletingPathExtension().lastPathComponent)
            if !validIDs.contains(id) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func fileName(for id: String) -> String {
        Data(id.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
            + ".json"
    }

    private static func idFromFileName(_ name: String) -> String {
        var base64 = name
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "-", with: "+")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let id = String(data: data, encoding: .utf8)
        else { return name }
        return id
    }
}
