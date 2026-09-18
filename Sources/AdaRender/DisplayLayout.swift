import AdaECS
import Math

/// Available application regions in logical points. An expanded layout does not imply a physical hinge sensor.
public struct DisplayLayout: Resource, Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case compact, expanded }

    public let state: State
    public let primary: Rect
    public let secondary: Rect?
    public let hinge: Rect?

    public var isExpanded: Bool { state == .expanded }
    public var size: Size {
        Size(width: max(primary.maxX, secondary?.maxX ?? 0), height: max(primary.maxY, secondary?.maxY ?? 0))
    }

    /// A conventional single surface, without inferring device posture from its aspect ratio.
    public static func standard(size: Size) -> Self {
        Self(state: .compact, primary: Rect(origin: .zero, size: sanitized(size)), secondary: nil, hinge: nil)
    }

    /// A neutral editor profile; these dimensions are not specifications of any shipping device.
    public static func foldable(expanded: Bool, panelSize: Size = Size(width: 400, height: 640), gap: Float = 20) -> Self {
        let panel = sanitized(panelSize)
        let spacing = gap.isFinite ? max(0, gap) : 0
        return Self(
            state: expanded ? .expanded : .compact,
            primary: Rect(origin: .zero, size: panel),
            secondary: expanded ? Rect(x: panel.width + spacing, y: 0, width: panel.width, height: panel.height) : nil,
            hinge: expanded && spacing > 0 ? Rect(x: panel.width, y: 0, width: spacing, height: panel.height) : nil
        )
    }

    public func fitScale(in available: Size) -> Float {
        guard available.width.isFinite, available.height.isFinite, available.width > 0, available.height > 0 else {
            return 0.02
        }
        return max(0.02, min(3, min(available.width / size.width, available.height / size.height)))
    }

    private static func sanitized(_ size: Size) -> Size {
        Size(width: size.width.isFinite ? max(1, size.width) : 1, height: size.height.isFinite ? max(1, size.height) : 1)
    }

    /// Registers a read-only snapshot for AdaScript's existing `@res` bridge.
    @MainActor public static func registerRuntimeType() {
        RuntimeTypeRegistry.registerResource(Self.self, names: ["DisplayLayout"])
        let keys = ["state", "isExpanded", "primary", "secondary", "hinge"]
        RuntimeResourceReflectionRegistry.register(
            Self.self,
            fields: keys.map { key in
                // ECS supplies this pointer only for the duration of a declared resource access.
                unsafe EditorComponentFieldDescriptor(
                    key: key,
                    label: key,
                    kind: .readOnly,
                    isEditable: false,
                    accepts: { _ in false },
                    read: { _ in nil },
                    write: { _, _ in nil },
                    readPointer: { pointer in
                        let layout = unsafe pointer.assumingMemoryBound(to: Self.self).pointee
                        switch key {
                        case "state": return .string(layout.state.rawValue)
                        case "isExpanded": return .bool(layout.isExpanded)
                        case "primary": return rectangleValue(layout.primary)
                        case "secondary": return layout.secondary.map(rectangleValue) ?? .null
                        case "hinge": return layout.hinge.map(rectangleValue) ?? .null
                        default: return nil
                        }
                    }
                )
            }
        )
    }

    private static func rectangleValue(_ rect: Rect) -> EditorFieldValue {
        .object([
            "x": .double(Double(rect.minX)),
            "y": .double(Double(rect.minY)),
            "width": .double(Double(rect.width)),
            "height": .double(Double(rect.height)),
        ])
    }
}

/// Marks a layout supplied by an embedding surface instead of the native window.
package struct EmbeddedDisplayLayout: Resource {
    package init() {}
}
