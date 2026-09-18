import AdaRender
import AdaText
import AdaUIDescription
import AdaUtils
import Math

extension UICatalog {
    static var builtinModifiers: [UINativeModifierDescriptor] {
        func modifier(
            _ name: String,
            _ parameters: [UIParameter] = [],
            content: UIContentShape = .none,
            actions: [UIActionSignature] = [],
            _ apply: @escaping @MainActor (AnyView, UIFactoryContext) throws -> AnyView
        ) -> UINativeModifierDescriptor {
            .init(signature: .init(id: name, name: name, parameters: parameters, actions: actions, content: content), apply: apply)
        }
        return [
            modifier(
                "textureButtonStyle",
                [string("normal"), string("highlighted"), string("pressed"), string("disabled"), bool("selectionEffect"), color("selectionColor", "#ffe08aff")] + imageCapParameters
            ) { view, c in
                guard let resources = c.resources else {
                    throw UIDiagnostic("Texture button style requires a UI resource context.")
                }
                let normal = try resources.image(c.string("normal"), relativeTo: c.sourceURL)
                @MainActor func optionalImage(_ key: String) throws -> AdaRender.Image? {
                    let path = c.string(key)
                    return path.isEmpty ? nil : try resources.image(path, relativeTo: c.sourceURL)
                }
                return AnyView(
                    view.buttonStyle(
                        TextureButtonStyle(
                            normal: normal,
                            highlighted: try optionalImage("highlighted"),
                            pressed: try optionalImage("pressed"),
                            disabled: try optionalImage("disabled"),
                            capInsets: try c.imageCapInsets(),
                            selectionEffect: c.bool("selectionEffect"),
                            selectionColor: try c.color("selectionColor")
                        )
                    )
                )
            },
            modifier("lineLimit", [number("value", 1)]) { AnyView($0.lineLimit(Int(max(0, min(10000, $1.number("value")))))) },
            modifier("multilineTextAlignment", [choice("value", "leading", ["leading", "center", "trailing"])]) {
                AnyView($0.multilineTextAlignment($1.string("value") == "center" ? .center : $1.string("value") == "trailing" ? .trailing : .leading))
            },
            modifier("aspectRatio", [number("value", 1), choice("mode", "fit", ["fit", "fill"])]) {
                AnyView($0.aspectRatio($1.float("value"), contentMode: $1.string("mode") == "fill" ? .fill : .fit))
            },
            modifier("ignoresSafeArea") { view, _ in AnyView(view.ignoresSafeArea()) },
            modifier("allowsHitTesting", [bool("value", true)]) { AnyView($0.allowsHitTesting($1.bool("value"))) },
            modifier("drawingGroup") { view, _ in AnyView(view.drawingGroup()) },
            modifier("glassEffect", [number("cornerRadius", 8)]) { AnyView($0.glassEffect(in: RoundedRectangleShape(cornerRadius: Float($1.number("cornerRadius"))))) },
            modifier("colorScheme", [choice("value", "dark", ["dark", "light"])]) { AnyView($0.environment(\.colorScheme, $1.string("value") == "light" ? .light : .dark)) },
            modifier("buttonStyle", [choice("value", "default", ["default", "glass"])]) { view, c in
                switch c.string("value") {
                case "glass": return AnyView(view.buttonStyle(GlassButtonStyle()))
                default: return AnyView(view.buttonStyle(DefaultButtonStyle()))
                }
            },
            modifier("textFieldStyle", [choice("value", "default", ["default", "plain"])]) { view, c in
                if c.string("value") == "plain" {
                    return AnyView(view.textFieldStyle(PlainTextFieldStyle()))
                }
                return AnyView(view.textFieldStyle(DefaultTextFieldStyle()))
            },
            modifier("navigationTitle", [string("value", "Title")]) { AnyView($0.navigationTitle($1.string("value"))) },
            modifier("navigationDestination", [string("value")], content: .single) { view, c in
                AnyView(
                    view.navigate(for: String.self) { value in
                        if value == c.string("value") {
                            AnyView(c.content)
                        } else {
                            AnyView(EmptyView())
                        }
                    }
                )
            },
            modifier("padding", [number("value", 8)]) { AnyView($0.padding(Float($1.number("value")))) },
            modifier("frame", [number("width"), number("height"), alignment()]) { AnyView($0.frame(width: $1.float("width"), height: $1.float("height"), alignment: $1.alignment)) },
            modifier("flexibleFrame", [number("minWidth"), number("maxWidth"), number("minHeight"), number("maxHeight"), alignment()]) {
                AnyView($0.frame(minWidth: $1.float("minWidth"), maxWidth: $1.float("maxWidth"), minHeight: $1.float("minHeight"), maxHeight: $1.float("maxHeight"), alignment: $1.alignment))
            },
            modifier("background", [color("color", "#000000ff")], content: .children) { view, c in
                if c.children.isEmpty {
                    return AnyView(view.background(try c.color("color")))
                }
                return AnyView(view.background { c.content })
            },
            modifier("overlay", content: .children) { view, c in AnyView(view.overlay { c.content }) },
            modifier("mask", [choice("shape", "rectangle", ["rectangle", "circle", "roundedRectangle"]), number("cornerRadius", 8)]) { view, c in
                switch c.string("shape") {
                case "circle": return AnyView(view.mask(Circle()))
                case "roundedRectangle": return AnyView(view.mask(RoundedRectangleShape(cornerRadius: Float(c.number("cornerRadius")))))
                default: return AnyView(view.mask(RectangleShape()))
                }
            },
            modifier("foregroundColor", [color("color", "#ffffffff")]) { AnyView($0.foregroundColor(try $1.color("color"))) },
            modifier("fontSize", [number("value", 14)]) { AnyView($0.fontSize($1.number("value"))) },
            modifier("opacity", [number("value", 1)]) { AnyView($0.opacity(Float($1.number("value")))) },
            modifier("border", [color("color", "#ffffffff"), number("width", 1)]) { AnyView($0.border(try $1.color("color"), lineWidth: Float($1.number("width")))) },
            modifier("disabled", [bool("value", true)]) { AnyView($0.disabled($1.bool("value"))) },
            modifier("fixedSize", [bool("horizontal", true), bool("vertical", true)]) { AnyView($0.fixedSize(horizontal: $1.bool("horizontal"), vertical: $1.bool("vertical"))) },
            modifier("layoutPriority", [number("value", 0)]) { AnyView($0.layoutPriority($1.number("value"))) },
            modifier("zIndex", [number("value", 0)]) { AnyView($0.zIndex(Int(max(-2_147_483_648, min(2_147_483_647, $1.number("value")))))) },
            modifier("offset", [number("x", 0), number("y", 0)]) { AnyView($0.offset(x: Float($1.number("x")), y: Float($1.number("y")))) },
            modifier("accessibilityIdentifier", [string("value")]) { AnyView($0.accessibilityIdentifier($1.string("value"))) },
            modifier("onAppear", actions: [.init("action")]) { view, c in AnyView(view.onAppear { c.perform("action") }) },
            modifier("onDisappear", actions: [.init("action")]) { view, c in AnyView(view.onDisappear { c.perform("action") }) },
            modifier("onTap", actions: [.init("action")]) { view, c in AnyView(view.onTapGesture { c.perform("action") }) },
            modifier(
                "onChange",
                [.init("value", type: .any, defaultValue: .null)],
                actions: [.init("action", parameters: [.init("oldValue", type: .any), .init("newValue", type: .any)])]
            ) { view, c in
                AnyView(view.onChange(of: c.arguments["value"] ?? .null) { old, new in c.perform("action", arguments: ["oldValue": old, "newValue": new]) })
            },
        ]
    }
}
