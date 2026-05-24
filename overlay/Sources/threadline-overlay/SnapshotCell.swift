import Foundation
import Observation

/// Per-session observable cell — sidebar/detail rows observe this, not the whole store.
@Observable
final class SnapshotCell {
    let id: String
    private(set) var snapshot: SourceSnapshot
    /// Bumped when a changed payload is applied so SwiftUI sees content refreshes.
    private(set) var revision: UInt64 = 0
    /// When this row last received new snapshot data from a refresh.
    private(set) var lastAppliedAt: Date?

    init(snapshot: SourceSnapshot) {
        self.id = snapshot.id
        self.snapshot = snapshot
        self.lastAppliedAt = Date()
    }

    func apply(_ incoming: SourceSnapshot) {
        let next = SourceSnapshot.withStructuralDerivedFields(incoming)
        guard snapshot != next else { return }
        snapshot = next
        revision &+= 1
        lastAppliedAt = Date()
    }
}
