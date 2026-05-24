import Foundation

enum SnapshotDiskCache {
    private struct Payload: Codable {
        let version: Int
        let writtenAt: Date
        let selectedID: String?
        let snapshots: [SourceSnapshot]
    }

    struct Loaded {
        let selectedID: String?
        let snapshots: [SourceSnapshot]
    }

    private static let version = 1

    private static var cacheURL: URL {
        if let stateDir = ProcessInfo.processInfo.environment["THREADLINE_OVERLAY_STATE_DIR"],
           !stateDir.isEmpty {
            return URL(fileURLWithPath: stateDir, isDirectory: true)
                .appendingPathComponent("cache", isDirectory: true)
                .appendingPathComponent("overlay-snapshots.json")
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".threadline", isDirectory: true)
            .appendingPathComponent("cache", isDirectory: true)
        return dir.appendingPathComponent("overlay-snapshots.json")
    }

    static func load(maxAge: TimeInterval = 7 * 24 * 3600) -> Loaded? {
        let url = cacheURL
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            guard payload.version == version else { return nil }
            guard Date().timeIntervalSince(payload.writtenAt) <= maxAge else { return nil }
            let snapshots = payload.snapshots
                .map(restoredSnapshot)
                .sorted(by: WorkStatusResolver.sort)
            guard !snapshots.isEmpty else { return nil }
            OverlayLog.write("snapshot cache load count=\(snapshots.count)")
            return Loaded(selectedID: payload.selectedID, snapshots: snapshots)
        } catch {
            OverlayLog.write("snapshot cache load failed \(error)")
            return nil
        }
    }

    static func save(snapshots: [SourceSnapshot], selectedID: String?) {
        guard !snapshots.isEmpty else { return }
        let url = cacheURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let payload = Payload(version: version,
                                  writtenAt: Date(),
                                  selectedID: selectedID,
                                  snapshots: snapshots.sorted(by: WorkStatusResolver.sort))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(payload)
            try data.write(to: url, options: [.atomic])
            OverlayLog.write("snapshot cache save count=\(snapshots.count)")
        } catch {
            OverlayLog.write("snapshot cache save failed \(error)")
        }
    }

    static func restoredSnapshot(_ stored: SourceSnapshot) -> SourceSnapshot {
        var snap = stored
        snap.livePid = nil
        snap.tty = nil
        snap.terminalBundleID = nil
        snap.terminalPID = nil
        snap.terminalSurfaceID = nil
        snap.terminalWindowID = nil
        snap.terminalTabID = nil
        if snap.state == .running {
            snap.state = .idle
        }
        if snap.workState.status == .working {
            snap.workState = WorkState(status: .done,
                                       reason: "Previously active; refreshing.",
                                       nextAction: "Refresh",
                                       rank: 6)
        }
        return SourceSnapshot.withStructuralDerivedFields(snap)
    }
}
