extension World {
    /// Stores metadata and registered factories only, never constructed component values.
    struct SpawnPlan: Sendable {
        let inputIDs: [ComponentId]
        let registeredRequirements: [[ComponentsStorage.RequiredComponentInfo]]
        let outputIDs: [ComponentId]
        let layout: ComponentLayout
        let archetypeIndex: Archetype.ID

        func matches(_ components: borrowing [any Component]) -> Bool {
            guard inputIDs.count == components.count else {
                return false
            }
            for index in components.indices where componentIdentifier(of: components[index]) != inputIDs[index] {
                return false
            }
            return true
        }
    }

    /// Shares the world's existing externally synchronized mutation contract.
    /// The recent plan avoids allocating/hashing a signature for repeated bundles.
    struct SpawnPlanCache: Sendable {
        private var plans: [[ComponentId]: SpawnPlan] = [:]
        private var recent: SpawnPlan?
        private(set) var revision: UInt64 = 0

        mutating func lookup(_ components: borrowing [any Component]) -> SpawnPlan? {
            if let recent, recent.matches(components) {
                return recent
            }
            let key = components.map { componentIdentifier(of: $0) }
            let plan = plans[key]
            recent = plan
            return plan
        }

        mutating func store(_ plan: consuming SpawnPlan) {
            // Bound extra metadata even when runtime input signatures churn.
            if plans[plan.inputIDs] == nil && plans.count >= 256 {
                plans.removeAll(keepingCapacity: true)
            }
            plans[plan.inputIDs] = plan
            recent = consume plan
        }

        mutating func invalidate() {
            revision &+= 1
            plans.removeAll(keepingCapacity: true)
            recent = nil
        }
    }
}
