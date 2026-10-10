import AdaECS
import Math

/// Detached values used by AdaScript constructors and component query fields.
/// Layout values use lists so the VM and native host share the same contract.
extension ComponentReflection {
    public static func kind(for _: SpriteAnchor.Type) -> ReflectedFieldKind { .vector2 }
    public static func kind(for _: SpriteImageMode.Type) -> ReflectedFieldKind { .readOnly }
    public static func kind(for _: Size?.Type) -> ReflectedFieldKind { .vector2 }
    public static func isWritable(_: SpriteAnchor.Type) -> Bool { true }
    public static func isWritable(_: SpriteImageMode.Type) -> Bool { true }
    public static func isWritable(_: Size?.Type) -> Bool { true }

    public static func value(_ fieldValue: ReflectedFieldValue, as _: SpriteAnchor.Type) -> SpriteAnchor? {
        guard let vector = value(fieldValue, as: Vector2.self) else {
            return nil
        }
        return SpriteAnchor(x: vector.x, y: vector.y)
    }

    public static func value(_ fieldValue: ReflectedFieldValue, as _: Size?.Type) -> Size?? {
        if fieldValue == .null {
            return .some(nil)
        }
        guard let vector = value(fieldValue, as: Vector2.self), vector.x > 0, vector.y > 0 else {
            return nil
        }
        return .some(Size(width: vector.x, height: vector.y))
    }

    public static func value(_ fieldValue: ReflectedFieldValue, as _: SpriteImageMode.Type) -> SpriteImageMode? {
        let values: [ReflectedFieldValue]
        if case .string(let mode) = fieldValue { values = [.string(mode)] } else if case .array(let array) = fieldValue { values = array } else {
            return nil
        }
        guard case .string(let mode)? = values.first else {
            return nil
        }
        switch mode {
        case "stretch" where values.count == 1: return .stretch
        case "fit" where values.count == 1: return .fit
        case "fill" where values.count == 1: return .fill
        case "sliced" where values.count == 5:
            guard let top = value(values[1], as: Float.self), let left = value(values[2], as: Float.self),
                let bottom = value(values[3], as: Float.self), let right = value(values[4], as: Float.self),
                min(top, left, bottom, right) >= 0
            else { return nil }
            return .sliced(SpriteSliceBorder(top: top, left: left, bottom: bottom, right: right))
        case "tiled" where values.count == 4:
            guard let tileX = value(values[1], as: Bool.self), let tileY = value(values[2], as: Bool.self),
                let scale = value(values[3], as: Float.self), scale > 0
            else { return nil }
            return .tiled(tileX: tileX, tileY: tileY, scale: scale)
        default: return nil
        }
    }

    public static func accepts(_ value: ReflectedFieldValue, for type: SpriteAnchor.Type) -> Bool { self.value(value, as: type) != nil }
    public static func accepts(_ value: ReflectedFieldValue, for type: SpriteImageMode.Type) -> Bool { self.value(value, as: type) != nil }
    public static func accepts(_ value: ReflectedFieldValue, for type: Size?.Type) -> Bool { self.value(value, as: type) != nil }
    public static func read(_ anchor: SpriteAnchor) -> ReflectedFieldValue { read(Vector2(anchor.x, anchor.y)) }
    public static func read(_ size: Size?) -> ReflectedFieldValue { size.map { read(Vector2($0.width, $0.height)) } ?? .null }
    public static func read(_ mode: SpriteImageMode) -> ReflectedFieldValue {
        switch mode {
        case .stretch: .string("stretch")
        case .fit: .string("fit")
        case .fill: .string("fill")
        case .sliced(let border): .array([.string("sliced"), read(border.top), read(border.left), read(border.bottom), read(border.right)])
        case let .tiled(tileX, tileY, scale): .array([.string("tiled"), .bool(tileX), .bool(tileY), read(scale)])
        }
    }
    public static func write(_ fieldValue: ReflectedFieldValue, to target: inout SpriteAnchor) -> Bool {
        guard let decoded = value(fieldValue, as: SpriteAnchor.self) else {
            return false
        }
        target = decoded
        return true
    }
    public static func write(_ fieldValue: ReflectedFieldValue, to target: inout SpriteImageMode) -> Bool {
        guard let decoded = value(fieldValue, as: SpriteImageMode.self) else {
            return false
        }
        target = decoded
        return true
    }
    public static func write(_ fieldValue: ReflectedFieldValue, to target: inout Size?) -> Bool {
        guard let decoded = value(fieldValue, as: Size?.self) else {
            return false
        }
        target = decoded
        return true
    }
}
