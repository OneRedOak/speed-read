import XCTest
@testable import SRCore

final class ChunkerTests: XCTestCase {
    func testSplitsSentences() {
        let chunks = Chunker.split("First sentence here. Second sentence follows! Third one ends?")
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0].text, "First sentence here.")
        XCTAssertEqual(chunks[0].id, 0)
        XCTAssertEqual(chunks[2].id, 2)
    }

    func testMergesShortFragments() {
        let chunks = Chunker.split("Dr. Smith arrived early in the morning. He left at noon.")
        // "Dr." must not become its own tiny chunk.
        XCTAssertTrue(chunks.allSatisfy { $0.text.count >= Chunker.minChunkLength || chunks.count == 1 })
    }

    func testEmptyInput() {
        XCTAssertTrue(Chunker.split("").isEmpty)
        XCTAssertTrue(Chunker.split("   \n  ").isEmpty)
    }

    func testOffsetsPointIntoOriginal() {
        let text = "Alpha beta gamma. Delta epsilon zeta."
        let chunks = Chunker.split(text)
        for chunk in chunks {
            let start = text.index(text.startIndex, offsetBy: chunk.offset)
            XCTAssertTrue(text[start...].hasPrefix(chunk.text.prefix(5)))
        }
    }
}
