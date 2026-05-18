import XCTest
@testable import threadline_overlay

final class LocalLLMTests: XCTestCase {
    func testParseChatResponse() {
        let json = """
        {"model":"qwen2.5:3b","message":{"role":"assistant","content":"Refactoring auth middleware."},"done":true}
        """
        let text = LocalLLM.parseChatResponse(Data(json.utf8))
        XCTAssertEqual(text, "Refactoring auth middleware.")
    }

    func testParseChatResponseInvalid() {
        XCTAssertNil(LocalLLM.parseChatResponse(Data("{}".utf8)))
        XCTAssertNil(LocalLLM.parseChatResponse(Data("not json".utf8)))
    }
}
