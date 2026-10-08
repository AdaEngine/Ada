//
//  AnyLayout.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 23.06.2024.
//

import AdaAnimation
import Math

public struct AnyLayout: Layout {
    public typealias Cache = AnyCache
    public typealias AnimatableData = EmptyAnimatableData

    let layout: any Layout

    public struct AnyCache {
        @usableFromInline
        var value: Any
    }

    public init(erased layout: any Layout) {
        self.layout = layout
    }

    public init<L: Layout>(_ layout: L) {
        self.layout = layout
    }

    public func makeCache(subviews: Subviews) -> Cache {
        return Cache(value: self.layout.makeCache(subviews: subviews))
    }

    public func updateCache(_ cache: inout Cache, subviews: Subviews) {
        layout._updateCache(&cache, subviews: subviews)
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> Size {
        return layout._sizeThatFits(proposal, subviews: subviews, cache: &cache)
    }

    public func placeSubviews(in bounds: Math.Rect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        layout._placeSubviews(in: bounds, proposal: proposal, subviews: subviews, cache: &cache)
    }
}

// MARK: - AnyLayout

extension Layout {
    @inlinable
    func _sizeThatFits(_ proposal: ProposedViewSize, subviews: Subviews, cache: inout AnyLayout.Cache) -> Size {
        var layoutCache = cache.value as! Self.Cache
        let result = sizeThatFits(proposal, subviews: subviews, cache: &layoutCache)
        cache.value = layoutCache
        return result
    }

    @inlinable
    func _placeSubviews(in bounds: Rect, proposal: ProposedViewSize, subviews: Subviews, cache: inout AnyLayout.Cache) {
        var layoutCache = cache.value as! Self.Cache
        placeSubviews(in: bounds, proposal: proposal, subviews: subviews, cache: &layoutCache)
        cache.value = layoutCache
    }

    @inlinable
    func _updateCache(_ cache: inout AnyLayout.Cache, subviews: Subviews) {
        var layoutCache = cache.value as! Self.Cache
        updateCache(&layoutCache, subviews: subviews)
        cache.value = layoutCache
    }
}
