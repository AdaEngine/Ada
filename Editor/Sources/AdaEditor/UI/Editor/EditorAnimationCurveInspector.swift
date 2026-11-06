@_spi(AdaEngine) import AdaEngine
import Foundation

/// An explicit key transaction: text drafts never mutate playback until Apply succeeds.
struct EditorAnimationCurveInspector: View {
    let model: EditorAnimationTimelineModel
    let track: AnimationLibraryTrack
    let key: AnimationLibraryKey
    @State private var family = "linear"
    @State private var direction = "inOut"
    @State private var overshoot = "1.70158"
    @State private var amplitude = "1"
    @State private var period = "0.3"
    @State private var component = 0
    @State private var handleDrafts: [String: String] = [:]
    @State private var revision = ""
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("Outgoing segment easing")).font(.system(size: 11, weight: .semibold))
            EditorEnumField(cases: AnimationEasing.Family.allCases.map(\.rawValue), selection: $family,
                accessibilityID: "AdaEditor.Animation.Key.Easing.Family")
            EditorEnumField(cases: AnimationEasing.Direction.allCases.map(\.rawValue), selection: $direction,
                accessibilityID: "AdaEditor.Animation.Key.Easing.Direction")
            if family == "back" { field("Overshoot", text: $overshoot, id: "Easing.Overshoot") }
            if family == "elastic" {
                field("Amplitude", text: $amplitude, id: "Easing.Amplitude")
                field("Period", text: $period, id: "Easing.Period")
            }
            if track.interpolation == .bezier, track.channel != .rotation {
                Text(L10n.tr("Bezier handles")).font(.system(size: 11, weight: .semibold))
                EditorEnumField(cases: key.value.indices.map(String.init), selection: Binding(get: { String(component) }, set: { component = Int($0) ?? 0 }),
                    accessibilityID: "AdaEditor.Animation.Key.Bezier.Component", labels: componentLabels, localizesValues: false)
                Text(L10n.tr("Handle offsets use seconds and value units.")).font(.system(size: 10)).foregroundColor(theme.editorColors.muted)
                if neighbor(incoming: true) != nil { handleFields(incoming: true) }
                if neighbor(incoming: false) != nil { handleFields(incoming: false) }
            }
            Button { model.perform { try apply() } } label: {
                Text(L10n.tr("Apply Curve")).font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(EditorAnimationButtonStyle(colors: theme.editorColors, prominent: true))
                .accessibilityIdentifier("AdaEditor.Animation.Key.Curve.Apply")
        }.disabled(!model.isEditable || track.interpolation == .step)
            .onAppear { synchronize() }
            .onChange(of: key.id) { _, _ in synchronize() }
            .onChange(of: track.id) { _, _ in synchronize() }
            .onChange(of: model.workspace?.library?.revision) { _, _ in synchronize() }
    }

    private var componentLabels: [String: String] {
        key.value.indices.reduce(into: [:]) { values, index in
            values[String(index)] = track.channel == .weights ? String(index) : ["X", "Y", "Z", "W"][index]
        }
    }

    private func neighbor(incoming: Bool) -> AnimationLibraryKey? {
        guard let index = track.keys.firstIndex(where: { $0.id == key.id }) else { return nil }
        let next = index + (incoming ? -1 : 1)
        return track.keys.indices.contains(next) ? track.keys[next] : nil
    }

    private func handle(incoming: Bool, component: Int) -> AnimationBezierHandle {
        let values = incoming ? key.curve?.incoming : key.curve?.outgoing
        if let values, values.indices.contains(component) { return values[component] }
        guard let other = neighbor(incoming: incoming), key.value.indices.contains(component), other.value.indices.contains(component) else {
            return .init(timeOffset: 0, valueOffset: 0)
        }
        return .init(timeOffset: (other.time - key.time) / 3, valueOffset: (Double(other.value[component]) - Double(key.value[component])) / 3)
    }

    private func handleFields(incoming: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.tr(incoming ? "Incoming handle" : "Outgoing handle")).font(.system(size: 10, weight: .semibold))
            field("Time offset", text: handleBinding(incoming: incoming, time: true), id: "Bezier.\(incoming ? "Incoming" : "Outgoing").Time")
            field("Value offset", text: handleBinding(incoming: incoming, time: false), id: "Bezier.\(incoming ? "Incoming" : "Outgoing").Value")
        }
    }

    private func handleBinding(incoming: Bool, time: Bool) -> Binding<String> {
        let id = "\(component):\(incoming):\(time)"
        return Binding(get: {
            let value = handle(incoming: incoming, component: component)
            return handleDrafts[id] ?? String(time ? value.timeOffset : value.valueOffset)
        }, set: { handleDrafts[id] = $0 })
    }

    private func apply() throws {
        guard let clip = model.clip, let family = AnimationEasing.Family(rawValue: family), let direction = AnimationEasing.Direction(rawValue: direction),
              let overshoot = Double(overshoot), let amplitude = Double(amplitude), let period = Double(period) else { throw invalidInput() }
        var edited = key, curve = key.curve ?? .init()
        curve.easing = .init(family: family, direction: direction, overshoot: overshoot, amplitude: amplitude, period: period)
        if track.interpolation == .bezier {
            for incoming in [true, false] where neighbor(incoming: incoming) != nil {
                let handles = try key.value.indices.map { index -> AnimationBezierHandle in
                    let original = handle(incoming: incoming, component: index)
                    guard let time = Double(handleDrafts["\(index):\(incoming):true"] ?? String(original.timeOffset)),
                          let value = Double(handleDrafts["\(index):\(incoming):false"] ?? String(original.valueOffset)), time.isFinite, value.isFinite else { throw invalidInput() }
                    return .init(timeOffset: time, valueOffset: value)
                }
                if incoming { curve.incoming = handles } else { curve.outgoing = handles }
            }
        }
        edited.curve = curve
        try model.apply([.init(kind: .putKey, clipID: clip.id, trackID: track.id, key: edited, replaceExisting: true)], revision: revision)
    }

    private func synchronize() {
        let easing = key.curve?.easing ?? .init()
        family = easing.family.rawValue; direction = easing.direction.rawValue
        overshoot = String(easing.overshoot); amplitude = String(easing.amplitude); period = String(easing.period)
        component = min(component, max(0, key.value.count - 1)); handleDrafts = [:]
        revision = model.workspace?.library?.revision ?? ""
    }

    private func invalidInput() -> AnimationAuthoringError {
        .init(.invalidCurve, itemID: key.id, message: L10n.tr("Enter finite numeric values for every component."))
    }

    private func field(_ title: String, text: Binding<String>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.tr(title)).font(.system(size: 10)).foregroundColor(theme.editorColors.muted)
            TextField(L10n.tr(title), text: text).textFieldStyle(EditorAnimationFieldStyle(colors: theme.editorColors))
                .accessibilityIdentifier("AdaEditor.Animation.Key." + id)
        }
    }
}
