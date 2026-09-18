@_spi(AdaEngine) import AdaEngine
import Foundation

extension EditorComponentRegistry {
    static let physicsBody2DDescriptor = EditorComponentDescriptor(
        typeName: EditorBuiltInComponentType.physicsBody2D,
        displayName: "Physics Body 2D",
        category: "Physics",
        description: "Simulates a 2D body with collision shapes, material, and motion settings.",
        requiredComponentTypeNames: [EditorBuiltInComponentType.transform],
        fields: [
            physicsField("mode", "Mode", .enumeration(["static", "dynamic", "kinematic"]), .enumCase),
            physicsField("isTrigger", "Sensor", .bool),
            physicsField("fixedRotation", "Fixed Rotation", .bool, defaultValue: .bool(false)),
            physicsField("gravityScale", "Gravity Scale", .float, defaultValue: .double(1)),
            physicsField("linearVelocity", "Linear Velocity", .vector2, .vectorObject, defaultValue: .object(["x": .double(0), "y": .double(0)])),
            physicsField("angularVelocity", "Angular Velocity", .float, defaultValue: .double(0)),
            physicsField("material.friction", "Friction", .float),
            physicsField("material.restitution", "Restitution", .float),
            physicsField("material.density", "Density", .float),
            physicsField("massProperties.mass", "Mass", .float),
            physicsField("massProperties.inertia.z", "Rotational Inertia (0 = auto)", .float),
            physicsField("filter.categoryBitMask", "Collision Category", .string, .unsignedInteger),
            physicsField("filter.collisionBitMask", "Collision Mask", .string, .unsignedInteger),
            physicsField("debugColor", "Debug Color", .color, defaultValue: .object(["red": .double(1), "green": .double(1), "blue": .double(1), "alpha": .double(1)])),
            physicsField("shapes", "Shapes", .string, .json),
        ],
        makeDefaultPayload: {
            [
                "mode": .object(["dynamic": .object([:])]),
                "filter": .object(["categoryBitMask": .uint(1), "collisionBitMask": .uint(UInt64.max)]),
                "material": .object(["friction": .double(0.6), "restitution": .double(0), "density": .double(1)]),
                "massProperties": .object(["mass": .double(1), "inertia": .object(["x": .double(0), "y": .double(0), "z": .double(0)])]),
                "shapes": .array([EditorPhysicsShapeValue.make(.box)]),
                "isTrigger": .bool(false), "fixedRotation": .bool(false), "gravityScale": .double(1),
                "linearVelocity": .object(["x": .double(0), "y": .double(0)]), "angularVelocity": .double(0),
            ]
        },
        decode: { payload in
            try EditorComponentPayloadDecoder.decode(PhysicsBody2DComponent.self, payload: resolvedPhysicsPayload(payload)) as! PhysicsBody2DComponent
        }
    )

    static func resolvedPhysicsPayload(_ payload: EditorComponentPayload, is3D: Bool = false) -> EditorComponentPayload {
        var result = (is3D ? physicsBody3DDescriptor : physicsBody2DDescriptor).makeDefaultPayload()
        for (key, value) in payload {
            if case let .object(defaults) = result[key], case let .object(incoming) = value, key != "mode" {
                result[key] = .object(defaults.merging(incoming) { _, new in new })
            } else {
                result[key] = value
            }
        }
        return result
    }

    static func physicsField(
        _ key: String,
        _ label: String,
        _ kind: EditorComponentFieldKind,
        _ coding: EditorComponentFieldCoding = .standard,
        defaultValue: EditorSceneValue? = nil
    ) -> EditorComponentField {
        var field = EditorComponentField(key: key, label: label, kind: kind)
        field.valuePath = key.split(separator: ".").map(String.init)
        field.coding = coding
        field.defaultValue = defaultValue
        if key.hasPrefix("material.") || key.hasPrefix("massProperties.") {
            field.minimumValue = 0
        }
        return field
    }
}
