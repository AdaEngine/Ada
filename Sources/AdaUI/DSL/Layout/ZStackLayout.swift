//
//  ZStackLayout.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 23.06.2024.
//

import AdaAnimation
import Math

public struct ZStackLayoutCache {
    var minSizes: [Size] = []
    var minSize: Size = .zero
    var onlyContainsInfiniteViews = false
}

public struct ZStackLayout: Layout {
    public typealias Cache = ZStackLayoutCache
    public typealias AnimatableData = EmptyAnimatableData

    let anchor: AnchorPoint

    public init(anchor: AnchorPoint = .center) {
        self.anchor = anchor
    }

    public func makeCache(subviews: Subviews) -> Cache {
        var cache = ZStackLayoutCache()
        self.updateCache(&cache, subviews: subviews)
        return cache
    }

    public func updateCache(_ cache: inout ZStackLayoutCache, subviews: Subviews) {
        cache = ZStackLayoutCache()

        for subview in subviews {
            let minSize = subview.sizeThatFits(.zero)

            cache.minSizes.append(minSize)
            cache.minSize.width = max(cache.minSize.width, minSize.width)
            cache.minSize.height = max(cache.minSize.height, minSize.height)
        }
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> Size {
        let idealSize = subviews.reduce(Size.zero) { partialResult, subview in
            let subviewSize = subview.sizeThatFits(proposal)

            var newSize = partialResult
            newSize.width = max(partialResult.width, subviewSize.width)
            newSize.height = max(partialResult.height, subviewSize.height)
            return newSize
        }

        return Size(
            width: max(idealSize.width, cache.minSize.width),
            height: max(idealSize.height, cache.minSize.height)
        )
    }

    public func placeSubviews(in bounds: Math.Rect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let origin = Point(
            x: bounds.minX + bounds.width * anchor.x,
            y: bounds.minY + bounds.height * anchor.y
        )

        for (index, subview) in subviews.enumerated() {
            let idealSize = subview.sizeThatFits(proposal)
            let minSize = cache.minSizes[index]

            let width = max(idealSize.width, minSize.width)
            let height = max(idealSize.height, minSize.height)

            let proposal = ProposedViewSize(width: width, height: height)
            subview.place(at: origin, anchor: anchor, proposal: proposal)
        }
    }
}
