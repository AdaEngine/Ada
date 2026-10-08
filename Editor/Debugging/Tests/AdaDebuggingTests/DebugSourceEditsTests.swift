import Testing
@testable import AdaDebugging

@Suite("Breakpoint source edits")
struct DebugSourceEditsTests {
    @Test func insertionKeepsOriginalStatement() {
        let points = [SourceBreakpoint(path: "a.swift", line: 2), SourceBreakpoint(path: "b.swift", line: 2)]
        let moved = DebugSourceEdits.relocate(points, path: "a.swift", old: "a\nb\nc", new: "x\ny\na\nb\nc")
        #expect(moved.map(\.line) == [4, 2])
        #expect(moved.map(\.id) == points.map(\.id))
    }

    @Test func deletingBreakpointLineRemovesAnchor() {
        let points = [SourceBreakpoint(path: "a", line: 2), SourceBreakpoint(path: "a", line: 3)]
        let moved = DebugSourceEdits.relocate(points, path: "a", old: "a\nb\nc", new: "a\nc")
        #expect(moved.count == 1)
        #expect(moved.first?.id == points[1].id)
        #expect(moved.first?.line == 2)
    }

    @Test func changingExpressionKeepsLine() {
        let points = [SourceBreakpoint(path: "a", line: 2, enabled: false)]
        #expect(DebugSourceEdits.relocate(points, path: "a", old: "a\nvar n = 1;\nc", new: "a\nvar n = 2;\nc") == points)
    }
}
