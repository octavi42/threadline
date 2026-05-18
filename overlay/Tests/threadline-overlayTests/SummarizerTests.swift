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
            "I've made the following changes to ensure that the session text"
        ))
        XCTAssertFalse(Summarizer.isLowQuality(
            "Adding Ollama local AI to Summarizer and WorkClassifier. Touched Panel.swift."
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
        XCTAssertTrue(text?.contains("Goal:") == true)
        XCTAssertTrue(text?.contains("Ollama") == true)
        XCTAssertTrue(text?.contains("Summarizer.swift") == true)
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
    }

    func testAcceptedBriefRejectsLowQuality() {
        XCTAssertNil(Summarizer.acceptedBrief(
            "I've made the following changes to ensure that the session text"
        ))
        XCTAssertNotNil(Summarizer.acceptedBrief(
            "Adding Ollama support. Touched Summarizer.swift and tests pass."
        ))
    }

    func testNormalizeBriefAllowsMultipleSentences() {
        let brief = SourceSnapshot.normalizeBrief(
            "User asked to add local Ollama. Edited Summarizer.swift and tests pass."
        )
        XCTAssertTrue(brief.contains("Ollama"))
        XCTAssertGreaterThan(brief.count, 40)
    }
}
