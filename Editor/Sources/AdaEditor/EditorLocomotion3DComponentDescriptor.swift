@_spi(AdaEngine) import AdaEngine
import Foundation

enum EditorLocomotionGroup: String, CaseIterable, Identifiable {
    case facing = "Facing"
    case clips = "Clips"
    case directional = "Directional clips"
    case timing = "Timing and speed"

    var id: String { rawValue }
}

enum EditorInspectorNumberRule: Equatable, Sendable {
    case positiveFloat
    case positiveDouble
    case nonnegativeDouble

    func value(_ text: String) -> Double? {
        guard let number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), number.isFinite else {
            return nil
        }
        let isValid = switch self {
        case .positiveFloat: Float(number).isFinite && Float(number) > 0
        case .positiveDouble: number > 0
        case .nonnegativeDouble: number >= 0
        }
        return isValid ? number : nil
    }
}

extension EditorComponentRegistry {
    static let locomotion3DDescriptor = EditorComponentDescriptor(
        typeName: EditorBuiltInComponentType.locomotion3D,
        displayName: "3D Locomotion",
        category: "3D",
        description: "Selects movement clips from the character's resolved motion.",
        requiredComponentTypeNames: [],
        fields: locomotionFields(),
        makeDefaultPayload: { ["isEnabled": .bool(true)] },
        decode: { payload in
            try JSONDecoder().decode(CharacterLocomotion3DComponent.self, from: JSONEncoder().encode(payload))
        }
    )

    private static func locomotionFields() -> [EditorComponentField] {
        let defaults = CharacterLocomotion3DComponent.Configuration()
        return [
            locomotionField("isEnabled", "Enabled", .bool, .bool(true), .facing),
            locomotionField(
                "configuration.facingMode",
                "Facing mode",
                .enumeration(["turnToMovement", "keepFacing"]),
                .string(defaults.facingMode.rawValue),
                .facing
            ),
            locomotionField(
                "configuration.forwardAxis",
                "Model forward axis",
                .enumeration(["positiveZ", "positiveX", "negativeZ", "negativeX"]),
                .string(defaults.forwardAxis.rawValue),
                .facing
            ),
            locomotionField("configuration.clips.idle", "Locomotion idle", .string, .string(defaults.clips.idle), .clips),
            locomotionField("configuration.clips.walk", "Locomotion walk", .string, .string(defaults.clips.walk), .clips),
            locomotionField("configuration.clips.run", "Locomotion run", .string, .string(defaults.clips.run), .clips),
            locomotionField("configuration.clips.jump", "Locomotion jump", .string, .string(defaults.clips.jump), .clips),
            locomotionField("configuration.clips.fall", "Locomotion fall", .string, .string(defaults.clips.fall), .clips),
            locomotionField("configuration.clips.land", "Locomotion land", .string, .string(defaults.clips.land), .clips),
            locomotionField("configuration.left.walk", "Walk left", .string, .null, .directional),
            locomotionField("configuration.left.run", "Run left", .string, .null, .directional),
            locomotionField("configuration.right.walk", "Walk right", .string, .null, .directional),
            locomotionField("configuration.right.run", "Run right", .string, .null, .directional),
            locomotionField("configuration.back.walk", "Walk backward", .string, .null, .directional),
            locomotionField("configuration.back.run", "Run backward", .string, .null, .directional),
            locomotionNumber("walkReferenceSpeed", "Walk reference (m/s)", Double(defaults.walkReferenceSpeed), .positiveFloat),
            locomotionNumber("runReferenceSpeed", "Run reference (m/s)", Double(defaults.runReferenceSpeed), .positiveFloat),
            locomotionNumber("gaitTransitionDuration", "Gait fade (s)", defaults.gaitTransitionDuration, .nonnegativeDouble),
            locomotionNumber("airTransitionDuration", "Air fade (s)", defaults.airTransitionDuration, .nonnegativeDouble),
            locomotionNumber("landingDuration", "Landing duration (s)", defaults.landingDuration, .positiveDouble),
        ]
    }

    private static func locomotionField(
        _ key: String,
        _ label: String,
        _ kind: EditorComponentFieldKind,
        _ value: EditorSceneValue,
        _ group: EditorLocomotionGroup
    ) -> EditorComponentField {
        var field = EditorComponentField(key: key, label: label, kind: kind, groupPath: [group.rawValue])
        field.valuePath = key.split(separator: ".").map(String.init)
        field.defaultValue = value
        return field
    }

    private static func locomotionNumber(
        _ key: String,
        _ label: String,
        _ value: Double,
        _ rule: EditorInspectorNumberRule
    ) -> EditorComponentField {
        var field = locomotionField("configuration.\(key)", label, .float, .double(value), .timing)
        field.numberRule = rule
        return field
    }
}
