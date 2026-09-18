//
//  GridLayout.swift
//  AdaEngine
//

import AdaAnimation
import Math

/// A layout that places subviews into a fixed number of equal-width columns.
public struct GridLayout: Layout {
    public typealias AnimatableData = EmptyAnimatableData

    private let columns: Int
    private let horizontalSpacing: Float
    private let verticalSpacing: Float
    private let alignment: Alignment

    public init(
        columns: Int,
        horizontalSpacing: Float? = nil,
        verticalSpacing: Float? = nil,
        alignment: Alignment = .topLeading
    ) {
        self.columns = max(columns, 1)
        self.horizontalSpacing = horizontalSpacing ?? 8
        self.verticalSpacing = verticalSpacing ?? 8
        self.alignment = alignment
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, subviews: Subviews, cache _: inout Void) -> Size {
        guard !subviews.isEmpty else {
            return .zero
        }

        let metrics = measure(proposal: proposal, subviews: subviews)

        return Size(
            width: metrics.totalWidth,
            height: metrics.totalHeight
        )
    }

    public func placeSubviews(in bounds: Rect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout Void) {
        guard !subviews.isEmpty else {
            return
        }

        let metrics = measure(proposal: ProposedViewSize(width: bounds.width, height: proposal.height), subviews: subviews)

        for index in subviews.indices {
            let row = index / columns
            let logicalColumn = index % columns
            let column =
                subviews.layoutDirection == .rightToLeft
                ? columns - logicalColumn - 1
                : logicalColumn
            let cellOrigin = Point(
                x: bounds.minX + Float(column) * (metrics.cellWidth + horizontalSpacing),
                y: bounds.minY + metrics.rowOffsets[row]
            )
            let cellRect = Rect(
                x: cellOrigin.x,
                y: cellOrigin.y,
                width: metrics.cellWidth,
                height: metrics.rowHeights[row]
            )

            let resolvedAlignment = alignment.resolved(for: subviews.layoutDirection)
            subviews[index]
                .place(
                    at: placementPoint(in: cellRect, layoutDirection: subviews.layoutDirection),
                    anchor: resolvedAlignment.anchorPoint,
                    proposal: ProposedViewSize(width: metrics.cellWidth, height: metrics.rowHeights[row])
                )
        }
    }

    private struct Metrics {
        var cellWidth: Float
        var rowHeights: [Float]
        var rowOffsets: [Float]
        var totalWidth: Float
        var totalHeight: Float
    }

    private func measure(proposal: ProposedViewSize, subviews: Subviews) -> Metrics {
        let rowCount = (subviews.count + columns - 1) / columns
        let proposedWidth = finiteDimension(proposal.width)
        let totalHorizontalSpacing = Float(columns - 1) * horizontalSpacing

        let cellWidth: Float
        if let proposedWidth {
            cellWidth = max((proposedWidth - totalHorizontalSpacing) / Float(columns), 0)
        } else {
            let widestSubview = subviews.reduce(Float.zero) { partialResult, subview in
                max(partialResult, sanitized(size: subview.sizeThatFits(.unspecified)).width)
            }
            cellWidth = widestSubview
        }

        var rowHeights = Array(repeating: Float.zero, count: rowCount)
        for index in subviews.indices {
            let measured = sanitized(size: subviews[index].sizeThatFits(ProposedViewSize(width: cellWidth)))
            rowHeights[index / columns] = max(rowHeights[index / columns], measured.height)
        }

        var rowOffsets = Array(repeating: Float.zero, count: rowCount)
        var cursor = Float.zero
        for row in 0..<rowCount {
            rowOffsets[row] = cursor
            cursor += rowHeights[row]
            if row != rowCount - 1 {
                cursor += verticalSpacing
            }
        }

        let totalWidth = proposedWidth ?? (Float(columns) * cellWidth + totalHorizontalSpacing)

        return Metrics(
            cellWidth: cellWidth,
            rowHeights: rowHeights,
            rowOffsets: rowOffsets,
            totalWidth: totalWidth,
            totalHeight: cursor
        )
    }

    private func placementPoint(in rect: Rect, layoutDirection: LayoutDirection) -> Point {
        let x: Float
        switch alignment.horizontal.resolved(for: layoutDirection) {
        case .leading:
            x = rect.minX
        case .center:
            x = rect.midX
        case .trailing:
            x = rect.maxX
        }

        let y: Float
        switch alignment.vertical {
        case .top:
            y = rect.minY
        case .center:
            y = rect.midY
        case .bottom:
            y = rect.maxY
        }

        return Point(x, y)
    }

    private func finiteDimension(_ value: Float?) -> Float? {
        guard let value, value.isFinite else {
            return nil
        }

        return value
    }

    private func sanitized(size: Size) -> Size {
        Size(
            width: size.width.isFinite ? size.width : 0,
            height: size.height.isFinite ? size.height : 0
        )
    }
}
