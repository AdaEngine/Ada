import AdaRender
import AdaText
import AdaUIDescription
import AdaUtils
import Math

extension UICatalog {
    public static let standard = Self(builtinViews: builtinViews, builtinModifiers: builtinModifiers)

    private init(builtinViews: [UINativeViewDescriptor], builtinModifiers: [UINativeModifierDescriptor]) {
        views = Dictionary(uniqueKeysWithValues: builtinViews.map { ($0.signature.id, $0) })
        modifiers = Dictionary(uniqueKeysWithValues: builtinModifiers.map { ($0.signature.id, $0) })
    }

    static func number(_ name: String, _ value: Double? = nil) -> UIParameter {
        UIParameter(name, type: .number, defaultValue: value.map(UIValue.number))
    }
    static func string(_ name: String, _ value: String = "") -> UIParameter {
        UIParameter(name, type: .string, defaultValue: .string(value))
    }
    static func color(_ name: String, _ value: String) -> UIParameter {
        UIParameter(name, type: .string, defaultValue: .string(value), editor: .color)
    }
    static func choice(_ name: String, _ value: String, _ cases: [String]) -> UIParameter {
        UIParameter(name, type: .string, defaultValue: .string(value), editor: .enumeration(cases))
    }
    static func alignment(_ value: String = "center") -> UIParameter {
        choice("alignment", value, ["center", "leading", "trailing", "top", "bottom", "topLeading", "topTrailing", "bottomLeading", "bottomTrailing"])
    }
    static func bool(_ name: String, _ value: Bool = false) -> UIParameter {
        UIParameter(name, type: .bool, defaultValue: .bool(value))
    }

    private static var builtinViews: [UINativeViewDescriptor] {
        func view(
            _ name: String,
            _ parameters: [UIParameter] = [],
            content: UIContentShape = .none,
            actions: [UIActionSignature] = [],
            _ make: @escaping @MainActor (UIFactoryContext) throws -> AnyView
        ) -> UINativeViewDescriptor {
            .init(signature: .init(id: name, name: name, parameters: parameters, actions: actions, content: content), makeView: make)
        }
        let horizontalStack = [number("spacing", 8), choice("alignment", "center", ["top", "center", "bottom"])]
        let verticalStack = [number("spacing", 8), choice("alignment", "center", ["leading", "center", "trailing"])]
        return [
            view("Text", [string("text", "Text")]) { AnyView(Text($0.string("text"))) },
            view("Image", [string("path"), bool("resizable", true), bool("template")] + imageCapParameters) { c in
                guard let resources = c.resources else {
                    throw UIDiagnostic("Image requires a UI resource context.")
                }
                var image = try resources.image(c.string("path"), relativeTo: c.sourceURL)
                if c.bool("resizable") {
                    image = image.resizable(capInsets: try c.imageCapInsets())
                }
                if c.bool("template") {
                    image = image.renderMode(.template)
                }
                return AnyView(image)
            },
            view("LinearGradient", [color("startColor", "#ffffffff"), color("endColor", "#000000ff"), bool("horizontal")]) { c in
                AnyView(
                    LinearGradient(
                        colors: [try c.color("startColor"), try c.color("endColor")],
                        startPoint: c.bool("horizontal") ? .leading : .top,
                        endPoint: c.bool("horizontal") ? .trailing : .bottom
                    )
                )
            },
            view("NavigationStack", content: .single) { c in AnyView(NavigationStack { c.content }) },
            view("NavigationLink", [string("value"), string("title", "Open")], content: .children) { c in
                AnyView(
                    NavigationLink(value: c.string("value")) {
                        if c.children.isEmpty {
                            AnyView(Text(c.string("title")))
                        } else {
                            AnyView(c.content)
                        }
                    }
                )
            },
            view("EmptyView") { _ in AnyView(EmptyView()) },
            view("Spacer", [number("minLength", 0)]) { AnyView(Spacer(minLength: $0.float("minLength"))) },
            view("Divider") { _ in AnyView(Divider()) },
            view("HStack", horizontalStack, content: .children) { c in AnyView(HStack(alignment: c.verticalAlignment, spacing: c.float("spacing")) { c.content }) },
            view("VStack", verticalStack, content: .children) { c in AnyView(VStack(alignment: c.horizontalAlignment, spacing: c.float("spacing")) { c.content }) },
            view("ZStack", [alignment()], content: .children) { c in AnyView(ZStack(anchor: c.anchor) { c.content }) },
            view("Group", content: .children) { AnyView($0.content) },
            view("Grid", [number("columns", 2), number("horizontalSpacing", 8), number("verticalSpacing", 8), alignment("topLeading")], content: .children) { c in
                guard c.number("columns") >= 1, c.number("columns") <= 1024, c.number("columns").rounded() == c.number("columns") else {
                    throw UIDiagnostic("Grid columns must be an integer between 1 and 1024.")
                }
                return AnyView(
                    Grid(columns: Int(c.number("columns")), horizontalSpacing: c.float("horizontalSpacing"), verticalSpacing: c.float("verticalSpacing"), alignment: c.alignment) {
                        c.content
                    }
                )
            },
            view("LazyVStack", verticalStack + [number("estimatedRowHeight", 72)], content: .children) { c in
                AnyView(LazyVStack(c.children, alignment: c.horizontalAlignment, spacing: c.float("spacing"), estimatedRowHeight: Float(c.number("estimatedRowHeight"))) { $0.view })
            },
            view("ScrollView", [choice("axis", "vertical", ["vertical", "horizontal"])], content: .single) { c in
                AnyView(ScrollView(c.string("axis") == "horizontal" ? .horizontal : .vertical) { c.content })
            },
            view("Button", [string("title", "Button")], content: .children, actions: [.init("action")]) { c in
                if c.children.isEmpty {
                    return AnyView(Button(c.string("title")) { c.perform("action") })
                }
                return AnyView(Button(action: { c.perform("action") }, label: { c.content }))
            },
            view(
                "VirtualJoystick",
                [
                    .init("x", type: .number, defaultValue: .number(0), isBinding: true),
                    .init("y", type: .number, defaultValue: .number(0), isBinding: true),
                    number("diameter", 96), number("thumbDiameter", 38), number("movementRadius", 27), number("deadZone", 0.12),
                    color("baseColor", "#e0d8c5ff"), color("ringColor", "#293c55ff"), color("thumbColor", "#477c80ff"),
                    number("ringWidth", 3), number("idleOpacity", 1), number("activeOpacity", 1),
                    number("idleThumbOpacity", 1), number("activeThumbOpacity", 1),
                ]
            ) { c in
                guard let x = c.bindings["x"], let y = c.bindings["y"] else {
                    throw UIDiagnostic("VirtualJoystick requires x and y bindings.")
                }
                return AnyView(
                    VirtualJoystick(
                        x: Binding(get: { Float(x.wrappedValue.number ?? 0) }, set: { x.wrappedValue = .number(Double($0)) }),
                        y: Binding(get: { Float(y.wrappedValue.number ?? 0) }, set: { y.wrappedValue = .number(Double($0)) }),
                        style: VirtualJoystickStyle(
                            diameter: Float(c.number("diameter")),
                            thumbDiameter: Float(c.number("thumbDiameter")),
                            movementRadius: Float(c.number("movementRadius")),
                            deadZone: Float(c.number("deadZone")),
                            baseColor: try c.color("baseColor"),
                            ringColor: try c.color("ringColor"),
                            thumbColor: try c.color("thumbColor"),
                            ringWidth: Float(c.number("ringWidth")),
                            idleOpacity: Float(c.number("idleOpacity")),
                            activeOpacity: Float(c.number("activeOpacity")),
                            idleThumbOpacity: Float(c.number("idleThumbOpacity")),
                            activeThumbOpacity: Float(c.number("activeThumbOpacity"))
                        )
                    )
                )
            },
            view("TriggerButton", [string("title", "Action"), .init("sequence", type: .number, defaultValue: .number(0), isBinding: true)]) { c in
                guard let value = c.bindings["sequence"] else {
                    throw UIDiagnostic("TriggerButton requires a sequence binding.")
                }
                return AnyView(Button(c.string("title")) { value.wrappedValue = .number((value.wrappedValue.number ?? 0) + 1) })
            },
            view("ToggleButton", [string("title", "Toggle"), .init("isOn", type: .bool, defaultValue: .bool(false), isBinding: true)], content: .children) { c in
                guard let binding = c.bindings["isOn"] else {
                    throw UIDiagnostic("ToggleButton requires an isOn binding.")
                }
                return AnyView(
                    Button(action: { binding.wrappedValue = .bool(!(binding.wrappedValue.bool ?? false)) }, label: {
                        if c.children.isEmpty {
                            AnyView(Text(c.string("title")))
                        } else {
                            AnyView(c.content)
                        }
                    })
                )
            },
            view("TextField", [string("placeholder"), .init("text", type: .string, defaultValue: .string(""), isBinding: true)]) { c in
                AnyView(TextField(c.string("placeholder"), text: c.textBinding("text")))
            },
            view("TextEditor", [.init("text", type: .string, defaultValue: .string(""), isBinding: true)]) { AnyView(TextEditor(text: $0.textBinding("text"))) },
            view("SearchBar", [string("prompt", "Search"), .init("text", type: .string, defaultValue: .string(""), isBinding: true)]) {
                AnyView(SearchBar(text: $0.textBinding("text"), prompt: $0.string("prompt")))
            },
            view("Rectangle", [color("color", "#ffffffff")]) { AnyView(RectangleShape().fill(try $0.color("color"))) },
            view("RoundedRectangle", [number("cornerRadius", 8), color("color", "#ffffffff")]) {
                AnyView(RoundedRectangleShape(cornerRadius: Float($0.number("cornerRadius"))).fill(try $0.color("color")))
            },
            view("Circle", [color("color", "#ffffffff")]) { AnyView(Circle().fill(try $0.color("color"))) },
            view("Color", [color("color", "#ffffffff")]) { AnyView(try $0.color("color")) },
            // Structural entries are interpreted by UISceneInstance, with the same metadata used by the editor.
            view("If", [.init("condition", type: .bool, defaultValue: .bool(true))], content: .children) { AnyView($0.content) },
            view("ForEach", [.init("items", type: .array, defaultValue: .array([])), string("idKey", "id")], content: .single) { AnyView($0.content) },
            view("UI", [string("path")]) { _ in AnyView(EmptyView()) },
        ]
    }
}

extension UIFactoryContext {
    var horizontalAlignment: HorizontalAlignment {
        switch string("alignment") {
        case "leading": .leading
        case "trailing": .trailing
        default: .center
        }
    }
    var verticalAlignment: VerticalAlignment {
        switch string("alignment") {
        case "top": .top
        case "bottom": .bottom
        default: .center
        }
    }
    var alignment: Alignment {
        switch string("alignment") {
        case "leading": .leading
        case "trailing": .trailing
        case "top": .top
        case "bottom": .bottom
        case "topLeading": .topLeading
        case "topTrailing": .topTrailing
        case "bottomLeading": .bottomLeading
        case "bottomTrailing": .bottomTrailing
        default: .center
        }
    }
    var anchor: AnchorPoint {
        switch string("alignment") {
        case "leading": .leading
        case "trailing": .trailing
        case "top": .top
        case "bottom": .bottom
        case "topLeading": .topLeading
        case "topTrailing": .topTrailing
        case "bottomLeading": .bottomLeading
        case "bottomTrailing": .bottomTrailing
        default: .center
        }
    }
}
