//
//  BatchTransparent2DItemsSystem.swift
//  AdaEngine
//
//  Created by v.prusakov on 2/23/23.
//

import AdaECS

public struct SortedRenderItems<T: RenderItem>: Resource {
    public var items: RenderItems<T>

    public init(items: RenderItems<T> = .init()) {
        self.items = items
    }
}

/// Batch transparent items which contains batchEntity.
/// Run each frame before drawing.
/// - Warning: Doesn't work with `-Onone` optimization level. Need report to swift team. `swift::TargetMetadata<swift::InProcess>::isCanonicalStaticallySpecializedGenericMetadata()`
@PlainSystem
public struct BatchAndSortItemsSystem<T: RenderItem> {
    @ResMut<RenderItems<T>>
    private var renderItems

    @ResMut<SortedRenderItems<T>>
    private var sortedRenderItems

    public init(world _: World) {}

    public func update(context _: UpdateContext) async {
        sortedRenderItems.items.items.removeAll(keepingCapacity: true)
        let items = renderItems.sorted().items
        var batchedItems: [T] = []
        batchedItems.reserveCapacity(items.count)

        if var currentItem = items.first {
            for nextItemIndex in 1..<items.count {
                let nextItem = items[nextItemIndex]

                if tryToAddBatch(to: &currentItem, from: nextItem) == false {
                    batchedItems.append(currentItem)
                    currentItem = nextItem
                }
            }

            batchedItems.append(currentItem)
        }

        sortedRenderItems.items.items.append(contentsOf: batchedItems)
    }

    private func tryToAddBatch(to currentItem: inout T, from otherItem: T) -> Bool {
        guard let batch = currentItem.batchRange, let otherBatch = otherItem.batchRange else {
            return false
        }

        if otherItem.entity != currentItem.entity {
            return false
        }

        if batch.upperBound == otherBatch.lowerBound {
            currentItem.batchRange = batch.lowerBound..<otherBatch.upperBound
        } else if batch.lowerBound == otherBatch.upperBound {
            currentItem.batchRange = otherBatch.lowerBound..<batch.upperBound
        } else {
            return false
        }

        return true
    }
}
