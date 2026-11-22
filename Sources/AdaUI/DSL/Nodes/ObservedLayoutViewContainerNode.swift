import Math
import Observation

/// Custom layouts may read observable geometry without rebuilding their content.
final class ObservedLayoutViewContainerNode: LayoutViewContainerNode {
    var geometryInvalidation: LayoutInvalidation? {
        didSet {
            if oldValue?.node === self {
                oldValue?.node = nil
            }
            if owner != nil, parent != nil {
                geometryInvalidation?.node = self
            }
        }
    }
    private var measurementRevision: UInt64 = 0
    private var placementRevision: UInt64 = 0
    private var deferredTransaction: DeferredViewTransaction?
    private var hasGeometryInvalidation = false

    // A custom layout can report its own target size, just like a fixed frame.
    // Preserve its interpolation when an animated ancestor lays it out again.
    override var allowsNestedFrameAnimation: Bool { true }

    override func updateViewOwner(_ owner: ViewOwner) {
        super.updateViewOwner(owner)
        if parent != nil {
            geometryInvalidation?.node = self
        }
    }

    override func didMove(to parent: ViewNode?) {
        super.didMove(to: parent)
        if parent == nil, geometryInvalidation?.node === self {
            geometryInvalidation?.node = nil
        } else if parent != nil, owner != nil {
            geometryInvalidation?.node = self
        }
    }

    override func update(from newNode: ViewNode) {
        if let node = newNode as? ObservedLayoutViewContainerNode {
            geometryInvalidation = node.geometryInvalidation
        }
        super.update(from: newNode)
    }

    func invalidateGeometry() {
        hasGeometryInvalidation = true
        scheduleLayout()
    }

    private func scheduleLayout() {
        markNeedsLayout()
        invalidateNearestLayer()
        owner?.containerView?.setNeedsLayout()
    }

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
        let updatesGeometry = hasGeometryInvalidation
        hasGeometryInvalidation = false
        if let transaction = deferredTransaction {
            deferredTransaction = nil
            transaction.perform(on: self) { performObservedLayout() }
        } else if updatesGeometry, let controller = environment.animationController {
            Self.withoutInheritingFrameAnimation(from: controller) { performObservedLayout() }
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
                scheduleLayout()
            }
        }
    }
}
