import AdaRender
import AdaUIDescription
import AdaUtils
import Foundation

/// Validated factory inputs; closures and runtime bindings remain owned by the host.
@MainActor
public struct UIFactoryContext {
    public let arguments: [String: UIValue]
    public let bindings: [String: Binding<UIValue>]
    public let actions: [String: String]
    public let context: UIBindingContext
    public let children: [UIRenderedChild]
    public var resources: UISceneResources?
    public var sourceURL: URL?
    public var actionSignatures: [UIActionSignature] = []

    public func string(_ name: String, _ fallback: String = "") -> String { arguments[name]?.string ?? fallback }
    public func number(_ name: String, _ fallback: Double = 0) -> Double { arguments[name]?.number ?? fallback }
    public func float(_ name: String) -> Float? { arguments[name]?.number.map(Float.init) }
    public func bool(_ name: String, _ fallback: Bool = false) -> Bool { arguments[name]?.bool ?? fallback }
    public var content: some View { ForEach(children) { $0.view } }

    public func textBinding(_ name: String) -> Binding<String> {
        let binding = bindings[name]
        return Binding(get: { binding?.wrappedValue.string ?? string(name) }, set: { binding?.wrappedValue = .string($0) })
    }

    public func perform(_ event: String, arguments: [String: UIValue] = [:]) {
        guard let name = actions[event] else {
            return
        }
        if let signature = actionSignatures.first(where: { $0.name == event }) {
            for parameter in signature.parameters {
                guard let value = arguments[parameter.name], parameter.type.accepts(value) else {
                    context.report(UIDiagnostic("Invalid '\(parameter.name)' argument for event '\(event)'."))
                    return
                }
            }
        }
        context.perform(name, arguments: arguments)
    }

    public func color(_ name: String, fallback: Color = .white) throws -> Color {
        guard let text = arguments[name]?.string else {
            return fallback
        }
        return try Self.color(from: text)
    }

    /// Parses a named color or an RGB/RGBA hex literal using UI document semantics.
    public static func color(from text: String) throws -> Color {
        switch text {
        case "clear": return .clear
        case "white": return .white
        case "black": return .black
        case "red": return .red
        case "green": return .green
        case "blue": return .blue
        case "yellow": return .yellow
        case "gray",
            "grey":
            return .gray
        case "orange": return .orange
        case "purple": return .purple
        default: break
        }
        let hex = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard [6, 8].contains(hex.count), let value = UInt32(hex, radix: 16) else {
            throw UIDiagnostic("Invalid color '\(text)'.")
        }
        let rgba = hex.count == 6 ? (value << 8) | 255 : value
        return Color(
            red: Float((rgba >> 24) & 255) / 255,
            green: Float((rgba >> 16) & 255) / 255,
            blue: Float((rgba >> 8) & 255) / 255,
            alpha: Float(rgba & 255) / 255
        )
    }
}

@MainActor
public struct UIRenderedChild: Identifiable {
    public let id: String
    public let view: AnyView

    public init(id: String, view: AnyView) {
        self.id = id
        self.view = view
    }
}

@MainActor
public struct UINativeViewDescriptor {
    public let signature: UIDescriptorSignature
    public let makeView: @MainActor (UIFactoryContext) throws -> AnyView

    public init(signature: UIDescriptorSignature, makeView: @escaping @MainActor (UIFactoryContext) throws -> AnyView) {
        self.signature = signature
        self.makeView = makeView
    }
}

@MainActor
public struct UINativeModifierDescriptor {
    public let signature: UIDescriptorSignature
    public let apply: @MainActor (AnyView, UIFactoryContext) throws -> AnyView

    public init(signature: UIDescriptorSignature, apply: @escaping @MainActor (AnyView, UIFactoryContext) throws -> AnyView) {
        self.signature = signature
        self.apply = apply
    }
}

/// Immutable, session-scoped catalog shared by authoring, validation and rendering.
@MainActor
public struct UICatalog {
    public let generation = UUID()
    public let views: [String: UINativeViewDescriptor]
    public let modifiers: [String: UINativeModifierDescriptor]

    public init(views: [UINativeViewDescriptor], modifiers: [UINativeModifierDescriptor]) throws {
        guard
            Set(views.map(\.signature.id)).count == views.count,
            Set(modifiers.map(\.signature.id)).count == modifiers.count
        else {
            throw UIDiagnostic("Duplicate UI descriptor ID.")
        }
        self.views = Dictionary(uniqueKeysWithValues: views.map { ($0.signature.id, $0) })
        self.modifiers = Dictionary(uniqueKeysWithValues: modifiers.map { ($0.signature.id, $0) })
    }

    public func adding(views: [UINativeViewDescriptor] = [], modifiers: [UINativeModifierDescriptor] = []) throws -> Self {
        try Self(views: Array(self.views.values) + views, modifiers: Array(self.modifiers.values) + modifiers)
    }

    public var viewSignatures: [UIDescriptorSignature] { views.values.map(\.signature).sorted { $0.name < $1.name } }
    public var modifierSignatures: [UIDescriptorSignature] { modifiers.values.map(\.signature).sorted { $0.name < $1.name } }
}
