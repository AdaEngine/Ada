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
        description: "Lights meshes in all directions. Range is in meters; intensity is a linear multiplier at one meter.",
        isSpot: false,
        decode: { payload in try EditorComponentPayloadDecoder.decode(PointLightComponent.self, payload: payload) as! PointLightComponent }
    )

    static let spotLight3DDescriptor = localLight3DDescriptor(
        typeName: EditorBuiltInComponentType.spotLight3D,
        displayName: "Spot Light 3D",
        description: "Lights a cone along local +Z. Cone fields are half-angles in degrees; rotate the entity to aim.",
        isSpot: true,
        decode: { payload in try EditorComponentPayloadDecoder.decode(SpotLightComponent.self, payload: payload) as! SpotLightComponent }
    )

    private static func localLight3DDescriptor(
        typeName: String,
        displayName: String,
        description: String,
        isSpot: Bool,
        decode: @escaping @Sendable ([String: EditorSceneValue]) throws -> any Component
    ) -> EditorComponentDescriptor {
        var fields: [EditorComponentField] = [
            .init(key: "radiance", label: "Radiance (RGB)", kind: .vector3),
            .init(key: "intensity", label: "Intensity at 1 m", kind: .float),
            .init(key: "range", label: "Range (m)", kind: .float),
            .init(key: "castShadows", label: "Cast Shadows", kind: .bool),
            .init(key: "shadowBias", label: "Shadow Bias", kind: .float),
            .init(key: "shadowSlopeBias", label: "Shadow Slope Bias", kind: .float),
            .init(key: "shadowPriority", label: "Shadow Priority", kind: .int),
        ]
        if isSpot {
            fields.append(.init(key: "innerConeAngle", label: "Inner Half Angle (degrees)", kind: .float))
            fields.append(.init(key: "outerConeAngle", label: "Outer Half Angle (degrees)", kind: .float))
        }
        return EditorComponentDescriptor(
            typeName: typeName,
            displayName: displayName,
            category: "3D",
            description: description,
            requiredComponentTypeNames: [EditorBuiltInComponentType.transform],
            fields: fields,
            makeDefaultPayload: {
                var payload: [String: EditorSceneValue] = [
                    "radiance": .array([.double(1), .double(1), .double(1)]), "intensity": .double(1), "range": .double(10),
                    "castShadows": .bool(true), "shadowBias": .double(0.002), "shadowSlopeBias": .double(0.004), "shadowPriority": .int(0),
                ]
                if isSpot { payload["innerConeAngle"] = .double(20); payload["outerConeAngle"] = .double(35) }
                return payload
            },
            decode: decode
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
