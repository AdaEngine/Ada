@_spi(AdaEngine) import AdaEngine

extension EditorComponentRegistry {
    static let environment3DDescriptor = EditorComponentDescriptor(
        typeName: EditorBuiltInComponentType.environment3D,
        displayName: "Environment 3D",
        category: "3D",
        description: "Configures the sky, star field, and screen-space reflections for a 3D camera.",
        requiredComponentTypeNames: [EditorBuiltInComponentType.camera],
        fields: [
            environmentField("skybox.texture", "Skybox Texture", .assetReference),
            environmentField("skybox.isEnabled", "Skybox Enabled", .bool),
            environmentField("skybox.intensity", "Skybox Intensity", .float, minimumValue: 0),
            environmentField("skybox.zenithColor", "Zenith Color", .color),
            environmentField("skybox.horizonColor", "Horizon Color", .color),
            environmentField("skybox.groundColor", "Ground Color", .color),
            environmentField("skybox.starfield.isEnabled", "Starfield Enabled", .bool),
            environmentField("skybox.starfield.density", "Star Density", .float, minimumValue: 0),
            environmentField("skybox.starfield.intensity", "Star Intensity", .float, minimumValue: 0),
            environmentField("skybox.starfield.size", "Star Size", .float, minimumValue: 0),
            environmentField("skybox.starfield.seed", "Star Seed", .float),
            environmentField("screenSpaceReflection.isEnabled", "Reflections Enabled", .bool),
            environmentField("screenSpaceReflection.maxDistance", "Reflection Distance", .float, minimumValue: 0),
            environmentField("screenSpaceReflection.stride", "Reflection Stride", .float, minimumValue: 0),
            environmentField("screenSpaceReflection.thickness", "Reflection Thickness", .float, minimumValue: 0),
            environmentField("screenSpaceReflection.maxSteps", "Reflection Steps", .int, minimumValue: 1),
            environmentField("screenSpaceReflection.intensity", "Reflection Intensity", .float, minimumValue: 0),
            environmentField("screenSpaceReflection.edgeFade", "Reflection Edge Fade", .float, minimumValue: 0),
        ],
        makeDefaultPayload: makeDefaultEnvironment3DPayload,
        decode: decodeEnvironment3D
    )

    private static func environmentField(
        _ key: String,
        _ label: String,
        _ kind: EditorComponentFieldKind,
        minimumValue: Double? = nil
    ) -> EditorComponentField {
        var field = EditorComponentField(key: key, label: label, kind: kind)
        field.valuePath = key.split(separator: ".").map(String.init)
        field.minimumValue = minimumValue
        return field
    }

    private static func makeDefaultEnvironment3DPayload() -> EditorComponentPayload {
        let environment = Environment3D()
        return [
            "skybox": .object([
                "texture": .null,
                "zenithColor": colorValue(environment.skybox.zenithColor),
                "horizonColor": colorValue(environment.skybox.horizonColor),
                "groundColor": colorValue(environment.skybox.groundColor),
                "intensity": .double(Double(environment.skybox.intensity)),
                "isEnabled": .bool(environment.skybox.isEnabled),
                "starfield": .object([
                    "isEnabled": .bool(environment.skybox.starfield.isEnabled),
                    "density": .double(Double(environment.skybox.starfield.density)),
                    "intensity": .double(Double(environment.skybox.starfield.intensity)),
                    "size": .double(Double(environment.skybox.starfield.size)),
                    "seed": .double(Double(environment.skybox.starfield.seed)),
                ]),
            ]),
            "screenSpaceReflection": .object([
                "isEnabled": .bool(environment.screenSpaceReflection.isEnabled),
                "maxDistance": .double(Double(environment.screenSpaceReflection.maxDistance)),
                "stride": .double(Double(environment.screenSpaceReflection.stride)),
                "thickness": .double(Double(environment.screenSpaceReflection.thickness)),
                "maxSteps": .int(environment.screenSpaceReflection.maxSteps),
                "intensity": .double(Double(environment.screenSpaceReflection.intensity)),
                "edgeFade": .double(Double(environment.screenSpaceReflection.edgeFade)),
            ]),
        ]
    }

    private static func decodeEnvironment3D(_ payload: EditorComponentPayload) throws -> any Component {
        let defaults = Environment3D()
        let root = EditorSceneValue.object(payload)
        let textureReference = root.value(at: ["skybox", "texture"][...])?.stringValue
        let texture: AssetHandle<Texture2D>? =
            if let textureReference, !textureReference.isEmpty {
                try? AssetsManager.loadSync(Texture2D.self, at: textureReference)
            } else {
                nil
            }
        let skybox = Skybox3D(
            texture: texture,
            zenithColor: root.value(at: ["skybox", "zenithColor"][...])?.colorValue ?? defaults.skybox.zenithColor,
            horizonColor: root.value(at: ["skybox", "horizonColor"][...])?.colorValue ?? defaults.skybox.horizonColor,
            groundColor: root.value(at: ["skybox", "groundColor"][...])?.colorValue ?? defaults.skybox.groundColor,
            intensity: Float(root.value(at: ["skybox", "intensity"][...])?.doubleValue ?? Double(defaults.skybox.intensity)),
            isEnabled: root.value(at: ["skybox", "isEnabled"][...])?.boolValue ?? defaults.skybox.isEnabled,
            starfield: Starfield3D(
                isEnabled: root.value(at: ["skybox", "starfield", "isEnabled"][...])?.boolValue ?? defaults.skybox.starfield.isEnabled,
                density: Float(root.value(at: ["skybox", "starfield", "density"][...])?.doubleValue ?? Double(defaults.skybox.starfield.density)),
                intensity: Float(root.value(at: ["skybox", "starfield", "intensity"][...])?.doubleValue ?? Double(defaults.skybox.starfield.intensity)),
                size: Float(root.value(at: ["skybox", "starfield", "size"][...])?.doubleValue ?? Double(defaults.skybox.starfield.size)),
                seed: Float(root.value(at: ["skybox", "starfield", "seed"][...])?.doubleValue ?? Double(defaults.skybox.starfield.seed))
            )
        )
        let reflection = ScreenSpaceReflection(
            isEnabled: root.value(at: ["screenSpaceReflection", "isEnabled"][...])?.boolValue ?? defaults.screenSpaceReflection.isEnabled,
            maxDistance: Float(root.value(at: ["screenSpaceReflection", "maxDistance"][...])?.doubleValue ?? Double(defaults.screenSpaceReflection.maxDistance)),
            stride: Float(root.value(at: ["screenSpaceReflection", "stride"][...])?.doubleValue ?? Double(defaults.screenSpaceReflection.stride)),
            thickness: Float(root.value(at: ["screenSpaceReflection", "thickness"][...])?.doubleValue ?? Double(defaults.screenSpaceReflection.thickness)),
            maxSteps: Int(root.value(at: ["screenSpaceReflection", "maxSteps"][...])?.doubleValue ?? Double(defaults.screenSpaceReflection.maxSteps)),
            intensity: Float(root.value(at: ["screenSpaceReflection", "intensity"][...])?.doubleValue ?? Double(defaults.screenSpaceReflection.intensity)),
            edgeFade: Float(root.value(at: ["screenSpaceReflection", "edgeFade"][...])?.doubleValue ?? Double(defaults.screenSpaceReflection.edgeFade))
        )
        return Environment3D(skybox: skybox, screenSpaceReflection: reflection)
    }

    private static func colorValue(_ color: Color) -> EditorSceneValue {
        .object([
            "red": .double(Double(color.red)),
            "green": .double(Double(color.green)),
            "blue": .double(Double(color.blue)),
            "alpha": .double(Double(color.alpha)),
        ])
    }
}
