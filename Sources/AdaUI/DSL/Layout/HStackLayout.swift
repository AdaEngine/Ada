//
//  HStackLayout.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 23.06.2024.
//

import AdaAnimation
import Math

public struct StackLayoutCache {
    var minSizes: [Size] = []
    var maxSizes: [Size] = []

    var minSize: Size = .zero
    var maxSize: Size = .zero

    var totalSubviewSpacing: Float = .zero
    var subviewSpacings: [Float] = []
}

public struct HStackLayout: Layout {
    public typealias AnimatableData = EmptyAnimatableData

    let alignment: VerticalAlignment
    let spacing: Float?

    public init(alignment: VerticalAlignment = .center, spacing: Float?) {
        self.alignment = alignment
        self.spacing = spacing
    }

    public typealias Cache = StackLayoutCache

    public static var layoutProperties: LayoutProperties = LayoutProperties(stackOrientation: .horizontal)

    public func makeCache(subviews: Subviews) -> Cache {
        var cache = StackLayoutCache()
        self.updateCache(&cache, subviews: subviews)
        return cache
    }

    public func updateCache(_ cache: inout StackLayoutCache, subviews: Subviews) {
        cache = StackLayoutCache()

        for (index, subview) in subviews.enumerated() {
            let minSize = subview.sizeThatFits(.zero)
            let maxSize = subview.sizeThatFits(.infinity)

            cache.minSizes.append(minSize)
            cache.minSize += minSize
            cache.maxSizes.append(maxSize)
            cache.maxSize += maxSize

            if index != 0 {
                let space = self.spacing ?? 8
                cache.totalSubviewSpacing += space
                cache.subviewSpacings.append(space)
            } else {
                cache.subviewSpacings.append(0)
            }
        }
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> Size {
        if proposal == .zero {
            let minHeight = cache.minSizes.reduce(Float.zero) { max($0, $1.height) }
            return Size(width: cache.minSize.width + cache.totalSubviewSpacing, height: minHeight)
        }

        let proposedHeight = finiteDimension(proposal.height)
        let idealSizes = subviews.enumerated()
            .map { index, subview in
                let measured = subview.sizeThatFits(ProposedViewSize(height: proposedHeight))
                return sanitized(size: measured, fallback: cache.minSizes[index])
            }
        let idealSize = idealSizes.reduce(Size.zero) { partialResult, subviewSize in
            Size(
                width: partialResult.width + subviewSize.width,
                height: max(partialResult.height, subviewSize.height)
            )
        }
        let hasFlexibleSubviews = (0..<subviews.count)
            .contains { index in
                isFlexibleSubview(index: index, cache: cache)
            }

        guard let proposedWidth = finiteDimension(proposal.width), hasFlexibleSubviews else {
            return Size(width: idealSize.width + cache.totalSubviewSpacing, height: idealSize.height)
        }

        let minimumContentWidth = subviews.enumerated()
            .reduce(Float.zero) { partialResult, element in
                let (index, subview) = element
                return partialResult
                    + min(
                        compressionMinWidth(index: index, subview: subview, cache: cache),
                        idealSizes[index].width
                    )
            }
        let proposedContentWidth = max(proposedWidth - cache.totalSubviewSpacing, 0)
        let width = min(max(proposedContentWidth, minimumContentWidth), cache.maxSize.width)

        return Size(
            width: width + cache.totalSubviewSpacing,
            height: idealSize.height
        )
    }

    public func placeSubviews(in bounds: Rect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        var origin: Point = bounds.origin
        var anchor: AnchorPoint = .leading
        let isRightToLeft = subviews.layoutDirection == .rightToLeft

        switch self.alignment {
        case .top:
            anchor = isRightToLeft ? .topTrailing : .topLeading
            origin.y = bounds.minY
        case .bottom:
            anchor = isRightToLeft ? .bottomTrailing : .bottomLeading
            origin.y = bounds.maxY
        case .center:
            anchor = isRightToLeft ? .trailing : .leading
            origin.y = bounds.midY
        }
        var idealWidth: Float = 0
        let proposedHeight = finiteDimension(proposal.height)
        let idealSizes: [Size] = subviews.enumerated()
            .map { index, subview in
                let size = subview.sizeThatFits(ProposedViewSize(height: proposedHeight))
                let sanitizedSize = sanitized(size: size, fallback: cache.minSizes[index])
                idealWidth += sanitizedSize.width
                return sanitizedSize
            }
        let hasFlexibleSubviews = (0..<subviews.count)
            .contains { index in
                isFlexibleSubview(index: index, cache: cache)
            }

        let layoutWidth: Float
        if hasFlexibleSubviews {
            layoutWidth = min(cache.maxSize.width + cache.totalSubviewSpacing, bounds.width)
        } else {
            layoutWidth = min(idealWidth + cache.totalSubviewSpacing, bounds.width)
        }
        origin.x = isRightToLeft ? bounds.maxX : bounds.minX

        let fallbackFlexibleIndices = (0..<subviews.count)
            .filter { index in
                isFlexibleSubview(index: index, cache: cache)
            }
        let spacerFlexibleIndices = fallbackFlexibleIndices.filter { index in
            isSpacerSubview(subviews[index])
        }
        let nonSpacerFlexibleIndices = fallbackFlexibleIndices.filter { index in
            !isSpacerSubview(subviews[index])
        }
        let explicitFlexibleIndices = nonSpacerFlexibleIndices.filter { index in
            isExplicitlyFlexibleWidthSubview(subviews[index])
        }

        let layoutPriorities = subviews.map(\.layoutPriority)
        let availableSpace = layoutWidth - idealWidth - cache.totalSubviewSpacing
        let distributedFlexibleIndices: [Int]
        if availableSpace > 0 {
            if !explicitFlexibleIndices.isEmpty {
                distributedFlexibleIndices = explicitFlexibleIndices
            } else if !spacerFlexibleIndices.isEmpty {
                distributedFlexibleIndices = spacerFlexibleIndices
            } else {
                distributedFlexibleIndices = fallbackFlexibleIndices
            }
        } else {
            distributedFlexibleIndices =
                nonSpacerFlexibleIndices.isEmpty
                ? fallbackFlexibleIndices
                : nonSpacerFlexibleIndices
        }
        let distributedPriorityCount = Set(distributedFlexibleIndices.map { layoutPriorities[$0] }).count

        if distributedPriorityCount > 1 || availableSpace < 0 {
            let assignedWidths = stackAssignedMainAxisSizes(
                idealSizes: idealSizes.map(\.width),
                minSizes: subviews.enumerated()
                    .map { index, subview in
                        min(
                            compressionMinWidth(index: index, subview: subview, cache: cache),
                            idealSizes[index].width
                        )
                    },
                maxSizes: cache.maxSizes.map(\.width),
                layoutPriorities: layoutPriorities,
                flexibleIndices: distributedFlexibleIndices,
                availableSpace: availableSpace
            )

            for (index, subview) in subviews.enumerated() {
                let assignedWidth = assignedWidths[index]

                origin.x += isRightToLeft ? -cache.subviewSpacings[index] : cache.subviewSpacings[index]

                let proposal = ProposedViewSize(width: assignedWidth, height: idealSizes[index].height)
                subview.place(at: origin, anchor: anchor, proposal: proposal)

                let newWidth = subview.dimensions(in: proposal).width
                origin.x += isRightToLeft ? -newWidth : newWidth
            }
        } else {
            let equalizedSpacerWidths = equalizedSpacerMainAxisSizes(
                idealSizes: idealSizes.map(\.width),
                maxSizes: cache.maxSizes.map(\.width),
                spacerIndices: distributedFlexibleIndices.filter { isSpacerSubview(subviews[$0]) },
                availableSpace: max(layoutWidth - idealWidth - cache.totalSubviewSpacing, 0)
            )
            var restOfFlexibleViews = distributedFlexibleIndices.count
            var availableSpace = max(availableSpace, 0)

            for (index, subview) in subviews.enumerated() {
                var idealWidth = equalizedSpacerWidths?[index] ?? idealSizes[index].width
                let isFlexible = isFlexibleSubview(index: index, cache: cache)
                let participatesInDistribution = distributedFlexibleIndices.contains(index)

                if equalizedSpacerWidths == nil && isFlexible && participatesInDistribution && restOfFlexibleViews > 0 {
                    let slot = max(availableSpace, 0) / Float(restOfFlexibleViews)
                    idealWidth += slot
                    availableSpace -= slot
                    restOfFlexibleViews -= 1
                }

                origin.x += isRightToLeft ? -cache.subviewSpacings[index] : cache.subviewSpacings[index]

                let proposal = ProposedViewSize(width: idealWidth, height: idealSizes[index].height)
                subview.place(at: origin, anchor: anchor, proposal: proposal)

                let newWidth = subview.dimensions(in: proposal).width

                if isFlexible {
                    availableSpace -= newWidth - idealWidth
                }

                origin.x += isRightToLeft ? -newWidth : newWidth
            }
        }
    }

    @inline(__always)
    private func finiteDimension(_ value: Float?) -> Float? {
        guard let value, value.isFinite else {
            return nil
        }

        return value
    }

    @inline(__always)
    private func sanitized(size: Size, fallback: Size) -> Size {
        Size(
            width: size.width.isFinite ? size.width : fallback.width,
            height: size.height.isFinite ? size.height : fallback.height
        )
    }

    @inline(__always)
    private func isFlexibleSubview(
        index: Int,
        cache: Cache
    ) -> Bool {
        let maxWidth = cache.maxSizes[index].width
        let minWidth = cache.minSizes[index].width
        return maxWidth > minWidth
    }

    @inline(__always)
    private func isSpacerSubview(_ subview: LayoutSubview) -> Bool {
        subview.node is SpacerViewNode
    }

    private func compressionMinWidth(
        index: Int,
        subview: LayoutSubview,
        cache: Cache
    ) -> Float {
        guard
            let frameNode = subview.node as? FrameViewNode,
            case let .constraints(minWidth, _, maxWidth, _, _, _, _) = frameNode.frameRule,
            let maxWidth,
            !maxWidth.isFinite
        else {
            return cache.minSizes[index].width
        }

        return minWidth ?? 0
    }

    private func isExplicitlyFlexibleWidthSubview(_ subview: LayoutSubview) -> Bool {
        isExplicitlyFlexibleWidthNode(subview.node)
    }

    private func isExplicitlyFlexibleWidthNode(_ node: ViewNode) -> Bool {
        if let frameNode = node as? FrameViewNode,
            case let .constraints(_, _, maxWidth, _, _, _, _) = frameNode.frameRule,
            let maxWidth {
            return !maxWidth.isFinite
        }

        if let modifierNode = node as? ViewModifierNode {
            return isExplicitlyFlexibleWidthNode(modifierNode.contentNode)
        }

        return false
    }
}
