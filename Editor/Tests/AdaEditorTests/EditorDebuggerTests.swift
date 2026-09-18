import AdaDebugging
import Foundation
import Testing

@testable import AdaEditor

@Suite("Editor debugger state")
@MainActor
struct EditorDebuggerTests {
    @Test func breakpointsAndWatchesSurviveProjectMove() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("debug-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("state.json")
        let first = EditorDebugger()
        first.configure(projectURL: root.appendingPathComponent("old"), storageURL: store)
        first.toggleBreakpoint(path: root.appendingPathComponent("old/Sources/main.swift").path, line: 4)
        first.watchExpression = "player.position.x"
        first.addWatch()
        let restored = EditorDebugger()
        restored.configure(projectURL: root.appendingPathComponent("new"), storageURL: store)
        #expect(restored.breakpoints.count == 1)
        #expect(restored.breakpoints.first?.path == root.appendingPathComponent("new/Sources/main.swift").path)
        #expect(restored.breakpoints.first?.line == 4)
        #expect(restored.watches == ["player.position.x"])
    }

    @Test func toggleAndDisablePersist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("debug-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("state.json")
        let state = EditorDebugger()
        state.configure(projectURL: root, storageURL: store)
        state.toggleBreakpoint(path: root.appendingPathComponent("main.ada").path, line: 7)
        let point = try #require(state.breakpoints.first)
        state.setBreakpointEnabled(point, enabled: false)
        let restored = EditorDebugger()
        restored.configure(projectURL: root, storageURL: store)
        #expect(restored.breakpoints.first?.enabled == false)
        restored.toggleBreakpoint(path: point.path, line: point.line)
        #expect(restored.breakpoints.isEmpty)
    }
}
