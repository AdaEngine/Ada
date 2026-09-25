@_spi(AdaEngine) import AdaEngine
import Foundation
import Observation

@Observable
@MainActor
final class EditorAppearanceSettings {
    static let shared = EditorAppearanceSettings()
    private static let glowKey = "AdaEditor.appearance.agentActivityGlowEnabled"
    private static let indentationMarkersKey = "AdaEditor.editor.showsIndentationMarkers"
    private static let indentationGuidesKey = "AdaEditor.editor.showsIndentationGuides"
    private static let tabMarkersKey = "AdaEditor.editor.showsTabMarkers"
    private static let spaceMarkersKey = "AdaEditor.editor.showsSpaceMarkers"
    private static let accentKey = "AdaEditor.appearance.agentGlowAccent"
    private static let radiusKey = "AdaEditor.appearance.agentGlowRadius"
    private static let opacityKey = "AdaEditor.appearance.agentGlowOpacity"
    static let defaultRadius: Double = 24
    static let defaultOpacity: Double = 0.45
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var agentGlowAccentHex: String?
    private var radius: Double
    private var opacity: Double

    var agentActivityGlowEnabled: Bool {
        didSet { defaults.set(agentActivityGlowEnabled, forKey: Self.glowKey) }
    }

    var showsIndentationGuides: Bool {
        didSet { defaults.set(showsIndentationGuides, forKey: Self.indentationGuidesKey) }
    }

    var showsTabMarkers: Bool {
        didSet { defaults.set(showsTabMarkers, forKey: Self.tabMarkersKey) }
    }

    var showsSpaceMarkers: Bool {
        didSet { defaults.set(showsSpaceMarkers, forKey: Self.spaceMarkersKey) }
    }

    var showsIndentationMarkers: Bool {
        get { showsIndentationGuides && showsTabMarkers && showsSpaceMarkers }
        set {
            showsIndentationGuides = newValue
            showsTabMarkers = newValue
            showsSpaceMarkers = newValue
            defaults.set(newValue, forKey: Self.indentationMarkersKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        agentActivityGlowEnabled = defaults.object(forKey: Self.glowKey) as? Bool ?? true
        let legacyMarkers = defaults.object(forKey: Self.indentationMarkersKey) as? Bool ?? true
        showsIndentationGuides = defaults.object(forKey: Self.indentationGuidesKey) as? Bool ?? legacyMarkers
        showsTabMarkers = defaults.object(forKey: Self.tabMarkersKey) as? Bool ?? legacyMarkers
        showsSpaceMarkers = defaults.object(forKey: Self.spaceMarkersKey) as? Bool ?? legacyMarkers
        let hex = defaults.string(forKey: Self.accentKey)
        agentGlowAccentHex = hex.flatMap { EditorInspectorColorValue(hexText: $0) == nil ? nil : $0 }
        radius = Self.clamp(defaults.object(forKey: Self.radiusKey) as? Double ?? Self.defaultRadius, to: 4...100, fallback: Self.defaultRadius)
        opacity = Self.clamp(defaults.object(forKey: Self.opacityKey) as? Double ?? Self.defaultOpacity, to: 0...1, fallback: Self.defaultOpacity)
    }

    var agentGlowRadius: Double {
        get { radius }
        set {
            radius = Self.clamp(newValue, to: 4...100, fallback: Self.defaultRadius)
            defaults.set(radius, forKey: Self.radiusKey)
        }
    }

    var agentGlowOpacity: Double {
        get { opacity }
        set {
            opacity = Self.clamp(newValue, to: 0...1, fallback: Self.defaultOpacity)
            defaults.set(opacity, forKey: Self.opacityKey)
        }
    }

    func accentColor(fallback: Color) -> Color {
        guard let hex = agentGlowAccentHex, let value = EditorInspectorColorValue(hexText: hex) else {
            return fallback
        }
        return Color(red: value.red, green: value.green, blue: value.blue)
    }

    func setAccentColor(_ color: Color) {
        guard color.red.isFinite, color.green.isFinite, color.blue.isFinite else {
            return
        }
        let value = EditorInspectorColorValue(red: color.red, green: color.green, blue: color.blue, alpha: 1)
        agentGlowAccentHex = String(value.hexString.prefix(7))
        defaults.set(agentGlowAccentHex, forKey: Self.accentKey)
    }

    func useThemeAccent() {
        agentGlowAccentHex = nil
        defaults.removeObject(forKey: Self.accentKey)
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }
}

struct EditorCodeDisplaySettings: View {
    var settings: EditorAppearanceSettings = .shared
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Show indentation marks", isOn: Binding(
                get: { settings.showsIndentationMarkers },
                set: { settings.showsIndentationMarkers = $0 }
            ))
            .toggleStyle(.editorSettings(colors: theme.editorColors))
            .accessibilityIdentifier("AdaEditor.Settings.IndentationMarkers")

            settingToggle(
                "Indentation guides",
                isOn: Binding(
                    get: { settings.showsIndentationGuides },
                    set: { settings.showsIndentationGuides = $0 }
                ),
                identifier: "IndentationGuides"
            )
            settingToggle(
                "Tab markers",
                isOn: Binding(
                    get: { settings.showsTabMarkers },
                    set: { settings.showsTabMarkers = $0 }
                ),
                identifier: "TabMarkers"
            )
            settingToggle(
                "Space markers",
                isOn: Binding(
                    get: { settings.showsSpaceMarkers },
                    set: { settings.showsSpaceMarkers = $0 }
                ),
                identifier: "SpaceMarkers"
            )
        }
    }

    private func settingToggle(_ title: String, isOn: Binding<Bool>, identifier: String) -> some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(.editorSettings(colors: theme.editorColors))
            .accessibilityIdentifier("AdaEditor.Settings.\(identifier)")
    }
}

struct EditorAgentGlowSettings: View {
    var settings: EditorAppearanceSettings = .shared
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Agent activity glow", isOn: Binding(
                get: { settings.agentActivityGlowEnabled },
                set: { settings.agentActivityGlowEnabled = $0 }
            ))
            .toggleStyle(.editorSettings(colors: theme.editorColors))
            .accessibilityIdentifier("AdaEditor.Settings.AgentActivityGlow")
            Text("Show colored window edges while an agent works or needs attention. Applies immediately to all editor windows.")
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.muted)
            VStack(alignment: .leading, spacing: 6) {
                Text("Accent color").font(.system(size: 13))
                EditorUIColorField(value: accentHex, supportsAlpha: false) { value in
                    if let color = EditorUIColorField.color(value) {
                        settings.setAccentColor(color)
                    }
                }
                .accessibilityIdentifier("AdaEditor.Settings.AgentGlow.Accent")
                Button("Use theme color") { settings.useThemeAccent() }
                    .font(.system(size: 11))
                    .accessibilityIdentifier("AdaEditor.Settings.AgentGlow.ThemeAccent")
            }
            valueControl("Effect radius", value: settings.agentGlowRadius, unit: "px", step: 2, id: "Radius") {
                settings.agentGlowRadius = $0
            }
            valueControl("Opacity", value: settings.agentGlowOpacity * 100, unit: "%", step: 5, id: "Opacity") {
                settings.agentGlowOpacity = $0 / 100
            }
            Text("Radius controls the inward glow width (4–100 px). Success, attention and error keep their status colors. Success fades out after 3 seconds.")
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.muted)
        }
    }

    private var accentHex: String {
        let color = settings.accentColor(fallback: theme.editorColors.blue)
        return String(EditorInspectorColorValue(red: color.red, green: color.green, blue: color.blue, alpha: 1).hexString.prefix(7))
    }

    private func valueControl(_ title: String, value: Double, unit: String, step: Double, id: String, onChange: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 13))
            Spacer()
            Button("−") { onChange(value - step) }
                .frame(width: 28, height: 28)
                .accessibilityIdentifier("AdaEditor.Settings.AgentGlow.\(id).Decrease")
            TextField(
                "0",
                text: Binding(
                    get: { String(format: "%.0f", value) },
                    set: { text in
                        if let number = Double(text.replacingOccurrences(of: ",", with: ".")), number.isFinite {
                            onChange(number)
                        }
                    }
                )
            )
            .textFieldStyle(PlainTextFieldStyle())
            .font(.system(size: 12))
            .foregroundColor(theme.editorColors.text)
            .padding(.horizontal, 8)
            .frame(width: 52, height: 28)
            .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.surface))
            .overlay {
                RoundedRectangleShape(cornerRadius: 6).stroke(theme.editorColors.border, lineWidth: 1)
            }
            .accessibilityIdentifier("AdaEditor.Settings.AgentGlow.\(id)")
            Text(unit).font(.system(size: 11))
            Button("+") { onChange(value + step) }
                .frame(width: 28, height: 28)
                .accessibilityIdentifier("AdaEditor.Settings.AgentGlow.\(id).Increase")
        }
        .foregroundColor(theme.editorColors.text)
        .frame(height: 36)
    }
}
