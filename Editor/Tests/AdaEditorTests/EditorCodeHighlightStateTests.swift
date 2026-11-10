@_spi(AdaEngine) import AdaEngine
import Foundation
import Testing

@testable import AdaEditor

@Suite("EditorCodeHighlightState")
@MainActor
struct EditorCodeHighlightStateTests {
    private static func swiftSource(lines: Int, marker: String = "value") -> String {
        (0..<lines).map { "let \(marker)\($0): String = \"line \($0)\" // comment \($0)" }.joined(separator: "\n")
    }

    private static func request(_ source: String, document: String = "text:Large.swift") -> EditorCodeHighlightState.Request {
        EditorCodeHighlightState.Request(documentID: document, source: source, language: .swift, palette: .dark, keywordFont: nil)
    }

    @Test("switching to another large document never shows the previous document's spans")
    func documentSwitchStartsPlain() async {
        let state = EditorCodeHighlightState()
        let first = Self.swiftSource(lines: 1_500, marker: "first")
        let second = Self.swiftSource(lines: 1_600, marker: "second")
        _ = state.spans(for: Self.request(first, document: "text:First.swift"))
        await state.waitUntilIdle()
        #expect(!state.spans(for: Self.request(first, document: "text:First.swift")).isEmpty)

        // Another document, or the same one restyled, starts as plain text.
        #expect(state.spans(for: Self.request(second, document: "text:Second.swift")).isEmpty)
        var recolored = Self.request(first + "\n// edit", document: "text:First.swift")
        recolored.palette = .monokai
        #expect(state.spans(for: recolored).isEmpty)
        await state.waitUntilIdle()
        #expect(state.spans(for: recolored) == EditorSyntaxHighlighter.spans(
            for: recolored.source, language: .swift, palette: .monokai
        ))
    }

    @Test("small sources keep synchronous spans")
    func smallSourcesStaySynchronous() {
        let source = Self.swiftSource(lines: 20)
        #expect(source.utf8.count <= EditorCodeHighlightState.synchronousUTF8Limit)
        let state = EditorCodeHighlightState()

        let spans = state.spans(for: Self.request(source))

        #expect(!spans.isEmpty)
        #expect(spans == EditorSyntaxHighlighter.spans(for: source, language: .swift, palette: .dark))
        #expect(!state.isHighlighting)
        #expect(state.backgroundPasses == 0)
    }

    @Test("large sources highlight off the main actor and keep the previous spans meanwhile")
    func largeSourcesHighlightInBackground() async {
        let original = Self.swiftSource(lines: 1_500)
        #expect(original.utf8.count > EditorCodeHighlightState.synchronousUTF8Limit)
        let state = EditorCodeHighlightState()

        #expect(state.spans(for: Self.request(original)).isEmpty)
        #expect(state.isHighlighting)
        await state.waitUntilIdle()
        let expected = EditorSyntaxHighlighter.spans(for: original, language: .swift, palette: .dark)
        #expect(!expected.isEmpty)
        #expect(state.spans(for: Self.request(original)) == expected)
        #expect(state.revision == 1)

        let edited = original + "\nlet appended = 1"
        // The edit is shown with the previous colors until its own pass finishes.
        #expect(state.spans(for: Self.request(edited)) == expected)
        await state.waitUntilIdle()
        #expect(state.spans(for: Self.request(edited)) == EditorSyntaxHighlighter.spans(for: edited, language: .swift, palette: .dark))
        #expect(state.backgroundPasses == 2)
    }

    @Test("a burst of edits coalesces into a pass for the latest text")
    func editBurstCoalesces() async {
        let state = EditorCodeHighlightState()
        let sources = (0..<6).map { Self.swiftSource(lines: 1_500, marker: "edit\($0)_") }

        for source in sources {
            _ = state.spans(for: Self.request(source))
        }
        await state.waitUntilIdle()

        // The worker starts after the synchronous burst, so the edits collapse into at most one pass
        // beyond any pass that was already running; intermediate sources are never highlighted.
        #expect((1...2).contains(state.backgroundPasses))
        let last = sources[sources.count - 1]
        #expect(state.spans(for: Self.request(last)) == EditorSyntaxHighlighter.spans(for: last, language: .swift, palette: .dark))
        #expect(!state.isHighlighting)
    }
}
