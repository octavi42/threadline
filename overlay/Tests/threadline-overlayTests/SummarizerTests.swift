import XCTest
@testable import threadline_overlay

final class SummarizerTests: XCTestCase {
    func testDiscardsSummarizerNoise() {
        XCTAssertTrue(Summarizer.shouldDiscardSnippet(
            "Summarize this coding-assistant session in 2-3 short sentences."
        ))
        XCTAssertTrue(Summarizer.shouldDiscardSnippet(
            "I've made the current session text more concise by limiting it to..."
        ))
    }

    func testDetectsLowQualitySummary() {
        XCTAssertTrue(Summarizer.isLowQuality(
            "The current state of the project involves several key components."
        ))
        XCTAssertTrue(Summarizer.isLowQuality(
            "arrays to views like linesAdded, linesRemoved, and snap.tasksDone"
        ))
        XCTAssertFalse(Summarizer.isLowQuality(
            "Adding Ollama local AI to Summarizer and WorkClassifier"
        ))
    }

    func testStructuralFallbackPrefersTask() {
        let ctx = SummaryContext(
            projectName: "threadline",
            currentTask: "Implement local Ollama support",
            lastTool: "Edit Summarizer.swift",
            filesEdited: ["/Projects/threadline/overlay/Summarizer.swift"],
            activityLine: "—"
        )
        let text = Summarizer.structuralFallback(context: ctx)
        XCTAssertEqual(text, "Implement local Ollama support")
    }

    func testStructuralFallbackUsesFilesWhenNoTask() {
        let ctx = SummaryContext(
            projectName: "threadline",
            currentTask: nil,
            lastTool: nil,
            filesEdited: ["/Projects/threadline/overlay/Panel.swift"],
            activityLine: "—"
        )
        let text = Summarizer.structuralFallback(context: ctx)
        XCTAssertTrue(text?.contains("Panel.swift") == true)
        XCTAssertTrue(text?.contains("threadline") == true)
    }
}
