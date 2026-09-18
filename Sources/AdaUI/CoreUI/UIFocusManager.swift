//
//  UIFocusManager.swift
//  AdaEngine
//
//  Created by vladislav.prusakov on 30.07.2024.
//

@MainActor
final class UIFocusManager {
    private weak var rootNode: ViewNode?
    private(set) var focusedNode: ViewNode?

    init(rootNode: ViewNode? = nil) {
        self.rootNode = rootNode
    }

    func setRootNode(_ node: ViewNode) {
        self.rootNode = node
    }

    func focus(_ node: ViewNode?) {
        guard focusedNode !== node else {
            return
        }

        focusedNode?.onFocusChanged(isFocused: false)
        focusedNode = node
        focusedNode?.onFocusChanged(isFocused: true)
    }

    func focusNext() {
        advanceFocus(forward: true)
    }

    func focusPrevious() {
        advanceFocus(forward: false)
    }

    private func advanceFocus(forward: Bool) {
        guard let root = rootNode else {
            return
        }

        var focusableNodes: [ViewNode] = []
        collectFocusableNodes(from: root, into: &focusableNodes)

        guard !focusableNodes.isEmpty else {
            return
        }

        let currentIndex = focusableNodes.firstIndex(where: { $0 === focusedNode })

        let nextIndex: Int
        if let currentIndex {
            if forward {
                nextIndex = (currentIndex + 1) % focusableNodes.count
            } else {
                nextIndex = (currentIndex - 1 + focusableNodes.count) % focusableNodes.count
            }
        } else {
            nextIndex = forward ? 0 : focusableNodes.count - 1
        }

        focus(focusableNodes[nextIndex])
    }

    private func collectFocusableNodes(from node: ViewNode, into result: inout [ViewNode]) {
        if node.canBecomeFocused {
            result.append(node)
        }

        if let rootNode = node as? ViewRootNode {
            collectFocusableNodes(from: rootNode.contentNode, into: &result)
        } else if let container = node as? ViewContainerNode {
            for child in container.nodes {
                collectFocusableNodes(from: child, into: &result)
            }
        } else if let modifier = node as? ViewModifierNode {
            collectFocusableNodes(from: modifier.contentNode, into: &result)
        }
    }
}
