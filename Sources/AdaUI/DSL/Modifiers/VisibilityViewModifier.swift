//
//  VisibilityViewModifier.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 24.06.2024.
//

import Math

extension View {
    /// Adds an action to perform before this view appears.
    /// - Parameter action: The action to perform. If action is nil, the call has no effect.
    public func onAppear(perform action: (() -> Void)? = nil) -> some View {
        self.modifier(OnAppearView(content: self, onAppear: action))
    }

    /// Adds an action to perform after this view disappears.
    /// - Parameter action: The action to perform. If action is nil, the call has no effect.
    public func onDisappear(perform action: (() -> Void)? = nil) -> some View {
        self.modifier(OnDisappearView(content: self, onDisappear: action))
    }

    /// Adds an asynchronous task to perform when this view appears.
    ///
    /// AdaUI starts the task after the view is attached to the view tree and cancels it
    /// when the view disappears.
    public func task(
        priority: TaskPriority = .userInitiated,
        _ action: @escaping @Sendable () async -> Void
    ) -> some View {
        self.modifier(TaskView(content: self, priority: priority, action: action))
    }
}

struct OnAppearView<Content: View>: ViewModifier, ViewNodeBuilder {
    typealias Body = Never

    let content: Content
    let onAppear: (() -> Void)?

    init(content: Content, onAppear: (() -> Void)? = nil) {
        self.content = content
        self.onAppear = onAppear
    }

    func buildViewNode(in context: BuildContext) -> ViewNode {
        let node = VisibilityViewNode(
            contentNode: context.makeNode(from: content),
            content: content
        )
        node.onAppear = self.onAppear
        return node
    }
}

struct OnDisappearView<Content: View>: ViewModifier, ViewNodeBuilder {
    typealias Body = Never

    let content: Content
    let onDisappear: (() -> Void)?

    func buildViewNode(in context: BuildContext) -> ViewNode {
        let node = VisibilityViewNode(
            contentNode: context.makeNode(from: content),
            content: content
        )
        node.onDisappear = self.onDisappear
        return node
    }
}

struct TaskView<Content: View>: ViewModifier, ViewNodeBuilder {
    typealias Body = Never

    let content: Content
    let priority: TaskPriority
    let action: @Sendable () async -> Void

    func buildViewNode(in context: BuildContext) -> ViewNode {
        let node = VisibilityViewNode(
            contentNode: context.makeNode(from: content),
            content: content
        )
        node.taskPriority = priority
        node.taskAction = action
        return node
    }
}

/// Handle visibility view on the screen.
final class VisibilityViewNode: ViewModifierNode {
    var onAppear: (() -> Void)?
    var onDisappear: (() -> Void)?
    var taskPriority: TaskPriority = .userInitiated
    var taskAction: (@Sendable () async -> Void)?

    private var isAppeared = false
    private var isAppearScheduled = false
    private var currentTask: Task<Void, Never>?

    deinit {
        currentTask?.cancel()
    }

    override func updateViewOwner(_ owner: ViewOwner) {
        super.updateViewOwner(owner)
        guard !isAppeared, !isAppearScheduled else {
            return
        }

        isAppearScheduled = true
        owner.enqueueLifecycleAction { [weak self] in
            guard let self, self.isAppearScheduled else {
                return
            }

            self.isAppearScheduled = false
            guard self.isAttachedToViewTree else {
                return
            }

            self.isAppeared = true
            self.startTask()
            self.onAppear?()
        }
    }

    override func didMove(to parent: ViewNode?) {
        if parent == nil {
            isAppearScheduled = false
        }

        if parent == nil, isAppeared {
            isAppeared = false
            cancelTask()
            let onDisappear = onDisappear
            owner?
                .enqueueLifecycleAction {
                    onDisappear?()
                }
        }
        super.didMove(to: parent)
    }

    override func update(from newNode: ViewNode) {
        super.update(from: newNode)
        guard let other = newNode as? VisibilityViewNode else {
            return
        }
        self.onAppear = other.onAppear
        self.onDisappear = other.onDisappear
        self.taskPriority = other.taskPriority
        self.taskAction = other.taskAction
    }

    private var isAttachedToViewTree: Bool {
        var node: ViewNode? = self
        while let currentNode = node {
            if currentNode is ViewRootNode {
                return true
            }

            node = currentNode.parent
        }

        return false
    }

    private func startTask() {
        guard let taskAction else {
            return
        }

        currentTask?.cancel()
        currentTask = Task(priority: taskPriority, operation: taskAction)
    }

    private func cancelTask() {
        currentTask?.cancel()
        currentTask = nil
    }
}
