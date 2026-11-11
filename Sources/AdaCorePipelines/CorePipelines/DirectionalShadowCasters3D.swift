import AdaUtils

/// The CPU caster lists share one partition across all directional cascades.
/// A caster that moves joins the dynamic list until its transform settles.
struct DirectionalShadowCasters3D: Sendable {
    private var frame: Int?
    private var usesGPU = false
    private var stableIndices: [Int] = []
    private var stableMembership: Set<Int> = []
    private var dynamicSlots: [Int: Int] = [:]
    private var settledAt: [Int: Int] = [:]
    private(set) var stable: [Mesh3DRenderSource] = []
    private(set) var dynamic: [Mesh3DRenderSource] = []
    private(set) var stableRevision = RID()

    /// Returns nil when the source list must use full preparation, and true
    /// when the retained lists need their source membership reconciled.
    mutating func update(
        sources: [Mesh3DRenderSource], cpuIndices: [Int]?, changes: [Int]?, frame nextFrame: Int
    ) -> Bool? {
        guard let changes else {
            if frame != nil { self = Self() }
            return nil
        }
        let nextUsesGPU = cpuIndices != nil
        if frame == nextFrame, usesGPU == nextUsesGPU {
            return false
        }
        let sequential = frame.map { $0 &+ 1 == nextFrame } == true && usesGPU == nextUsesGPU
        frame = nextFrame
        usesGPU = nextUsesGPU
        if !sequential {
            rebuild(sources: sources, cpuIndices: cpuIndices, changes: Set(changes))
            return true
        }

        var promoted = false
        for index in changes {
            if let slot = dynamicSlots[index] {
                dynamic[slot] = sources[index]
                if sources[index].previousTransform == sources[index].transform {
                    settledAt[index] = nextFrame
                } else {
                    settledAt.removeValue(forKey: index)
                }
            } else if stableMembership.remove(index) != nil {
                dynamicSlots[index] = dynamic.count
                dynamic.append(sources[index])
                promoted = true
            }
        }
        let retired = settledAt.compactMap { index, stopped in nextFrame &- stopped >= 8 ? index : nil }
        for index in retired {
            settledAt.removeValue(forKey: index)
            dynamicSlots.removeValue(forKey: index)
            stableMembership.insert(index)
            stableIndices.append(index)
        }
        if !retired.isEmpty {
            let remaining = dynamicSlots.keys.sorted()
            dynamic = remaining.map { sources[$0] }
            dynamicSlots = Dictionary(uniqueKeysWithValues: remaining.enumerated().map { ($0.element, $0.offset) })
            stableIndices.sort()
        }
        if promoted || !retired.isEmpty {
            stableIndices.removeAll { !stableMembership.contains($0) }
            stable = stableIndices.map { sources[$0] }
            stableRevision = RID()
        }
        return false
    }

    private mutating func rebuild(sources: [Mesh3DRenderSource], cpuIndices: [Int]?, changes: Set<Int>) {
        stableIndices.removeAll(keepingCapacity: true)
        dynamicSlots.removeAll(keepingCapacity: true)
        settledAt.removeAll(keepingCapacity: true)
        dynamic.removeAll(keepingCapacity: true)
        for index in cpuIndices ?? Array(sources.indices) where sources[index].castShadows {
            if changes.contains(index) || sources[index].previousTransform != sources[index].transform {
                dynamicSlots[index] = dynamic.count
                dynamic.append(sources[index])
                if sources[index].previousTransform == sources[index].transform, let frame {
                    settledAt[index] = frame
                }
            } else {
                stableIndices.append(index)
            }
        }
        stableMembership = Set(stableIndices)
        stable = stableIndices.map { sources[$0] }
        stableRevision = RID()
    }
}
