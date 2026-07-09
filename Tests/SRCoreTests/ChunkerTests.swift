import Testing
@testable import SRCore

@Suite struct ChunkerTests {
    @Test func splitsSentences() {
        let chunks = Chunker.split("First sentence here. Second sentence follows! Third one ends?")
        #expect(chunks.count == 3)
        #expect(chunks[0].text == "First sentence here.")
        #expect(chunks[0].id == 0)
        #expect(chunks[2].id == 2)
    }

    @Test func mergesShortFragments() {
        let chunks = Chunker.split("Dr. Smith arrived early in the morning. He left at noon.")
        // "Dr." must not become its own tiny chunk.
        #expect(chunks.allSatisfy { $0.text.count >= Chunker.minChunkLength || chunks.count == 1 })
    }

    @Test func emptyInput() {
        #expect(Chunker.split("").isEmpty)
        #expect(Chunker.split("   \n  ").isEmpty)
    }

    @Test func offsetsPointIntoOriginal() {
        let text = "Alpha beta gamma. Delta epsilon zeta."
        let chunks = Chunker.split(text)
        for chunk in chunks {
            let start = text.index(text.startIndex, offsetBy: chunk.offset)
            #expect(text[start...].hasPrefix(chunk.text.prefix(5)))
        }
    }

    @Test func splitsPathologicallyLongSentences() {
        let input = String(repeating: "word ", count: 2_500)
        let chunks = Chunker.split(input)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.text.count <= Chunker.maxChunkLength })
        #expect(chunks.map(\.offset) == chunks.map(\.offset).sorted())
    }
}
