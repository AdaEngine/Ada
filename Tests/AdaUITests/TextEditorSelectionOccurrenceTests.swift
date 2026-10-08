import AdaInput
@testable import AdaPlatform
@_spi(Internal) @testable import AdaUI
import Math
import Testing

@Suite("Text editor selected identifier occurrences", .serialized)
@MainActor
struct TextEditorSelectionOccurrenceTests {
    init() async throws { try Application.prepareForTest() }

    @Test func findsOnlyWholeCaseSensitiveIdentifiers() {
        let line = "SPEED speed SPEED_LIMIT xsPEED SPEED"
        #expect(TextEditorIdentifierOccurrences.ranges(of: "SPEED", in: line) == [0..<5, 31..<36])
        #expect(TextEditorIdentifierOccurrences.ranges(of: "speed", in: line) == [6..<11])
        #expect(TextEditorIdentifierOccurrences.ranges(of: "SPEED LIMIT", in: line).isEmpty)
        #expect(TextEditorIdentifierOccurrences.ranges(of: "", in: line).isEmpty)
        #expect(TextEditorIdentifierOccurrences.ranges(of: "10", in: "10 + 10").isEmpty)
    }

    @Test func selectionHighlightsOtherUsesAndClearsAfterEdit() throws {
        var text = "let SPEED = 10\nmove(SPEED)\nlet SPEED_LIMIT = SPEED"
        let tester = ViewTester {
            TextEditor(
                text: Binding(get: { text }, set: { text = $0 }),
                highlightsSelectedIdentifier: true
            )
            .font(.system(size: 12))
            .frame(width: 360, height: 160)
        }.setSize(Size(width: 380, height: 180)).performLayout()
        let node = try #require(tester.sendMouseEvent(at: Point(100, 28), phase: .began) as? TextEditorViewNode)
        tester.sendMouseEvent(at: Point(100, 28), phase: .ended)

        node.selectionAnchor = 4
        node.selectionHead = 9
        #expect(node.selectionOccurrences()[0] == [4..<9])
        #expect(node.selectionOccurrences()[1] == [5..<10])
        #expect(node.selectionOccurrences()[2] == [18..<23])

        node.selectionAnchor = node.lines()[2].startOffset + 4
        node.selectionHead = node.selectionAnchor + 5
        #expect(node.selectionOccurrences().isEmpty)

        node.selectionAnchor = 4
        node.selectionHead = 9
        node.replaceSelection(with: "VELOCITY")
        #expect(node.selectionOccurrences().isEmpty)
    }
}
