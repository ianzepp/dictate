import XCTest
@testable import DictateCore

final class CleanupRulesTests: XCTestCase {
    private struct Golden: Decodable {
        struct Drift: Decodable { let source: String; let cleaned: String; let expected: Bool; let accepted: String? }
        struct Matcher: Decodable {
            struct Opcode: Decodable { let tag: String; let i1: Int; let i2: Int; let j1: Int; let j2: Int }
            let a: [String]; let b: [String]; let autojunk: Bool; let ratio: Double; let opcodes: [Opcode]
        }
        struct Replace: Decodable { let text: String; let pairs: [Replacement]; let expected: String }
        struct Wrapped: Decodable { let text: String; let expected: String }
        struct Chunks: Decodable { let text: String; let expected: [String] }
        struct Messages: Decodable { let text: String; let pairs: [Replacement]; let expected: [CleanupMessage] }
        let drift: [Drift]; let matcher: [Matcher]; let replacements: [Replace]
        let wrappers: [Wrapped]; let chunks: [Chunks]; let messages: [Messages]
    }

    private func golden() throws -> Golden {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "cleanup-golden", withExtension: "json"))
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    }

    func testPythonSequenceMatcherParity() throws {
        for (index, entry) in try golden().matcher.enumerated() {
            let matcher = SequenceMatcher(entry.a, entry.b, autojunk: entry.autojunk)
            XCTAssertEqual(matcher.ratio(), entry.ratio, accuracy: 1e-14, "ratio case \(index)")
            let expected = entry.opcodes.map { SequenceMatcher<String>.Opcode(tag: $0.tag, i1: $0.i1, i2: $0.i2, j1: $0.j1, j2: $0.j2) }
            XCTAssertEqual(matcher.opcodes(), expected, "opcodes case \(index)")
        }
    }

    func testPythonDriftParityAndAcceptedFallback() throws {
        for (index, entry) in try golden().drift.enumerated() {
            XCTAssertEqual(CleanupRules.drifted(entry.source, entry.cleaned), entry.expected, "drift case \(index): \(entry.source) -> \(entry.cleaned)")
            XCTAssertEqual(CleanupRules.accepted(entry.source, response: entry.cleaned), entry.accepted, "accepted case \(index)")
        }
        XCTAssertNil(CleanupRules.accepted("hello", response: nil))
        XCTAssertNil(CleanupRules.accepted("hello", response: " \n "))
        XCTAssertNil(CleanupRules.accepted("we should not merge", response: "We should merge."))
        XCTAssertEqual(CleanupRules.accepted("hello", response: "Sure, here is the cleaned transcript:\n\"Hello.\""), "Hello.")
    }

    func testPythonLiteralReplacementParity() throws {
        for entry in try golden().replacements {
            XCTAssertEqual(CleanupRules.replacements(entry.text, pairs: entry.pairs), entry.expected, entry.text)
        }
    }

    func testPythonPromptParity() throws {
        for entry in try golden().messages {
            XCTAssertEqual(CleanupRules.messages(entry.text, pairs: entry.pairs), entry.expected)
        }
    }

    func testPythonWrappingAndChunkParity() throws {
        let corpus = try golden()
        for entry in corpus.wrappers { XCTAssertEqual(CleanupRules.stripWrapping(entry.text), entry.expected, entry.text) }
        for entry in corpus.chunks { XCTAssertEqual(CleanupRules.chunks(entry.text), entry.expected, entry.text) }
    }
}
