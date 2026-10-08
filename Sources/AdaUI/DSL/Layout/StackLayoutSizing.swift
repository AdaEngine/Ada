//
//  StackLayoutSizing.swift
//  AdaEngine
//
//  Created by OpenAI on 29.04.2026.
//

@MainActor
func stackAssignedMainAxisSizes(
    idealSizes: [Float],
    minSizes: [Float],
    maxSizes: [Float],
    layoutPriorities: [Double],
    flexibleIndices: [Int],
    availableSpace: Float
) -> [Float] {
    guard !flexibleIndices.isEmpty else {
        return idealSizes
    }

    if availableSpace > 0 {
        return adjustedMainAxisSizes(
            idealSizes: idealSizes,
            limitSizes: maxSizes,
            layoutPriorities: layoutPriorities,
            flexibleIndices: flexibleIndices,
            amount: availableSpace,
            priorities: uniquePriorities(for: flexibleIndices, layoutPriorities: layoutPriorities, descending: true),
            operation: +
        )
    }

    if availableSpace < 0 {
        return adjustedMainAxisSizes(
            idealSizes: idealSizes,
            limitSizes: minSizes,
            layoutPriorities: layoutPriorities,
            flexibleIndices: flexibleIndices,
            amount: -availableSpace,
            priorities: uniquePriorities(for: flexibleIndices, layoutPriorities: layoutPriorities, descending: false),
            operation: -
        )
    }

    return idealSizes
}

@MainActor
func equalizedSpacerMainAxisSizes(
    idealSizes: [Float],
    maxSizes: [Float],
    spacerIndices: [Int],
    availableSpace: Float
) -> [Float]? {
    guard availableSpace > 0, !spacerIndices.isEmpty else {
        return nil
    }

    var sizes = idealSizes
    var activeIndices = spacerIndices
    var remaining = availableSpace
    let epsilon: Float = 0.0001

    while remaining > epsilon && !activeIndices.isEmpty {
        let activeCurrentTotal = activeIndices.reduce(Float.zero) { $0 + sizes[$1] }
        let target = (activeCurrentTotal + remaining) / Float(activeIndices.count)
        var nextActiveIndices: [Int] = []
        var used: Float = 0

        for index in activeIndices {
            let limit = maxSizes[index]
            let desired = max(target, sizes[index])
            let capped = limit.isFinite ? min(desired, limit) : desired
            let delta = max(capped - sizes[index], 0)
            sizes[index] += delta
            used += delta

            if !limit.isFinite || limit - sizes[index] > epsilon {
                nextActiveIndices.append(index)
            }
        }

        guard used > epsilon else {
            break
        }

        remaining -= used
        activeIndices = nextActiveIndices
    }

    return sizes
}

@MainActor
private func adjustedMainAxisSizes(
    idealSizes: [Float],
    limitSizes: [Float],
    layoutPriorities: [Double],
    flexibleIndices: [Int],
    amount: Float,
    priorities: [Double],
    operation: (Float, Float) -> Float
) -> [Float] {
    var sizes = idealSizes
    var remaining = amount
    let epsilon: Float = 0.0001

    for priority in priorities {
        var activeIndices = flexibleIndices.filter { layoutPriorities[$0] == priority }

        while remaining > epsilon && !activeIndices.isEmpty {
            let slot = remaining / Float(activeIndices.count)
            var nextActiveIndices: [Int] = []
            var used: Float = 0

            for index in activeIndices {
                let capacity = adjustmentCapacity(
                    current: sizes[index],
                    limit: limitSizes[index],
                    remaining: remaining,
                    operation: operation
                )
                let delta = min(slot, capacity)
                sizes[index] = operation(sizes[index], delta)
                used += delta

                if capacity - delta > epsilon {
                    nextActiveIndices.append(index)
                }
            }

            guard used > epsilon else {
                break
            }

            remaining -= used
            activeIndices = nextActiveIndices
        }

        if remaining <= epsilon {
            break
        }
    }

    return sizes
}

@MainActor
private func adjustmentCapacity(
    current: Float,
    limit: Float,
    remaining: Float,
    operation: (Float, Float) -> Float
) -> Float {
    let grows = operation(current, 1) > current
    if grows {
        guard limit.isFinite else {
            return remaining
        }

        return max(limit - current, 0)
    }

    let lowerLimit = limit.isFinite ? limit : 0
    return max(current - lowerLimit, 0)
}

private func uniquePriorities(
    for indices: [Int],
    layoutPriorities: [Double],
    descending: Bool
) -> [Double] {
    let priorities = Set(indices.map { layoutPriorities[$0] })
    return priorities.sorted { lhs, rhs in
        descending ? lhs > rhs : lhs < rhs
    }
}
