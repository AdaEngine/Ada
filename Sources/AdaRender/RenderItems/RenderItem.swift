//
//  RenderItem.swift
//  AdaEngine
//
//  Created by v.prusakov on 2/23/23.
//

import AdaECS

/// An object that store render items for rendering.
public struct RenderItems<T: RenderItem>: Sendable, Resource {
    /// The items of the render items.
    public var items: [T]

    /// Initialize a new render items.
    ///
    /// - Parameter items: The items of the render items.
    public init(items: [T] = []) {
        self.items = items
    }

    /// Sort the items of the render items.
    public mutating func sort() {
        self.items.sort(by: { $0.sortKey < $1.sortKey })
    }

    /// Get the sorted items of the render items.
    ///
    /// - Returns: The sorted items of the render items.
    public func sorted() -> Self {
        var value = self
        value.items.sort(by: { $0.sortKey < $1.sortKey })
        return value
    }

    /// Render the items of the render items.
    ///
    /// - Parameters:
    ///   - drawList: The draw list.
    ///   - world: The world.
    ///   - view: The view.
    public func render(with renderPass: RenderCommandEncoder, world: World, view: Entity) throws {
        for item in self.items {
            try AnyDrawPass(item.drawPass)
                .render(
                    with: renderPass,
                    world: world,
                    view: view,
                    item: item
                )
        }
    }
}

/// A protocol that defines a render item.
public protocol RenderItem: Sendable {
    /// The sort key of the render item.
    associatedtype SortKey: Comparable

    /// The entity of the render item.
    var entity: Entity.ID { get }

    /// The draw pass of the render item.
    var drawPass: any DrawPass { get }

    /// The sort key of the render item.
    var sortKey: SortKey { get }

    /// The range of instances that the batch cover.
    var batchRange: Range<Int32>? { get set }
}
