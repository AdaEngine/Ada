import AdaAnimation
import Synchronization

/// Animation policy for a group of state updates. Unlike environment values, a transaction
/// is discarded when the update ends, and is captured by deferred observation work.
public struct Transaction: Sendable {
    public var animation: Animation?
    public var disablesAnimations = false

    public init(animation: Animation? = nil) {
        self.animation = animation
    }
}

enum UITransactionContext {
    private final class Scope: Sendable {
        let transaction: Transaction?
        let isActive = Mutex(true)
        init(_ transaction: Transaction?) { self.transaction = transaction }
    }

    @TaskLocal private static var scope: Scope?

    static var current: Transaction? {
        guard let scope, scope.isActive.withLock({ $0 }) else {
            return nil
        }
        return scope.transaction
    }

    static func withValue<Result>(_ transaction: Transaction?, operation: () throws -> Result) rethrows -> Result {
        let value = Scope(transaction)
        defer { value.isActive.withLock { $0 = false } }
        return try $scope.withValue(value, operation: operation)
    }
}

/// Performs state changes using the supplied animation policy.
/// State values change immediately; affected views rebuild once when the closure finishes.
@MainActor
public func withTransaction<Result>(_ transaction: Transaction, _ body: () throws -> Result) rethrows -> Result {
    try BindingAnimationTransaction.withTransaction(transaction, body)
}

extension View {
    /// Changes the transaction for updates in this subtree.
    public func transaction(_ transform: @escaping (inout Transaction) -> Void) -> some View {
        modifier(TransactionModifier(content: self, transform: transform))
    }
}

private struct TransactionModifier<Content: View>: ViewModifier, ViewNodeBuilder {
    typealias Body = Never
    let content: Content
    let transform: (inout Transaction) -> Void

    func buildViewNode(in context: BuildContext) -> ViewNode {
        TransactionViewNode(contentNode: context.makeNode(from: content), content: content, transform: transform)
    }
}

private final class TransactionViewNode: ViewModifierNode {
    var transformTransaction: (inout Transaction) -> Void

    init<Content: View>(contentNode: ViewNode, content: Content, transform: @escaping (inout Transaction) -> Void) {
        self.transformTransaction = transform
        super.init(contentNode: contentNode, content: content)
        transactionTransform = transform
    }

    override func update(from newNode: ViewNode) {
        guard let other = newNode as? TransactionViewNode else {
            return
        }
        transformTransaction = other.transformTransaction
        transactionTransform = transformTransaction
        var transaction = UITransactionContext.current ?? Transaction()
        transformTransaction(&transaction)
        withTransaction(transaction) {
            super.update(from: other)
            if let controller = BindingAnimationTransaction.currentController {
                owner?.addTransientAnimationController(controller)
            }
        }
    }
}

@MainActor
extension ViewNode {
    var animationControllerForUpdate: UIAnimationController? {
        guard !environment.animationsDisabled, UITransactionContext.current?.disablesAnimations != true else {
            return nil
        }
        return BindingAnimationTransaction.currentController
    }
}

@MainActor
extension ViewNode {
    /// State can invalidate a descendant without rebuilding its modifier ancestors.
    /// Apply those ancestor policies before rebuilding the affected subtree.
    func withAncestorTransaction(_ operation: () -> Void) {
        var transforms: [(inout Transaction) -> Void] = []
        var ancestor = parent
        while let node = ancestor {
            if let transform = node.transactionTransform { transforms.append(transform) }
            ancestor = node.parent
        }
        guard !transforms.isEmpty else {
            operation()
            return
        }
        var transaction = UITransactionContext.current ?? Transaction()
        for transform in transforms.reversed() { transform(&transaction) }
        withTransaction(transaction, operation)
    }
}
