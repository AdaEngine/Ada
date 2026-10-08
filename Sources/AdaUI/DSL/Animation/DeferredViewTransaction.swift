/// Carries update policy across a deferred layout without extending the lifetime
/// of the synchronous transaction scope. Retains the original controller so an
/// implicit animation and its deferred descendants share one clock.
@MainActor
struct DeferredViewTransaction {
    let transaction: Transaction?
    let controller: UIAnimationController?

    init(for node: ViewNode) {
        transaction = UITransactionContext.current
        controller = node.animationControllerForUpdate
    }

    func schedule(on node: ViewNode) {
        if let controller { node.owner?.addTransientAnimationController(controller) }
    }

    func perform(on node: ViewNode, _ operation: () -> Void) {
        controller?.playAnimation()
        BindingAnimationTransaction.withController(controller, transaction: transaction) {
            node.performWithTransientAnimationController(controller, operation)
        }
        schedule(on: node)
    }
}
