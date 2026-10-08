@_spi(Scripting) import AdaECS
import AdaUI
import AdaUtils
import Foundation
import Gravity

@GSExportable("__AdaUIView")
final class AdaScriptViewBridge: @unchecked Sendable, AdaScriptNonSendableBridge {
    @GSExportableIgnore
    let model: AdaScriptViewModel

    init() {
        self.model = AdaScriptViewModel(content: .empty)
    }

    @GSExportableIgnore
    private init(model: AdaScriptViewModel) {
        self.model = model
    }

    func accessibilityIdentifier(_ value: String) -> AdaScriptViewBridge {
        replacingStyle("accessibilityIdentifier") { $0.accessibilityIdentifier = value }
    }

    func background(_ value: String) -> AdaScriptViewBridge {
        replacingStyle("background") { $0.background = value }
    }

    func button(_ title: String, _ action: String) -> AdaScriptViewBridge {
        AdaScriptViewBridge(model: AdaScriptViewModel(content: .button(title: title, action: action)))
    }

    func child(_ value: AdaScriptViewBridge) -> AdaScriptViewBridge {
        AdaScriptViewBridge(model: model.addingChild(value.model))
    }

    func divider() -> AdaScriptViewBridge {
        AdaScriptViewBridge(model: AdaScriptViewModel(content: .divider))
    }

    func empty() -> AdaScriptViewBridge {
        AdaScriptViewBridge(model: AdaScriptViewModel(content: .empty))
    }

    func fontSize(_ value: GSValue) -> AdaScriptViewBridge {
        replacingStyle("fontSize") { $0.fontSize = value.finiteNonnegativeFloat }
    }

    func foregroundColor(_ value: String) -> AdaScriptViewBridge {
        replacingStyle("foregroundColor") { $0.foregroundColor = value }
    }

    func frame(_ width: GSValue, _ height: GSValue) -> AdaScriptViewBridge {
        replacingStyle("frame") {
            $0.width = width.finiteNonnegativeFloat
            $0.height = height.finiteNonnegativeFloat
        }
    }

    func hStack() -> AdaScriptViewBridge {
        AdaScriptViewBridge(model: AdaScriptViewModel(content: .hStack(children: [], spacing: nil)))
    }

    func opacity(_ value: GSValue) -> AdaScriptViewBridge {
        replacingStyle("opacity") { $0.opacity = min(max(value.finiteFloat ?? 1, 0), 1) }
    }

    func padding(_ value: GSValue) -> AdaScriptViewBridge {
        replacingStyle("padding") { $0.padding = value.finiteNonnegativeFloat }
    }

    func spacer() -> AdaScriptViewBridge {
        AdaScriptViewBridge(model: AdaScriptViewModel(content: .spacer(minLength: nil)))
    }

    func spacerMinLength(_ value: GSValue) -> AdaScriptViewBridge {
        AdaScriptViewBridge(model: model.replacingSpacerMinLength(value.finiteNonnegativeFloat))
    }

    func spacing(_ value: GSValue) -> AdaScriptViewBridge {
        AdaScriptViewBridge(model: model.replacingSpacing(value.finiteNonnegativeFloat))
    }

    func text(_ value: String) -> AdaScriptViewBridge {
        AdaScriptViewBridge(model: AdaScriptViewModel(content: .text(value)))
    }

    func vStack() -> AdaScriptViewBridge {
        AdaScriptViewBridge(model: AdaScriptViewModel(content: .vStack(children: [], spacing: nil)))
    }

    func zStack() -> AdaScriptViewBridge {
        AdaScriptViewBridge(model: AdaScriptViewModel(content: .zStack(children: [])))
    }

    private func replacingStyle(_ type: String, _ update: (inout AdaScriptViewStyle) -> Void) -> AdaScriptViewBridge {
        var style = model.style
        update(&style)
        var arguments: [String: UIArgument] = [:]
        switch type {
        case "padding": arguments["value"] = style.padding.map { .init(value: .number(Double($0))) }
        case "fontSize": arguments["value"] = style.fontSize.map { .init(value: .number(Double($0))) }
        case "opacity": arguments["value"] = style.opacity.map { .init(value: .number(Double($0))) }
        case "foregroundColor": arguments["color"] = style.foregroundColor.map { .init(value: .string($0)) }
        case "background": arguments["color"] = style.background.map { .init(value: .string($0)) }
        case "accessibilityIdentifier": arguments["value"] = style.accessibilityIdentifier.map { .init(value: .string($0)) }
        case "frame":
            arguments["width"] = style.width.map { .init(value: .number(Double($0))) }
            arguments["height"] = style.height.map { .init(value: .number(Double($0))) }
        default: break
        }
        return AdaScriptViewBridge(
            model: AdaScriptViewModel(
                content: model.content,
                style: style,
                modifiers: model.modifiers + [.init(id: "modifier-\(model.modifiers.count)", type: type, arguments: arguments)]
            )
        )
    }

    func nativeView(_ identifier: String) -> AdaScriptViewBridge {
        AdaScriptViewBridge(model: .init(content: .native(.init(id: "native", type: identifier))))
    }

    func argument(_ name: String, _ value: GSValue) -> AdaScriptViewBridge {
        guard
            case var .native(node) = model.content,
            let field = AdaScriptUIValueBridge.detached(value)
        else {
            return AdaScriptViewBridge(model: .init(content: .native(.init(type: "Invalid UI argument: " + name))))
        }
        node.arguments[name] = .init(value: field)
        return AdaScriptViewBridge(model: .init(content: .native(node), style: model.style, modifiers: model.modifiers))
    }

    func action(_ event: String, _ method: String) -> AdaScriptViewBridge {
        guard case var .native(node) = model.content else {
            return self
        }
        node.actions[event] = method
        return AdaScriptViewBridge(model: .init(content: .native(node), style: model.style, modifiers: model.modifiers))
    }

    func nativeModifier(_ identifier: String, _ values: GSValue) -> AdaScriptViewBridge {
        guard let field = AdaScriptUIValueBridge.detached(values), case let .object(object) = field else {
            return AdaScriptViewBridge(model: .init(content: .native(.init(type: "Invalid modifier arguments: " + identifier))))
        }
        let modifier = UIModifierDescription(id: "modifier-\(model.modifiers.count)", type: identifier, arguments: object.mapValues { .init(value: $0) })
        return AdaScriptViewBridge(model: .init(content: model.content, style: model.style, modifiers: model.modifiers + [modifier]))
    }
}

struct AdaScriptViewModel: Sendable {
    indirect enum Content: Sendable {
        case native(UINodeDescription)
        case button(title: String, action: String)
        case divider
        case empty
        case hStack(children: [AdaScriptViewModel], spacing: Float?)
        case spacer(minLength: Float?)
        case text(String)
        case vStack(children: [AdaScriptViewModel], spacing: Float?)
        case zStack(children: [AdaScriptViewModel])
    }

    let content: Content
    let style: AdaScriptViewStyle
    let modifiers: [UIModifierDescription]

    init(content: Content, style: AdaScriptViewStyle = AdaScriptViewStyle(), modifiers: [UIModifierDescription] = []) {
        self.content = content
        self.style = style
        self.modifiers = modifiers
    }

    func addingChild(_ child: Self) -> Self {
        switch content {
        case var .native(node):
            node.children.append(child.uiNode(id: "child-\(node.children.count)"))
            return Self(content: .native(node), style: style, modifiers: modifiers)
        case let .hStack(children, spacing):
            return Self(content: .hStack(children: children + [child], spacing: spacing), style: style, modifiers: modifiers)
        case let .vStack(children, spacing):
            return Self(content: .vStack(children: children + [child], spacing: spacing), style: style, modifiers: modifiers)
        case let .zStack(children):
            return Self(content: .zStack(children: children + [child]), style: style, modifiers: modifiers)
        default:
            return self
        }
    }

    func replacingSpacerMinLength(_ minLength: Float?) -> Self {
        guard case .spacer = content else {
            return self
        }
        return Self(content: .spacer(minLength: minLength), style: style, modifiers: modifiers)
    }

    func replacingSpacing(_ spacing: Float?) -> Self {
        switch content {
        case let .hStack(children, _):
            Self(content: .hStack(children: children, spacing: spacing), style: style, modifiers: modifiers)
        case let .vStack(children, _):
            Self(content: .vStack(children: children, spacing: spacing), style: style, modifiers: modifiers)
        default:
            self
        }
    }
}

struct AdaScriptViewStyle: Sendable {
    var accessibilityIdentifier: String?
    var background: String?
    var fontSize: Float?
    var foregroundColor: String?
    var height: Float?
    var opacity: Float?
    var padding: Float?
    var width: Float?
}

@MainActor
struct AdaScriptRenderedView: View {
    let model: AdaScriptViewModel
    let performAction: @MainActor (String) -> Void
    var catalog: UICatalog = .standard

    var body: some View {
        do {
            let document = UISceneDocument(root: model.uiNode(id: "script"))
            let context = UIBindingContext()
            document.root.visit { node in
                for action in node.actions.values { context.on(action) { _ in performAction(action) } }
            }
            return AnyView(UISceneView(session: try UISceneInstance(document: document, context: context, catalog: catalog)))
        } catch { return AnyView(Text(error.localizedDescription).foregroundColor(.red)) }
    }
}

extension AdaScriptViewModel {
    func uiNode(id: String) -> UINodeDescription {
        var node: UINodeDescription
        var children: [AdaScriptViewModel] = []
        switch content {
        case let .native(value):
            node = value
            node.id = id
        case let .button(title, action): node = .init(id: id, type: "Button", arguments: ["title": .init(value: .string(title))], actions: ["action": action])
        case .divider: node = .init(id: id, type: "Divider")
        case .empty: node = .init(id: id, type: "EmptyView")
        case let .text(text): node = .init(id: id, type: "Text", arguments: ["text": .init(value: .string(text))])
        case let .spacer(length): node = .init(id: id, type: "Spacer", arguments: length.map { ["minLength": .init(value: .number(Double($0)))] } ?? [:])
        case let .hStack(values, spacing):
            node = .init(id: id, type: "HStack", arguments: spacing.map { ["spacing": .init(value: .number(Double($0)))] } ?? [:])
            children = values
        case let .vStack(values, spacing):
            node = .init(id: id, type: "VStack", arguments: spacing.map { ["spacing": .init(value: .number(Double($0)))] } ?? [:])
            children = values
        case let .zStack(values):
            node = .init(id: id, type: "ZStack")
            children = values
        }
        if !children.isEmpty {
            node.children = children.enumerated().map { $0.element.uiNode(id: "\(id)/\($0.offset)") }
        }
        node.modifiers += modifiers
        return node
    }
}

private struct AdaScriptColor {
    let value: Color

    init?(_ source: String) {
        if let named = Self.named[source.lowercased()] {
            self.value = named
            return
        }
        guard let value = Self.hex(source) else {
            return nil
        }
        self.value = value
    }

    private static let named: [String: Color] = [
        "black": .black, "blue": .blue, "brown": .brown, "clear": .clear,
        "gray": .gray, "green": .green, "grey": .gray, "mint": .mint,
        "orange": .orange, "pink": .pink, "purple": .purple, "red": .red,
        "white": .white, "yellow": .yellow,
    ]

    private static func hex(_ source: String) -> Color? {
        guard source.hasPrefix("#") else {
            return nil
        }
        let digits = source.dropFirst()
        guard let hex = Int(digits, radix: 16) else {
            return nil
        }
        if digits.count == 6 {
            return .fromHex(hex)
        }
        guard digits.count == 8 else {
            return nil
        }
        return Color(
            red: Float((hex >> 24) & 0xFF) / 255,
            green: Float((hex >> 16) & 0xFF) / 255,
            blue: Float((hex >> 8) & 0xFF) / 255,
            alpha: Float(hex & 0xFF) / 255
        )
    }
}

extension GSValue {
    var finiteFloat: Float? {
        // Gravity stores integers and floating-point numbers in the same union.
        // Read the active numeric type before converting to Swift floating point.
        let number: Double
        if isInteger {
            number = Double(toInteger)
        } else if isDouble {
            number = toDouble
        } else {
            return nil
        }
        let converted = Float(number)
        return converted.isFinite ? converted : nil
    }

    var finiteNonnegativeFloat: Float? {
        finiteFloat.map { max($0, 0) }
    }
}
