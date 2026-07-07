import Foundation
import NaturalLanguage

/// A sentence chunk with its position in the normalized text (F-5).
public struct Chunk: Sendable, Identifiable {
    public let id: Int          // 0-based sentence index
    public let text: String
    public let offset: Int      // character offset in the normalized text

    public init(id: Int, text: String, offset: Int) {
        self.id = id
        self.text = text
        self.offset = offset
    }
}

/// Sentence segmentation via NLTokenizer, with merging of very short
/// fragments (initials, list numbers) into their successor so we don't
/// pay per-request overhead on 3-character chunks.
public enum Chunker {
    public static let minChunkLength = 8

    public static func split(_ text: String) -> [Chunk] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text

        var raw: [(text: String, offset: Int)] = []
        // Accumulate offsets from the previous sentence boundary: measuring
        // each from startIndex is an O(n) walk per sentence (O(n²) on
        // book-length input — seconds of CPU before synthesis starts).
        var cursor = text.startIndex
        var cursorOffset = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                cursorOffset += text.distance(from: cursor, to: range.lowerBound)
                cursor = range.lowerBound
                raw.append((sentence, cursorOffset))
            }
            return true
        }

        // Merge fragments shorter than minChunkLength into the next sentence.
        var merged: [(text: String, offset: Int)] = []
        for piece in raw {
            if let last = merged.last, last.text.count < minChunkLength {
                merged[merged.count - 1] = (last.text + " " + piece.text, last.offset)
            } else {
                merged.append(piece)
            }
        }

        return merged.enumerated().map { index, piece in
            Chunk(id: index, text: piece.text, offset: piece.offset)
        }
    }
}
