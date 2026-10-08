//
//  NavigationLink.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 25.03.2026.
//

import AdaInput
import AdaUtils
import Math

/// A view that controls a navigation presentation.
///
/// Create a navigation link by providing a destination value and a label.
/// When the user taps or clicks the link, AdaUI pushes the value onto the
/// nearest ``NavigationStack``'s path.
///
/// ```swift
/// NavigationLink(value: "detail") {
///     Text("Go to Detail")
/// }
/// ```
@MainActor @preconcurrency
public struct NavigationLink<Label: View>: View, ViewNodeBuilder {
    public typealias Body = Never
    public var body: Never { fatalError("Unreachable code") }

    let value: AnyHashable
    let label: () -> Label

    /// Creates a navigation link with a hashable value and a view builder label.
    public init<V: Hashable>(value: V, @ViewBuilder label: @escaping () -> Label) {
        self.value = AnyHashable(value)
        self.label = label
    }

    func buildViewNode(in context: BuildContext) -> ViewNode {
        let labelView = label()
        let labelNode = Label._makeView(_ViewGraphNode(value: labelView), inputs: context).node
        return NavigationLinkNode(labelNode: labelNode, value: value, navLink: self)
    }
}

// MARK: - NavigationLinkNode

final class NavigationLinkNode: ViewModifierNode {
    private let value: AnyHashable
    private var isHighlighted: Bool = false

    init<Label: View>(labelNode: ViewNode, value: AnyHashable, navLink: NavigationLink<Label>) {
        self.value = value
        super.init(contentNode: labelNode, content: navLink)
    }

    override func hitTest(_ point: Point, with event: any InputEvent) -> ViewNode? {
        guard self.point(inside: point, with: event) else {
            return nil
        }
        return self
    }

    override func onMouseEvent(_ event: MouseEvent) {
        guard environment.isEnabled else {
            return
        }

        switch event.phase {
        case .began,
            .changed:
            if event.button == .left {
                isHighlighted = true
            }
        case .ended:
            let wasHighlighted = isHighlighted
            isHighlighted = false
            if wasHighlighted && event.button == .left {
                navigate()
            }
        case .cancelled:
            isHighlighted = false
        }

        requestDisplay()
    }

    override func onMouseLeave() {
        isHighlighted = false
        requestDisplay()
    }

    override func onTouchesEvent(_ touches: Set<TouchEvent>) {
        guard environment.isEnabled else {
            return
        }
        guard let touch = touches.first else {
            return
        }

        switch touch.phase {
        case .began:
            isHighlighted = true
        case .moved:
            break
        case .ended:
            let wasHighlighted = isHighlighted
            isHighlighted = false
            if wasHighlighted {
                navigate()
            }
        case .cancelled:
            isHighlighted = false
        }

        requestDisplay()
    }

    private func navigate() {
        if environment.navigationSplitColumnContext?.navigate(value) == true {
            return
        }
        environment.navigationContext?.push(value)
    }

    private func requestDisplay() {
        invalidateNearestLayer()
        owner?.containerView?.setNeedsDisplay(in: absoluteFrame())
    }
}
