#if os(macOS)
@testable import AdaPlatform
import AppKit
import Testing

@MainActor
struct MacOSFramePacingWindowTests {
    /// A real NSWindow with deterministic focus/visibility flags; no external app's keyboard focus is consulted.
    final class NativeWindow: NSWindow {
        var visibleForTest = true
        var keyForTest = false
        var mainForTest = false
        var minimizedForTest = false
        override var isVisible: Bool { visibleForTest }
        override var isKeyWindow: Bool { keyForTest }
        override var isMainWindow: Bool { mainForTest }
        override var isMiniaturized: Bool { minimizedForTest }

        init(width: CGFloat, height: CGFloat) {
            _ = NSApplication.shared
            super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: true)
            isReleasedWhenClosed = false
        }
    }

    @Test
    func visibleEditorRemainsTheFramePacingWindowWhenAnotherAppHasFocus() {
        let opening = NativeWindow(width: 1_024, height: 700)
        opening.visibleForTest = false
        opening.mainForTest = true
        let editor = NativeWindow(width: 2_560, height: 1_410)
        let palette = NativeWindow(width: 300, height: 400)
        #expect(MacOSWindowManager.preferredRenderingWindow(in: [opening, palette, editor]) === editor)
        #expect(MacOSWindowManager.preferredRenderingWindow(in: [editor, opening, palette]) === editor)
    }

    @Test
    func focusedOrMainWindowWinsAndHiddenOrMinimizedWindowsAreSkipped() {
        let editor = NativeWindow(width: 2_560, height: 1_410)
        let other = NativeWindow(width: 800, height: 600)
        other.mainForTest = true
        #expect(MacOSWindowManager.preferredRenderingWindow(in: [editor, other]) === other)
        editor.keyForTest = true
        #expect(MacOSWindowManager.preferredRenderingWindow(in: [other, editor]) === editor)
        editor.minimizedForTest = true
        #expect(MacOSWindowManager.preferredRenderingWindow(in: [editor, other]) === other)
        other.visibleForTest = false
        #expect(MacOSWindowManager.preferredRenderingWindow(in: [editor, other]) == nil)
        #expect(MacOSWindowManager.preferredRenderingWindow(in: [NSWindow]()) == nil)
    }
}
#endif
