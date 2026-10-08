//
//  EditorWindow.swift
//  AdaEngine
//

@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI

/// Transparent chrome host used by the editor window.
///
/// Empty parts of the toolbar are treated as draggable window chrome, while
/// interactive subviews keep receiving input normally.
final class EditorWindowDragPassthroughView: UIView, UIWindowDragRegionResolving {
    func uiAllowsWindowDrag(at windowPoint: Point, with event: MouseEvent) -> Bool {
        let localPoint = convert(windowPoint, from: window)
        for subview in subviews.reversed() {
            let subviewPoint = subview.convert(localPoint, from: self)
            guard subview.point(inside: subviewPoint, with: event) else {
                continue
            }

            if let dragResolver = subview as? any UIWindowDragRegionResolving {
                return dragResolver.uiAllowsWindowDrag(at: windowPoint, with: event)
            }

            return false
        }

        return true
    }
}

/// Window wrapper for the editor content used by tests and legacy launch paths.
final class EditorWindow: UIWindow {
    private(set) var inspectableView: LayoutInspectableView?

    required init(frame: Rect) {
        super.init(frame: frame)
        installEditorContent()
    }

    override init(frame: Rect, configuration: Configuration) {
        super.init(frame: frame, configuration: configuration)
        installEditorContent()
    }

    private func installEditorContent() {
        let inspectableView = LayoutInspectableView(frame: Rect(origin: .zero, size: frame.size))
        inspectableView.backgroundColor = .clear
        inspectableView.autoresizingRules = [.flexibleWidth, .flexibleHeight]

        // Keep the legacy window wrapper lightweight and deterministic in tests.
        // ProjectEditorLauncher uses UIWindowManager.spawnWindow for the real
        // SwiftUI editor content; this host only preserves resize behavior for
        // older editor-window paths.
        let editorContentView = UIView(frame: inspectableView.bounds)
        editorContentView.backgroundColor = .clear
        editorContentView.autoresizingRules = [.flexibleWidth, .flexibleHeight]
        inspectableView.addSubview(editorContentView)
        addSubview(inspectableView)

        self.inspectableView = inspectableView
    }

    override func frameDidChange() {
        super.frameDidChange()
        let contentFrame = Rect(origin: .zero, size: frame.size)
        inspectableView?.frame = contentFrame
        inspectableView?.bounds.size = frame.size
        if let editorContentView = inspectableView?.subviews.first {
            editorContentView.frame = contentFrame
            editorContentView.bounds.size = frame.size
        }
    }
}
