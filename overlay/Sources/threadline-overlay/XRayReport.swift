import Foundation

// Mirrors the JSON emitted by `threadline xray --json`. Keep in sync with
// src/threadline/xray/json_report.py — the schema_version field gates breaking
// changes.

struct XRayReport: Codable {
    let schemaVersion: Int
    let repo: String?
    let base: String
    let session: String?
    let generatedAt: String
    let files: [XRayFile]

    enum CodingKeys: String, CodingKey {
        case repo, base, session, files
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
    }
}

struct XRayFile: Codable, Identifiable {
    let path: String
    let framingPrompts: [XRayPrompt]
    let immediatePrompts: [XRayPrompt]
    let editCounts: [XRayEditCount]
    let retryCount: Int
    let hasTestFailure: Bool
    let hunks: [XRayHunk]

    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case path, hunks
        case framingPrompts = "framing_prompts"
        case immediatePrompts = "immediate_prompts"
        case editCounts = "edit_counts"
        case retryCount = "retry_count"
        case hasTestFailure = "has_test_failure"
    }
}

struct XRayPrompt: Codable, Hashable {
    let source: String
    let text: String
}

struct XRayEditCount: Codable, Hashable {
    let tool: String
    let count: Int
}

struct XRayHunk: Codable, Hashable {
    let baseStart: Int
    let baseCount: Int
    let newStart: Int
    let newCount: Int
    let body: [String]
    let tests: [XRayTest]

    enum CodingKeys: String, CodingKey {
        case tests, body
        case baseStart = "base_start"
        case baseCount = "base_count"
        case newStart = "new_start"
        case newCount = "new_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.baseStart = try c.decode(Int.self, forKey: .baseStart)
        self.baseCount = try c.decode(Int.self, forKey: .baseCount)
        self.newStart = try c.decode(Int.self, forKey: .newStart)
        self.newCount = try c.decode(Int.self, forKey: .newCount)
        self.body = try c.decodeIfPresent([String].self, forKey: .body) ?? []
        self.tests = try c.decode([XRayTest].self, forKey: .tests)
    }
}

struct XRayTest: Codable, Hashable {
    let tool: String
    let command: String
    let output: String
    let exitStatus: Int?
    let timestamp: String

    enum CodingKeys: String, CodingKey {
        case tool, command, output, timestamp
        case exitStatus = "exit_status"
    }
}
