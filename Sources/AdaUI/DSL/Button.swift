//
//  Button.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 01.07.2024.
//

import AdaInput
import AdaUtils
import Math

/// A control that initiates an action.
public struct Button: View, ViewNodeBuilder {
    /// A state of the button.
    public struct State: OptionSet, Hashable, Sendable {
        public let rawValue: UInt

        /// Initialize a new state.
        ///
        /// - Parameter rawValue: The raw value of the state.
        public init(rawValue: UInt) {
            self.rawValue = rawValue
        }

        /// A Boolean value indicating whether the control is in the enabled state.
        public var isEnabled: Bool {
            !self.contains(.disabled)
        }

        /// A Boolean value indicating whether the control is in the selected state.
        public var isSelected: Bool {
            self.contains(.selected)
        }

        /// A Boolean value indicating whether the control draws a highlight.
        public var isHighlighted: Bool {
            self.contains(.highlighted)
        }

        /// The normal state.
        public static let normal = Self(rawValue: 1 << 0)

        /// The disabled state.
        public static let disabled = Self(rawValue: 1 << 1)

        /// The highlighted state.
        public static let highlighted = Self(rawValue: 1 << 2)

        /// The focused state.
        public static let focused = Self(rawValue: 1 << 3)

        /// The selected state.
        public static let selected = Self(rawValue: 1 << 4)
    }

    /// The body of the button.
    public typealias Body = Never
    public var body: Never { fatalError("Unreachable code") }

    /// The action of the button.
    let action: () -> Void
    let label: ButtonStyleConfiguration.Label.Storage
    let role: ButtonRole?
    let alertTitle: String?

    /// Initialize a new button.
    ///
    /// - Parameter action: The action of the button.
    /// - Parameter label: The label of the button.
    @MainActor
    public init<Label: View>(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.init(role: nil, action: action, label: label)
    }

    /// Initialize a new button.
    ///
    /// - Parameter role: The semantic role of the button.
    /// - Parameter action: The action of the button.
    /// - Parameter label: The label of the button.
    @MainActor
    public init<Label: View>(role: ButtonRole?, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action
        let label = label()
        self.label = .makeView({ Label._makeView(_ViewGraphNode(value: label), inputs: $0) })
        self.role = role
        self.alertTitle = (label as? Text)?.plainText
    }

    /// Initialize a new button.
    ///
    /// - Parameter text: The text of the button.
    /// - Parameter action: The action of the button.
    @MainActor
    public init(_ text: String, action: @escaping () -> Void) {
        self.init(text, role: nil, action: action)
    }

    /// Initialize a new button.
    ///
    /// - Parameter text: The text of the button.
    /// - Parameter role: The semantic role of the button.
    /// - Parameter action: The action of the button.
    @MainActor
    public init(_ text: String, role: ButtonRole?, action: @escaping () -> Void) {
        self.action = action
        self.label = .makeView({ Text._makeView(_ViewGraphNode(value: Text(text)), inputs: $0) })
        self.role = role
        self.alertTitle = text
    }

    // MARK: - ViewNodeBuilder

    func buildViewNode(in context: BuildContext) -> ViewNode {
        ButtonViewNode(
            content: self,
            label: label,
            viewInputs: context,
            action: self.action
        )
    }
}

/// The semantic role of a button.
public struct ButtonRole: Equatable, Hashable, Sendable {
    enum Storage: Equatable, Hashable, Sendable {
        case cancel
        case destructive
    }

    let storage: Storage

    /// A role that indicates the button cancels the current operation.
    public static let cancel = Self(storage: .cancel)

    /// A role that indicates the button performs a destructive action.
    public static let destructive = Self(storage: .destructive)
}

final class ButtonViewNode: ViewModifierNode {
    private(set) var action: () -> Void
    private var body: (Button.State, EnvironmentValues) -> StyledButtonContent

    private var state: Button.State = .normal
    private var touchStartLocation: Point?
    private var didMoveOutsideTapSlop = false
    private weak var activeTouchScrollView: ScrollViewNode?

    private static let tapMovementToleranceSquared: Float = 100

    init<Content: View>(content: Content, label: ButtonStyleConfiguration.Label.Storage, viewInputs: _ViewInputs, action: @escaping () -> Void) {
        self.action = action
        self.body = { state, environment in
            Self.makeStyledContent(
                state: state,
                environment: environment,
                label: label,
                viewInputs: viewInputs
            )
        }

        let initialContent = body(.normal, viewInputs.environment)
        super.init(contentNode: initialContent.node, content: content)
        self.registerStyleStorages(initialContent.styleStorages)
        self.updateEnvironment(viewInputs.environment)
    }

    override func invalidateContent() {
        self.reconcileContentNode()
        self.performLayout()
        owner?.containerView?.setNeedsDisplay(in: absoluteFrame())
    }

    override func performLayout() {
        let proposal = ProposedViewSize(self.frame.size)

        self.contentNode.place(
            in: .zero,
            anchor: .zero,
            proposal: proposal
        )
    }

    override func update(from newNode: ViewNode) {
        guard let otherNode = newNode as? ButtonViewNode else {
            return
        }

        self.action = otherNode.action
        self.body = otherNode.body
        super.update(from: otherNode)
        self.reconcileContentNode()
        self.performLayout()
        owner?.containerView?.setNeedsDisplay(in: absoluteFrame())
    }

    override var canBecomeFocused: Bool {
        self.state.isEnabled && self.environment.isEnabled
    }

    override func onFocusChanged(isFocused: Bool) {
        let previousState = state
        if isFocused {
            state.insert(.focused)
        } else {
            state.remove(.focused)
        }
        self.invalidateContentIfStateChanged(from: previousState)
    }

    // MARK: - Interaction

    override func hitTest(_ point: Point, with event: any InputEvent) -> ViewNode? {
        guard self.point(inside: point, with: event) else {
            return nil
        }
        return self
    }

    override func onMouseEvent(_ event: MouseEvent) {
        if !self.state.isEnabled || !self.environment.isEnabled {
            return
        }

        let previousState = state
        switch event.phase {
        case .began,
            .changed:
            state.insert(.highlighted)

            switch event.button {
            case .left:
                state.insert(.selected)
                state.remove(.highlighted)
            default:
                break
            }
        case .ended:
            let shouldInvokeAction = event.button == .left && state.contains(.selected)
            state.remove(.selected)
            state.remove(.highlighted)

            if shouldInvokeAction {
                self.action()
            }
        case .cancelled:
            state.remove(.selected)
            state.remove(.highlighted)
        }

        self.invalidateContentIfStateChanged(from: previousState)
    }

    override func onMouseLeave() {
        let previousState = state
        state.remove(.selected)
        state.remove(.highlighted)
        self.invalidateContentIfStateChanged(from: previousState)
    }

    override func onTouchesEvent(_ touches: Set<TouchEvent>) {
        guard self.state.isEnabled && self.environment.isEnabled else {
            return
        }
        guard let touch = touches.first else {
            return
        }

        let previousState = state
        switch touch.phase {
        case .began:
            touchStartLocation = touch.location
            didMoveOutsideTapSlop = false
            activeTouchScrollView = nearestScrollView()
            activeTouchScrollView?.onTouchesEvent(touches)
            state.insert(.highlighted)
            state.insert(.selected)
        case .moved:
            activeTouchScrollView?.onTouchesEvent(touches)
            if let touchStartLocation {
                let dx = touch.location.x - touchStartLocation.x
                let dy = touch.location.y - touchStartLocation.y
                if dx * dx + dy * dy > Self.tapMovementToleranceSquared {
                    didMoveOutsideTapSlop = true
                    state.remove(.selected)
                    state.remove(.highlighted)
                }
            }
        case .ended:
            activeTouchScrollView?.onTouchesEvent(touches)
            let shouldInvokeAction = state.contains(.selected) && !didMoveOutsideTapSlop
            state.remove(.selected)
            state.remove(.highlighted)
            touchStartLocation = nil
            didMoveOutsideTapSlop = false
            activeTouchScrollView = nil
            if shouldInvokeAction {
                self.action()
            }
        case .cancelled:
            activeTouchScrollView?.onTouchesEvent(touches)
            state.remove(.selected)
            state.remove(.highlighted)
            touchStartLocation = nil
            didMoveOutsideTapSlop = false
            activeTouchScrollView = nil
        }

        self.invalidateContentIfStateChanged(from: previousState)
    }

    /// Invoked by ``keyboardShortcut`` when this button is the first enabled button in the subtree.
    func performPrimaryActionForShortcut() {
        guard self.canBecomeFocused else {
            return
        }
        self.action()
    }

    private func nearestScrollView() -> ScrollViewNode? {
        var current = self.parent
        while let node = current {
            if let scrollView = node as? ScrollViewNode {
                return scrollView
            }
            current = node.parent
        }
        return nil
    }

    private func invalidateContentIfStateChanged(from previousState: Button.State) {
        guard state != previousState else {
            return
        }
        self.invalidateContent()
    }

    private func reconcileContentNode() {
        let newContent = self.body(self.state, self.environment)
        self.registerStyleStorages(newContent.styleStorages)

        if newContent.node.canUpdate(contentNode) {
            contentNode.update(from: newContent.node)
        } else {
            contentNode.parent = nil
            contentNode = newContent.node
            contentNode.parent = self
        }

        contentNode.updateEnvironment(self.environment)
        if let owner, contentNode.owner !== owner {
            contentNode.updateViewOwner(owner)
        }
    }

    private func registerStyleStorages(_ storages: [PropertyStoragable]) {
        for storage in storages {
            storage.storage.registerNodeToUpdate(self)
        }
    }

    private static func makeStyledContent(
        state: Button.State,
        environment: EnvironmentValues,
        label: ButtonStyleConfiguration.Label.Storage,
        viewInputs: _ViewInputs
    ) -> StyledButtonContent {
        let configuration = ButtonStyleConfiguration(
            label: ButtonStyleConfiguration.Label(storage: label),
            state: state
        )

        var baseInputs = viewInputs
        baseInputs.environment = environment

        // ButtonStyle is not itself the rendered content node. Subscribe the button
        // node to the style's @Environment storages so environment changes rebuild
        // makeBody(configuration:) instead of only invalidating the already-built body.
        let styledInputs = baseInputs.resolveStorages(in: environment.buttonStyle)
        let styleStorages = Array(styledInputs.propertyStorages.dropFirst(baseInputs.propertyStorages.count))

        let body = AnyView(environment.buttonStyle.makeBody(configuration: configuration))
        let node = AnyButtonStyle.Body._makeView(_ViewGraphNode(value: body), inputs: baseInputs).node
        return StyledButtonContent(node: node, styleStorages: styleStorages)
    }
}

private struct StyledButtonContent {
    let node: ViewNode
    let styleStorages: [PropertyStoragable]
}
