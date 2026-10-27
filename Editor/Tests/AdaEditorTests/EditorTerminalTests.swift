import AdaEngine
import Foundation
import SwiftTerm
import Testing
@testable import AdaEditor

@Suite(.serialized)
struct EditorTerminalTests {
    @Test func interruptAndClipboardUseDifferentChords() {
        let event = KeyEvent(window: .empty, keyCode: .c, modifiers: .control, status: .down, time: 0, isRepeated: false)
        #expect(!EditorTerminalKeyboard.isClipboardChord(event.modifiers))
        #expect(EditorTerminalKeyboard.sequence(event, applicationCursor: false) == "\u{3}")
        #if os(Windows) || os(Linux)
        #expect(EditorTerminalKeyboard.isClipboardChord([.control, .shift]))
        #endif
    }

    @Test @MainActor
    func realShellInputResizeAndExit() async throws {
        #if os(macOS) || os(Linux) || os(Windows)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("terminal проба \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorTerminalSession()
        defer { session.stop() }
        session.start(in: root)
        #expect(session.error == nil)
        #expect(session.isRunning)
        session.resize(columns: 100, rows: 30)
        #expect(session.terminal.cols == 100)
        #expect(session.terminal.rows == 30)
        #if os(Windows)
        session.send("echo TERMINAL_OK && cd\r")
        #else
        session.send("printf 'TERMINAL_OK\\n'; pwd\r")
        #endif
        var output = ""
        for _ in 0..<300 {
            try await Task.sleep(for: .milliseconds(20))
            output = String(decoding: session.terminal.getBufferAsData(), as: UTF8.self)
            if output.contains("TERMINAL_OK"), output.contains(root.lastPathComponent) { break }
        }
        #expect(output.contains("TERMINAL_OK"))
        #expect(output.contains(root.lastPathComponent))
        session.send("exit\r")
        for _ in 0..<300 where session.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!session.isRunning)
        session.restart()
        #expect(session.isRunning)
        #endif
    }

    @Test @MainActor
    func workspaceOwnsAndClosesIndependentShells() {
        #if os(macOS) || os(Linux) || os(Windows)
        let workspace = EditorTerminalWorkspace()
        defer { workspace.stop() }
        workspace.start(in: FileManager.default.temporaryDirectory)
        let first = workspace.activeSession
        #expect(first.isRunning)
        workspace.add()
        let second = workspace.activeSession
        #expect(second.isRunning)
        #expect(first.isRunning)
        workspace.select(first)
        workspace.close(second)
        #expect(!second.isRunning)
        #expect(first.isRunning)
        #expect(workspace.activeSession === first)
        workspace.close(first)
        #expect(!first.isRunning)
        #expect(workspace.sessions.count == 1)
        #expect(workspace.activeSession !== first)
        #expect(workspace.activeSession.isRunning)
        workspace.stop()
        #expect(workspace.sessions.allSatisfy { !$0.isRunning })
        #endif
    }

    @Test @MainActor
    func ansiAndAlternateScreen() {
        let session = EditorTerminalSession()
        session.terminal.feed(text: "\u{1b}[31mred\u{1b}[0m\r\nПривет")
        let snapshot = session.terminal.makeRenderSnapshot(scope: .full)
        #expect(snapshot.lines[0].cells.prefix(3).map(\.text).joined() == "red")
        #expect(snapshot.lines[0].cells[0].attribute.fg == .ansi256(code: 1))
        session.terminal.feed(text: "\u{1b}[?1049hfull screen")
        #expect(session.terminal.makeRenderSnapshot(scope: .full).isAlternateScreen)
        session.terminal.feed(text: "\u{1b}[?1049l")
        #expect(!session.terminal.makeRenderSnapshot(scope: .full).isAlternateScreen)
    }
}
