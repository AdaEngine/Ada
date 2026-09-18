import AdaInput
import AdaUtils
import Foundation
import Math

public enum UIDebugOverlayMode: String, Codable, Sendable {
    case off
    case layoutBounds = "layout_bounds"
    case focusedNode = "focused_node"
    case hitTestTarget = "hit_test_target"
    case redraw
}

public enum UINodeSelector: Hashable, Sendable {
    case accessibilityIdentifier(String)
    case runtimeID(String)

    public var externalValue: String {
        switch self {
        case let .accessibilityIdentifier(value):
            return "accessibility:\(value)"
        case let .runtimeID(value):
            return "runtime:\(value)"
        }
    }
}

public struct UINodeSummary: Codable, Hashable, Sendable {
    public let runtimeId: String
    public let accessibilityIdentifier: String?
    public let nodeType: String
    public let viewType: String
    public let frame: Rect
    public let absoluteFrame: Rect
    public let canBecomeFocused: Bool
    public let isFocused: Bool
    public let isHidden: Bool?
    public let isInteractable: Bool

    public init(
        runtimeId: String,
        accessibilityIdentifier: String?,
        nodeType: String,
        viewType: String,
        frame: Rect,
        absoluteFrame: Rect,
        canBecomeFocused: Bool,
        isFocused: Bool,
        isHidden: Bool?,
        isInteractable: Bool
    ) {
        self.runtimeId = runtimeId
        self.accessibilityIdentifier = accessibilityIdentifier
        self.nodeType = nodeType
        self.viewType = viewType
        self.frame = frame
        self.absoluteFrame = absoluteFrame
        self.canBecomeFocused = canBecomeFocused
        self.isFocused = isFocused
        self.isHidden = isHidden
        self.isInteractable = isInteractable
    }
}

public struct UINodeSnapshot: Codable, Hashable, Sendable {
    public let sceneNodeID: String?
    public let runtimeId: String
    public let accessibilityIdentifier: String?
    public let nodeType: String
    public let viewType: String
    public let frame: Rect
    public let absoluteFrame: Rect
    public let canBecomeFocused: Bool
    public let isFocused: Bool
    public let isHidden: Bool?
    public let isInteractable: Bool
    public let parent: UINodeSummary?
    public let children: [Self]

    public init(
        runtimeId: String,
        accessibilityIdentifier: String?,
        nodeType: String,
        viewType: String,
        frame: Rect,
        absoluteFrame: Rect,
        canBecomeFocused: Bool,
        isFocused: Bool,
        isHidden: Bool?,
        isInteractable: Bool,
        parent: UINodeSummary?,
        children: [Self],
        sceneNodeID: String? = nil
    ) {
        self.sceneNodeID = sceneNodeID
        self.runtimeId = runtimeId
        self.accessibilityIdentifier = accessibilityIdentifier
        self.nodeType = nodeType
        self.viewType = viewType
        self.frame = frame
        self.absoluteFrame = absoluteFrame
        self.canBecomeFocused = canBecomeFocused
        self.isFocused = isFocused
        self.isHidden = isHidden
        self.isInteractable = isInteractable
        self.parent = parent
        self.children = children
    }
}

public struct UIWindowSummary: Codable, Hashable, Sendable {
    public let windowId: Int
    public let title: String
    public let frame: Rect
    public let isActive: Bool
    public let overlayMode: UIDebugOverlayMode
    public let rootCount: Int

    public init(
        windowId: Int,
        title: String,
        frame: Rect,
        isActive: Bool,
        overlayMode: UIDebugOverlayMode,
        rootCount: Int
    ) {
        self.windowId = windowId
        self.title = title
        self.frame = frame
        self.isActive = isActive
        self.overlayMode = overlayMode
        self.rootCount = rootCount
    }
}

public struct UIWindowSnapshot: Codable, Hashable, Sendable {
    public let summary: UIWindowSummary
    public let roots: [UINodeSnapshot]

    public init(summary: UIWindowSummary, roots: [UINodeSnapshot]) {
        self.summary = summary
        self.roots = roots
    }
}

public struct UIHitTestResult: Codable, Hashable, Sendable {
    public let windowId: Int
    public let point: Point
    public let node: UINodeSnapshot
    public let path: [UINodeSummary]

    public init(windowId: Int, point: Point, node: UINodeSnapshot, path: [UINodeSummary]) {
        self.windowId = windowId
        self.point = point
        self.node = node
        self.path = path
    }
}

public struct UILayoutDiagnostics: Codable, Hashable, Sendable {
    public let windowId: Int
    public let viewportSize: Size
    public let overlayMode: UIDebugOverlayMode
    public let focusedNode: UINodeSummary?
    public let target: UINodeSnapshot?
    public let parentPath: [UINodeSummary]
    public let children: [UINodeSummary]
    public let hasScrollContainer: Bool
    public let textInputFocused: Bool
    public let subtree: UINodeSnapshot?

    public init(
        windowId: Int,
        viewportSize: Size,
        overlayMode: UIDebugOverlayMode,
        focusedNode: UINodeSummary?,
        target: UINodeSnapshot?,
        parentPath: [UINodeSummary],
        children: [UINodeSummary],
        hasScrollContainer: Bool,
        textInputFocused: Bool,
        subtree: UINodeSnapshot?
    ) {
        self.windowId = windowId
        self.viewportSize = viewportSize
        self.overlayMode = overlayMode
        self.focusedNode = focusedNode
        self.target = target
        self.parentPath = parentPath
        self.children = children
        self.hasScrollContainer = hasScrollContainer
        self.textInputFocused = textInputFocused
        self.subtree = subtree
    }
}

public struct UIActionResult: Codable, Hashable, Sendable {
    public let action: String
    public let windowId: Int
    public let target: UINodeSnapshot?
    public let focusedNode: UINodeSummary?
    public let overlayMode: UIDebugOverlayMode
    public let viewportSize: Size

    public init(
        action: String,
        windowId: Int,
        target: UINodeSnapshot?,
        focusedNode: UINodeSummary?,
        overlayMode: UIDebugOverlayMode,
        viewportSize: Size
    ) {
        self.action = action
        self.windowId = windowId
        self.target = target
        self.focusedNode = focusedNode
        self.overlayMode = overlayMode
        self.viewportSize = viewportSize
    }
}

public enum UIInspectionError: LocalizedError {
    case nodeNotFound(String)
    case ambiguousSelector(String, [UINodeSummary])
    case scrollContainerNotFound(String)
    case noFocusableNode(String)

    public var errorDescription: String? {
        switch self {
        case let .nodeNotFound(selector):
            return "UI node was not found for selector '\(selector)'."
        case let .ambiguousSelector(selector, _):
            return "UI selector '\(selector)' matched multiple nodes."
        case let .scrollContainerNotFound(selector):
            return "No scroll container ancestor was found for selector '\(selector)'."
        case let .noFocusableNode(selector):
            return "Selector '\(selector)' did not resolve to a focusable node."
        }
    }
}

@MainActor
public protocol UIInspectableViewContainer: AnyObject {
    var uiInspectionWindowId: Int { get }
    var uiInspectionOverlayMode: UIDebugOverlayMode { get }

    func uiWindowSummary() -> UIWindowSummary
    func uiTreeRoots() -> [UINodeSnapshot]
    func uiFindNodes(matching selector: UINodeSelector) -> [UINodeSnapshot]
    func uiNode(matching selector: UINodeSelector) throws -> UINodeSnapshot
    func uiHitTest(at windowPoint: Point) -> UIHitTestResult?
    func uiLayoutDiagnostics(matching selector: UINodeSelector?, subtreeDepth: Int?) throws -> UILayoutDiagnostics
    func uiSetDebugOverlay(_ mode: UIDebugOverlayMode)
    func uiFocusNode(matching selector: UINodeSelector) throws -> UIActionResult
    func uiFocusNext() -> UIActionResult?
    func uiFocusPrevious() -> UIActionResult?
    func uiScrollToNode(matching selector: UINodeSelector) throws -> UIActionResult
    func uiTapNode(matching selector: UINodeSelector) throws -> UIActionResult
}

extension UIWindow {
    public func uiInspectableContainers() -> [any UIInspectableViewContainer] {
        var result: [any UIInspectableViewContainer] = []

        func walk(view: UIView) {
            if let container = view as? any UIInspectableViewContainer {
                result.append(container)
            }

            for subview in view.subviews {
                walk(view: subview)
            }
        }

        for subview in self.subviews {
            walk(view: subview)
        }

        return result
    }
}

extension UIContainerView: UIInspectableViewContainer {
    public var uiInspectionWindowId: Int {
        self.window?.id.id ?? RID.empty.id
    }

    public var uiInspectionOverlayMode: UIDebugOverlayMode {
        self.inspectionDebugOverlayMode
    }

    public func uiWindowSummary() -> UIWindowSummary {
        UIWindowSummary(
            windowId: self.uiInspectionWindowId,
            title: self.window?.title ?? "",
            frame: self.window?.frame ?? .zero,
            isActive: self.window?.isActive ?? false,
            overlayMode: self.inspectionDebugOverlayMode,
            rootCount: 1
        )
    }

    public func uiTreeRoots() -> [UINodeSnapshot] {
        self.layoutIfNeeded()
        return [self.viewTree.rootNode.contentNode.uiSnapshot(focusedNode: self.focusManager.focusedNode)]
    }

    public func uiFindNodes(matching selector: UINodeSelector) -> [UINodeSnapshot] {
        self.layoutIfNeeded()
        return self.resolveNodes(matching: selector)
            .map { $0.uiSnapshot(focusedNode: self.focusManager.focusedNode, maxDepth: 1) }
    }

    public func uiNode(matching selector: UINodeSelector) throws -> UINodeSnapshot {
        let node = try self.resolveUniqueNode(matching: selector)
        return node.uiSnapshot(focusedNode: self.focusManager.focusedNode)
    }

    public func uiHitTest(at windowPoint: Point) -> UIHitTestResult? {
        self.layoutIfNeeded()
        let event = self.makeInspectionMouseEvent(at: windowPoint, phase: .began)
        let localPoint = self.convert(windowPoint, from: self.window)
        guard let node = self.viewTree.rootNode.hitTest(localPoint, with: event) else {
            return nil
        }

        self.inspectionLastHitTestNode = node
        return UIHitTestResult(
            windowId: self.uiInspectionWindowId,
            point: windowPoint,
            node: node.uiSnapshot(focusedNode: self.focusManager.focusedNode),
            path: node.uiPathFromRoot(focusedNode: self.focusManager.focusedNode)
        )
    }

    public func uiLayoutDiagnostics(matching selector: UINodeSelector?, subtreeDepth: Int?) throws -> UILayoutDiagnostics {
        self.layoutIfNeeded()
        let targetNode = try selector.map { try self.resolveUniqueNode(matching: $0) }
        let focusedNode = self.focusManager.focusedNode
        let depth = subtreeDepth ?? 1

        return UILayoutDiagnostics(
            windowId: self.uiInspectionWindowId,
            viewportSize: self.frame.size,
            overlayMode: self.inspectionDebugOverlayMode,
            focusedNode: focusedNode?.uiSummary(focusedNode: focusedNode),
            target: targetNode?.uiSnapshot(focusedNode: focusedNode, maxDepth: 1),
            parentPath: targetNode?.uiParentPath(focusedNode: focusedNode) ?? [],
            children: targetNode?.uiChildren().map { $0.uiSummary(focusedNode: focusedNode) } ?? [],
            hasScrollContainer: targetNode?.uiNearestScrollContainer() != nil,
            textInputFocused: focusedNode is TextFieldViewNode,
            subtree: targetNode?.uiSnapshot(focusedNode: focusedNode, maxDepth: depth)
        )
    }

    public func uiSetDebugOverlay(_ mode: UIDebugOverlayMode) {
        if self.inspectionDebugOverlayMode != .redraw, mode == .redraw {
            self.inspectionRedrawBaselineRevision = ViewNode.currentInspectionRedrawRevision()
        }

        self.inspectionDebugOverlayMode = mode
        self.setNeedsLayout()
        self.setNeedsDisplay()
    }

    public func uiFocusNode(matching selector: UINodeSelector) throws -> UIActionResult {
        let resolvedNode = try self.resolveUniqueNode(matching: selector)
        guard let focusableNode = resolvedNode.uiFocusableAncestor() else {
            throw UIInspectionError.noFocusableNode(selector.externalValue)
        }

        self.focusManager.focus(focusableNode)
        return self.makeActionResult(action: "focus_node", target: focusableNode)
    }

    public func uiFocusNext() -> UIActionResult? {
        self.focusManager.focusNext()
        guard let focusedNode = self.focusManager.focusedNode else {
            return nil
        }
        return self.makeActionResult(action: "focus_next", target: focusedNode)
    }

    public func uiFocusPrevious() -> UIActionResult? {
        self.focusManager.focusPrevious()
        guard let focusedNode = self.focusManager.focusedNode else {
            return nil
        }
        return self.makeActionResult(action: "focus_previous", target: focusedNode)
    }

    public func uiScrollToNode(matching selector: UINodeSelector) throws -> UIActionResult {
        let resolvedNode = try self.resolveUniqueNode(matching: selector)
        guard let scrollView = resolvedNode.uiNearestScrollContainer() else {
            throw UIInspectionError.scrollContainerNotFound(selector.externalValue)
        }

        guard scrollView.scrollToNodeIfDescendant(resolvedNode) else {
            throw UIInspectionError.scrollContainerNotFound(selector.externalValue)
        }

        return self.makeActionResult(action: "scroll_to_node", target: resolvedNode)
    }

    public func uiTapNode(matching selector: UINodeSelector) throws -> UIActionResult {
        let resolvedNode = try self.resolveUniqueNode(matching: selector)
        let renderedFrame = resolvedNode.uiRenderedAbsoluteFrame()
        let localCenter = Point(x: renderedFrame.midX, y: renderedFrame.midY)
        let windowPoint = self.convert(localCenter, to: self.window)
        let began = self.makeInspectionMouseEvent(at: windowPoint, phase: .began)
        let ended = self.makeInspectionMouseEvent(at: windowPoint, phase: .ended)

        self.onMouseEvent(began)
        self.onMouseEvent(ended)

        return self.makeActionResult(action: "tap_node", target: resolvedNode)
    }

    private func resolveNodes(matching selector: UINodeSelector) -> [ViewNode] {
        switch selector {
        case let .accessibilityIdentifier(identifier):
            self.viewTree.rootNode.contentNode.uiCollectNodes { $0.accessibilityIdentifier == identifier }
        case let .runtimeID(runtimeID):
            self.viewTree.rootNode.contentNode.uiCollectNodes { $0.uiRuntimeID == runtimeID }
        }
    }

    private func resolveUniqueNode(matching selector: UINodeSelector) throws -> ViewNode {
        let matches = self.resolveNodes(matching: selector)
        guard let first = matches.first else {
            throw UIInspectionError.nodeNotFound(selector.externalValue)
        }
        guard matches.count == 1 else {
            throw UIInspectionError.ambiguousSelector(
                selector.externalValue,
                matches.map { $0.uiSummary(focusedNode: self.focusManager.focusedNode) }
            )
        }
        return first
    }

    private func makeActionResult(action: String, target: ViewNode?) -> UIActionResult {
        let focusedNode = self.focusManager.focusedNode
        return UIActionResult(
            action: action,
            windowId: self.uiInspectionWindowId,
            target: target?.uiSnapshot(focusedNode: focusedNode, maxDepth: 1),
            focusedNode: focusedNode?.uiSummary(focusedNode: focusedNode),
            overlayMode: self.inspectionDebugOverlayMode,
            viewportSize: self.frame.size
        )
    }

    private func makeInspectionMouseEvent(at point: Point, phase: MouseEvent.Phase) -> MouseEvent {
        MouseEvent(
            window: self.window?.id ?? .empty,
            button: .left,
            mousePosition: point,
            phase: phase,
            modifierKeys: [],
            time: Float(Date().timeIntervalSinceReferenceDate)
        )
    }
}

extension ViewNode {
    var uiRuntimeID: String {
        let rawValue = UInt(bitPattern: self.id)
        return String(rawValue, radix: 16, uppercase: false)
    }

    func uiSummary(focusedNode: ViewNode?) -> UINodeSummary {
        let absoluteFrame = self.uiRenderedAbsoluteFrame()
        let center = Point(x: self.frame.width * 0.5, y: self.frame.height * 0.5)
        let syntheticEvent = MouseEvent(
            window: self.owner?.window?.id ?? .empty,
            button: .left,
            mousePosition: Point(x: absoluteFrame.midX, y: absoluteFrame.midY),
            phase: .began,
            modifierKeys: [],
            time: 0
        )

        return UINodeSummary(
            runtimeId: self.uiRuntimeID,
            accessibilityIdentifier: self.accessibilityIdentifier,
            nodeType: String(reflecting: type(of: self)),
            viewType: String(reflecting: type(of: self.content)),
            frame: self.frame,
            absoluteFrame: absoluteFrame,
            canBecomeFocused: self.canBecomeFocused,
            isFocused: self === focusedNode,
            isHidden: nil,
            isInteractable: self.environment.isEnabled && self.hitTest(center, with: syntheticEvent) != nil
        )
    }

    func uiRenderedAbsoluteFrame() -> Rect {
        var origin = self.frame.origin
        var currentParent = self.parent

        while let parent = currentParent {
            origin += parent.frame.origin
            if let scrollView = parent as? ScrollViewNode {
                origin.x -= scrollView.contentOffset.x
                origin.y -= scrollView.contentOffset.y
            }
            currentParent = parent.parent
        }

        return Rect(origin: origin, size: self.frame.size)
    }

    func uiSnapshot(focusedNode: ViewNode?, maxDepth: Int? = nil) -> UINodeSnapshot {
        let nextDepth = maxDepth.map { max($0 - 1, 0) }
        let childSnapshots: [UINodeSnapshot]
        if let maxDepth, maxDepth == 0 {
            childSnapshots = []
        } else {
            childSnapshots = self.uiChildren().map { $0.uiSnapshot(focusedNode: focusedNode, maxDepth: nextDepth) }
        }

        let summary = self.uiSummary(focusedNode: focusedNode)
        return UINodeSnapshot(
            runtimeId: summary.runtimeId,
            accessibilityIdentifier: summary.accessibilityIdentifier,
            nodeType: summary.nodeType,
            viewType: summary.viewType,
            frame: summary.frame,
            absoluteFrame: summary.absoluteFrame,
            canBecomeFocused: summary.canBecomeFocused,
            isFocused: summary.isFocused,
            isHidden: summary.isHidden,
            isInteractable: summary.isInteractable,
            parent: self.parent?.uiSummary(focusedNode: focusedNode),
            children: childSnapshots,
            sceneNodeID: self.uiSceneNodeID
        )
    }

    func uiChildren() -> [ViewNode] {
        if let rootNode = self as? ViewRootNode {
            return [rootNode.contentNode]
        }
        if let navigationStack = self as? NavigationStackNode {
            return navigationStack.inspectionChildNodes
        }
        if let navigationBar = self as? NavigationBarNode {
            return navigationBar.inspectionChildNodes
        }
        if let cover = self as? FullScreenCoverNode {
            return cover.inspectionChildNodes
        }
        if let container = self as? ViewContainerNode {
            return container.nodes
        }
        if let modifier = self as? ViewModifierNode {
            return [modifier.contentNode]
        }
        return []
    }

    func uiCollectNodes(where predicate: (ViewNode) -> Bool) -> [ViewNode] {
        var result: [ViewNode] = []
        if predicate(self) {
            result.append(self)
        }
        for child in self.uiChildren() {
            result.append(contentsOf: child.uiCollectNodes(where: predicate))
        }
        return result
    }

    func uiPathFromRoot(focusedNode: ViewNode?) -> [UINodeSummary] {
        var path: [UINodeSummary] = []
        var current: ViewNode? = self
        while let node = current {
            path.append(node.uiSummary(focusedNode: focusedNode))
            current = node.parent
        }
        return path.reversed()
    }

    func uiParentPath(focusedNode: ViewNode?) -> [UINodeSummary] {
        var path: [UINodeSummary] = []
        var current = self.parent
        while let node = current {
            path.append(node.uiSummary(focusedNode: focusedNode))
            current = node.parent
        }
        return path.reversed()
    }

    func uiFocusableAncestor() -> ViewNode? {
        var current: ViewNode? = self
        while let node = current {
            if node.canBecomeFocused {
                return node
            }
            current = node.parent
        }
        return nil
    }

    func uiNearestScrollContainer() -> ScrollViewNode? {
        var current: ViewNode? = self
        while let node = current {
            if let scrollView = node as? ScrollViewNode {
                return scrollView
            }
            current = node.parent
        }
        return nil
    }
}
