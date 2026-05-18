import Foundation

/// Pre-split diff text for SwiftUI — avoids `components(separatedBy:)` in view bodies.
struct DiffDisplay: Equatable {
    let lines: [String]
    let totalLineCount: Int

    static let empty = DiffDisplay(lines: [], totalLineCount: 0)

    var hasMore: Bool { totalLineCount > lines.count }
    var hiddenCount: Int { max(0, totalLineCount - lines.count) }

    static func from(text: String, maxVisible: Int = 50) -> DiffDisplay {
        guard !text.isEmpty else { return .empty }
        let all = text.components(separatedBy: "\n")
        return DiffDisplay(lines: Array(all.prefix(maxVisible)), totalLineCount: all.count)
    }
}

extension FileEditOp {
    /// Build displays once when the edit op is created.
    static func withDisplays(seq: Int,
                             tool: String,
                             timestamp: String,
                             oldText: String = "",
                             newText: String = "",
                             patchText: String = "",
                             note: String = "",
                             rawLinesAdded: Int = 0,
                             rawLinesRemoved: Int = 0) -> FileEditOp {
        FileEditOp(seq: seq,
                   tool: tool,
                   timestamp: timestamp,
                   oldText: oldText,
                   newText: newText,
                   patchText: patchText,
                   note: note,
                   rawLinesAdded: rawLinesAdded,
                   rawLinesRemoved: rawLinesRemoved,
                   patchDisplay: DiffDisplay.from(text: patchText),
                   oldTextDisplay: DiffDisplay.from(text: oldText),
                   newTextDisplay: DiffDisplay.from(text: newText))
    }
}
