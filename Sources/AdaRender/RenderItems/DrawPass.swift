//
//  DrawPass.swift
//  AdaEngine
//
//  Created by v.prusakov on 2/23/23.
//

import AdaECS

/// Draw pass is a render function that will render for specific item.
///
/// For example, you can create render pass for rendering ``Transparent2DRenderItem`` and configure rendering whatever you want.
/// Pass additional render data as components to ``Entity`` and pass that entity to ``Transparent2DRenderItem/entity`` property.
public protocol DrawPass<Item>: Resource {
    associatedtype Item: RenderItem

    func render(
        with renderEncoder: RenderCommandEncoder,
        world: World,
        view: Entity,
        item: Item
    ) throws
}

/// Type-erased draw pass.
public struct AnyDrawPass<T: RenderItem>: DrawPass {
    @usableFromInline
    let base: any DrawPass

    public init<Value: DrawPass>(_ base: Value) {
        self.base = base
    }

    @inlinable
    public func render(
        with renderEncoder: RenderCommandEncoder,
        world: World,
        view: Entity,
        item: T
    ) throws {
        try base._render(
            with: renderEncoder,
            world: world,
            view: view,
            item: item
        )
    }
}

extension DrawPass {
    @inlinable
    func _render(
        with renderEncoder: RenderCommandEncoder,
        world: World,
        view: Entity,
        item: Any
    ) throws {
        try self.render(
            with: renderEncoder,
            world: world,
            view: view,
            item: item as! Self.Item
        )
    }
}
