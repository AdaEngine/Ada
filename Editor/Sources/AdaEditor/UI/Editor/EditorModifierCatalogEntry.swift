@_spi(AdaEngine) import AdaEngine

struct EditorModifierCatalogEntry: Identifiable {
    let signature: UIDescriptorSignature
    var id: String { signature.id }

    var category: String {
        switch id {
        case "padding",
            "frame",
            "flexibleFrame",
            "offset",
            "fixedSize",
            "layoutPriority",
            "aspectRatio",
            "ignoresSafeArea":
            "Layout"
        case "background",
            "foregroundColor",
            "border",
            "opacity",
            "mask",
            "overlay",
            "glassEffect",
            "drawingGroup",
            "zIndex",
            "colorScheme":
            "Appearance"
        case "fontSize",
            "lineLimit",
            "multilineTextAlignment":
            "Text"
        case "disabled",
            "allowsHitTesting",
            "buttonStyle",
            "textFieldStyle":
            "Controls"
        case "onAppear",
            "onDisappear",
            "onTap",
            "onChange":
            "Events"
        case "navigationTitle",
            "navigationDestination":
            "Navigation"
        case "accessibilityIdentifier": "Accessibility"
        default: "Custom"
        }
    }

    var description: String {
        switch id {
        case "padding": "Add space around the layer."
        case "frame": "Set width, height, and alignment."
        case "flexibleFrame": "Set minimum and maximum dimensions."
        case "offset": "Move the layer horizontally or vertically."
        case "fixedSize": "Keep the layer at its ideal size."
        case "layoutPriority": "Choose which layer gets space first."
        case "aspectRatio": "Fit or fill content at a fixed aspect ratio."
        case "ignoresSafeArea": "Extend content into the safe area."
        case "background": "Add a background color or views behind the layer."
        case "foregroundColor": "Set the foreground color."
        case "border": "Draw a border with a color and width."
        case "opacity": "Adjust transparency."
        case "mask": "Clip the layer to a shape."
        case "overlay": "Place views in front of the layer."
        case "glassEffect": "Apply a glass surface with rounded corners."
        case "drawingGroup": "Render the contents together as a group."
        case "zIndex": "Set the drawing order between overlapping layers."
        case "colorScheme": "Use a light or dark color scheme."
        case "fontSize": "Set the text size."
        case "lineLimit": "Limit the number of text lines."
        case "multilineTextAlignment": "Align text across multiple lines."
        case "disabled": "Enable or disable controls."
        case "allowsHitTesting": "Choose whether this layer receives pointer or touch input."
        case "buttonStyle": "Choose the appearance of buttons."
        case "textFieldStyle": "Choose the appearance of text fields."
        case "onAppear": "Run an action when the layer appears."
        case "onDisappear": "Run an action when the layer disappears."
        case "onTap": "Run an action when the layer is tapped."
        case "onChange": "Run an action when a value changes."
        case "navigationTitle": "Set the navigation title."
        case "navigationDestination": "Show a destination for a navigation value."
        case "accessibilityIdentifier": "Give the layer an identifier for accessibility and automation."
        default: signature.parameters.isEmpty ? "Apply this custom modifier." : "Parameters: " + signature.parameters.map(\.name).joined(separator: ", ")
        }
    }

    func matches(_ query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        let text = "\(signature.name) \(id) \(category) \(description)"
        return terms.allSatisfy { text.localizedCaseInsensitiveContains(String($0)) }
    }
}
