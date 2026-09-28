import Math
import Observation

/// Custom layouts may read observable geometry without rebuilding their content.
final class ObservedLayoutViewContainerNode: LayoutViewContainerNode {
    private var measurementRevision: UInt64 = 0
    private var placementRevision: UInt64 = 0
    private var deferredTransaction: DeferredViewTransaction?

    // A custom layout can report its own target size, just like a fixed frame.
    // Preserve its interpolation when an animated ancestor lays it out again.
    override var allowsNestedFrameAnimation: Bool { true }

    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        measurementRevision &+= 1
        let revision = measurementRevision
        return withObservationTracking {
            super.sizeThatFits(proposal)
        } onChange: { [weak self] in
            let transaction = UITransactionContext.current
            Task { @MainActor in
                guard let self, self.measurementRevision == revision else {
                    return
                }
                self.invalidateObservedLayout(transaction: transaction)
            }
        }
    }

    override func performLayout() {
        if let transaction = deferredTransaction {
            deferredTransaction = nil
            transaction.perform(on: self) { performObservedLayout() }
        } else {
            performObservedLayout()
        }
    }

    private func performObservedLayout() {
        placementRevision &+= 1
        let revision = placementRevision
        withObservationTracking {
            super.performLayout()
        } onChange: { [weak self] in
            let transaction = UITransactionContext.current
            Task { @MainActor in
                guard let self, self.placementRevision == revision else {
                    return
                }
                self.invalidateObservedLayout(transaction: transaction)
            }
        }
    }

    private func invalidateObservedLayout(transaction: Transaction?) {
        BindingAnimationTransaction.withTransaction(transaction) {
            withAncestorTransaction {
                let pending = DeferredViewTransaction(for: self)
                deferredTransaction = pending
                recordLayoutAnimation(pending.controller)
                pending.schedule(on: self)
                markNeedsLayout()
                invalidateNearestLayer()
                owner?.containerView?.setNeedsLayout()
            }
        }
    }
}
