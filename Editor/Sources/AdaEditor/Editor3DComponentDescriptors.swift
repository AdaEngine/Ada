@_spi(AdaEngine) import AdaEngine
import Foundation

extension EditorComponentRegistry {
    static let physicsBody3DDescriptor = EditorComponentDescriptor(
        typeName: EditorBuiltInComponentType.physicsBody3D,
        displayName: "Physics Body 3D",
        category: "3D",
        description: "Simulates a 3D body with box or sphere collision shapes, material, and initial motion.",
        requiredComponentTypeNames: [EditorBuiltInComponentType.transform],
        fields: [
            physicsField("mode", "Mode", .enumeration(["static", "dynamic", "kinematic"]), .enumCase),
            physicsField("isTrigger", "Sensor", .bool),
            physicsField("gravityScale", "Gravity Scale", .float, defaultValue: .double(1)),
            physicsField("linearVelocity", "Linear Velocity", .vector3, .vectorObject),
            physicsField("angularVelocity", "Angular Velocity", .vector3, .vectorObject),
            physicsField("material.friction", "Friction", .float),
            physicsField("material.restitution", "Restitution", .float),
            physicsField("material.density", "Density", .float),
            physicsField("massProperties.mass", "Mass", .float),
            physicsField("shapes", "Shapes", .string, .json),
        ],
        makeDefaultPayload: {
            let zero = EditorSceneValue.object(["x": .double(0), "y": .double(0), "z": .double(0)])
            return [
                "mode": .object(["dynamic": .object([:])]), "isTrigger": .bool(false),
                "gravityScale": .double(1), "linearVelocity": zero, "angularVelocity": zero,
                "material": .object(["friction": .double(0.6), "restitution": .double(0), "density": .double(1)]),
                "massProperties": .object(["mass": .double(1), "inertia": zero]),
                "shapes": .array([EditorPhysicsShapeValue.make(.box, is3D: true)]),
            ]
        },
        decode: { payload in
            try EditorComponentPayloadDecoder.decode(PhysicsBody3DComponent.self, payload: resolvedPhysicsPayload(payload, is3D: true)) as! PhysicsBody3DComponent
        }
    )

    static let directionalLight3DDescriptor = EditorComponentDescriptor(
        typeName: EditorBuiltInComponentType.directionalLight3D,
        displayName: "Directional Light 3D",
        category: "3D",
        description: "Lights 3D meshes with directional light and shadows. Rotate the entity to aim the light.",
        requiredComponentTypeNames: [EditorBuiltInComponentType.transform],
        fields: [
            EditorComponentField(key: "radiance", label: "Radiance (RGB)", kind: .vector3),
            EditorComponentField(key: "intensity", label: "Intensity", kind: .float),
            EditorComponentField(key: "castShadows", label: "Cast Shadows", kind: .bool),
            EditorComponentField(key: "shadowDistance", label: "Shadow Distance", kind: .float),
            EditorComponentField(key: "shadowBias", label: "Shadow Bias", kind: .float),
            EditorComponentField(key: "shadowSlopeBias", label: "Shadow Slope Bias", kind: .float),
        ],
        makeDefaultPayload: {
            [
                "radiance": .array([.double(1), .double(1), .double(1)]), "intensity": .double(1), "castShadows": .bool(true),
                "shadowDistance": .double(30), "shadowBias": .double(0.0008), "shadowSlopeBias": .double(0.003),
            ]
        },
        decode: { payload in
            let radiance: Vector3
            if case let .array(values) = payload["radiance"], values.count == 3 {
                radiance = Vector3(Float(values[0].doubleValue ?? 1), Float(values[1].doubleValue ?? 1), Float(values[2].doubleValue ?? 1))
            } else {
                radiance = .one
            }
            return DirectionalLightComponent(
                radiance: radiance,
                intensity: Float(payload["intensity"]?.doubleValue ?? 1),
                castShadows: payload["castShadows"]?.boolValue ?? true,
                shadowDistance: Float(payload["shadowDistance"]?.doubleValue ?? 30),
                shadowBias: Float(payload["shadowBias"]?.doubleValue ?? 0.0008),
                shadowSlopeBias: Float(payload["shadowSlopeBias"]?.doubleValue ?? 0.003)
            )
        }
    )

    static let pointLight3DDescriptor = localLight3DDescriptor(
        typeName: EditorBuiltInComponentType.pointLight3D,
        displayName: "Point Light 3D",
        description: "Lights 3D meshes in every direction from the entity position.",
        makeComponent: { radiance, intensity, castShadows in
            PointLightComponent(radiance: radiance, intensity: intensity, castShadows: castShadows)
        }
    )

    static let spotLight3DDescriptor = localLight3DDescriptor(
        typeName: EditorBuiltInComponentType.spotLight3D,
        displayName: "Spot Light 3D",
        description: "Lights 3D meshes from a focused entity-mounted source.",
        makeComponent: { radiance, intensity, castShadows in
            SpotLightComponent(radiance: radiance, intensity: intensity, castShadows: castShadows)
        }
    )

    private static func localLight3DDescriptor(
        typeName: String,
        displayName: String,
        description: String,
        makeComponent: @escaping @Sendable (Vector3, Float, Bool) -> any Component
    ) -> EditorComponentDescriptor {
        EditorComponentDescriptor(
            typeName: typeName,
            displayName: displayName,
            category: "3D",
            description: description,
            requiredComponentTypeNames: [EditorBuiltInComponentType.transform],
            fields: [
                EditorComponentField(key: "radiance", label: "Radiance (RGB)", kind: .vector3),
                EditorComponentField(key: "intensity", label: "Intensity", kind: .float),
                EditorComponentField(key: "castShadows", label: "Cast Shadows", kind: .bool),
            ],
            makeDefaultPayload: {
                [
                    "radiance": .array([.double(1), .double(1), .double(1)]),
                    "intensity": .double(1),
                    "castShadows": .bool(true),
                ]
            },
            decode: { payload in
                makeComponent(
                    vector3(from: payload["radiance"]),
                    Float(payload["intensity"]?.doubleValue ?? 1),
                    payload["castShadows"]?.boolValue ?? true
                )
            }
        )
    }

    private static func vector3(from value: EditorSceneValue?) -> Vector3 {
        guard case let .array(values) = value, values.count == 3 else {
            return .one
        }
        return Vector3(
            Float(values[0].doubleValue ?? 1),
            Float(values[1].doubleValue ?? 1),
            Float(values[2].doubleValue ?? 1)
        )
    }
}
