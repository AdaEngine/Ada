import AdaECS
import AdaRender
import Foundation
import Math

/// A data-driven platformer playfield rendered on foldable display surfaces.
@Component
public struct ShadowLevel: Codable, Sendable {
    public var path: String
    public init(path: String = "") { self.path = path }
}

public struct ShadowLevelDefinition: Codable, Sendable {
    public var title: String
    public var platforms: [ShadowSolid]
    public var bridges: [ShadowBridge]
    public var checkpoints: [Vector2]
    public var start: Vector2
    public var exitX: Float
    public var transferDestination: Vector3
    public var portal: Vector2
}

public struct ShadowSolid: Codable, Sendable {
    public var id: String
    public var rect: Rect
}

public struct ShadowBridge: Codable, Sendable {
    public var id: String
    public var lamp: FoldAttachment
    public var caster: FoldAttachment
    public var width: Float
    public var height: Float
    public var receivingBounds: Rect
    public var minimumCheckpoint: Int
    public var requiresTransferredItem: Bool
}

public struct ShadowPolygon: Sendable {
    public var id: String
    public var points: [Vector2]

    /// The upper silhouette is the same boundary used by drawing and collision.
    public var top: ShadowSupport? {
        guard points.count >= 3 else { return nil }
        var best: (Vector2, Vector2)?
        for index in points.indices {
            let a = points[index], b = points[(index + 1) % points.count]
            guard abs(b.x - a.x) > 0.1 else { continue }
            if let current = best {
                if a.y + b.y > current.0.y + current.1.y { best = (a, b) }
            } else { best = (a, b) }
        }
        guard let (a, b) = best else { return nil }
        return ShadowSupport(id: id, a: a.x < b.x ? a : b, b: a.x < b.x ? b : a)
    }
}

public struct ShadowSupport: Sendable {
    public var id: String
    public var a: Vector2
    public var b: Vector2
    public func height(at x: Float) -> Float? {
        guard x >= a.x - 0.01, x <= b.x + 0.01, b.x - a.x > 0.001 else { return nil }
        return a.y + (b.y - a.y) * (x - a.x) / (b.x - a.x)
    }
}

/// Game actions are counters so a press survives until the next simulation step.
public struct ShadowPlayerInput: Resource, Sendable {
    public var moveX: Float = 0
    public var jump: Int = 0
    public var flip: Int = 0
    public var transfer: Int = 0
    public var restart: Int = 0
    public init() {}

    @MainActor public static func registerRuntimeType() {
        RuntimeTypeRegistry.registerResource(Self.self, names: ["ShadowPlayerInput"])
        RuntimeResourceReflectionRegistry.register(Self.self, fields: ["moveX", "jump", "flip", "transfer", "restart"].map { key in
            unsafe ReflectedComponentField(key: key, label: key, kind: key == "moveX" ? .float : .int, isWritable: true,
                read: { _ in nil }, write: { _, _ in nil }, readPointer: { pointer in
                    let value = unsafe pointer.assumingMemoryBound(to: Self.self).pointee
                    switch key {
                    case "moveX": return .double(Double(value.moveX))
                    case "jump": return .int(value.jump)
                    case "flip": return .int(value.flip)
                    case "transfer": return .int(value.transfer)
                    default: return .int(value.restart)
                    }
                }, writePointer: { pointer, field in
                    let value = unsafe pointer.assumingMemoryBound(to: Self.self)
                    if key == "moveX" { return unsafe ComponentReflection.write(field, to: &value.pointee.moveX) }
                    switch key {
                    case "jump": return unsafe ComponentReflection.write(field, to: &value.pointee.jump)
                    case "flip": return unsafe ComponentReflection.write(field, to: &value.pointee.flip)
                    case "transfer": return unsafe ComponentReflection.write(field, to: &value.pointee.transfer)
                    default: return unsafe ComponentReflection.write(field, to: &value.pointee.restart)
                    }
                })
        })
    }
}

public struct ShadowProgress: Resource, Sendable {
    public var checkpoint: Int = 0
    public var completed = false
    public var outer = false
    public var message = ""
    public init() {}

    @MainActor public static func registerRuntimeType() {
        RuntimeTypeRegistry.registerResource(Self.self, names: ["ShadowProgress"])
        RuntimeResourceReflectionRegistry.register(Self.self, fields: ["checkpoint", "completed", "outer", "message"].map { key in
            unsafe ReflectedComponentField(key: key, label: key, kind: .readOnly, isWritable: false, accepts: { _ in false },
                read: { _ in nil }, write: { _, _ in nil }, readPointer: { pointer in
                    let value = unsafe pointer.assumingMemoryBound(to: Self.self).pointee
                    switch key {
                    case "checkpoint": return .int(value.checkpoint)
                    case "completed": return .bool(value.completed)
                    case "outer": return .bool(value.outer)
                    default: return .string(value.message)
                    }
                })
        })
    }
}
