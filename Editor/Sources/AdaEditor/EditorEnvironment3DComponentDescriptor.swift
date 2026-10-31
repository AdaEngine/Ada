@_spi(AdaEngine) import AdaEngine
import Foundation

extension EditorComponentRegistry {
    static let environment3DDescriptor = EditorComponentDescriptor(
        typeName: EditorBuiltInComponentType.environment3D,
        displayName: "Environment 3D",
        category: "3D",
        description: "Configures the sky, star field, and screen-space reflections for a 3D camera.",
        requiredComponentTypeNames: [EditorBuiltInComponentType.camera],
        fields: [
            environmentField("localShadows.isEnabled", "Local Shadows Enabled", .bool, group: "Local Shadows"),
            environmentField("localShadows.maximumLights", "Local Shadow Light Budget (0–4)", .int, minimumValue: 0, group: "Local Shadows"),
            environmentField("skybox.texture", "Skybox Texture", .assetReference, group: "Skybox"),
            environmentField("skybox.isEnabled", "Skybox Enabled", .bool, group: "Skybox"),
            environmentField("skybox.intensity", "Skybox Intensity", .float, minimumValue: 0, group: "Skybox"),
            environmentField("skybox.zenithColor", "Zenith Color", .color, group: "Skybox"),
            environmentField("skybox.horizonColor", "Horizon Color", .color, group: "Skybox"),
            environmentField("skybox.groundColor", "Ground Color", .color, group: "Skybox"),
            environmentField("skybox.starfield.isEnabled", "Starfield Enabled", .bool, group: "Skybox/Starfield"),
            environmentField("skybox.starfield.density", "Star Density", .float, minimumValue: 0, group: "Skybox/Starfield"),
            environmentField("skybox.starfield.intensity", "Star Intensity", .float, minimumValue: 0, group: "Skybox/Starfield"),
            environmentField("skybox.starfield.size", "Star Size", .float, minimumValue: 0, group: "Skybox/Starfield"),
            environmentField("skybox.starfield.seed", "Star Seed", .float, group: "Skybox/Starfield"),
            environmentField("screenSpaceReflection.isEnabled", "Reflections Enabled", .bool, group: "Reflections"),
            environmentField("screenSpaceReflection.maxDistance", "Reflection Distance", .float, minimumValue: 0, group: "Reflections"),
            environmentField("screenSpaceReflection.stride", "Reflection Stride", .float, minimumValue: 0, group: "Reflections"),
            environmentField("screenSpaceReflection.thickness", "Reflection Thickness", .float, minimumValue: 0, group: "Reflections"),
            environmentField("screenSpaceReflection.maxSteps", "Reflection Steps", .int, minimumValue: 1, group: "Reflections"),
            environmentField("screenSpaceReflection.intensity", "Reflection Intensity", .float, minimumValue: 0, group: "Reflections"),
            environmentField("screenSpaceReflection.edgeFade", "Reflection Edge Fade", .float, minimumValue: 0, group: "Reflections"),
            environmentField("debugView", "Debug View", .enumeration(DebugView3D.allCases.map(\.rawValue))),
            environmentField("postProcess.exposureEV", "Exposure (EV)", .float),
            environmentField("postProcess.toneMapper", "Tone Mapper", .enumeration(ToneMapper3D.allCases.map(\.rawValue))),
            environmentField("postProcess.autoExposure.isEnabled", "Auto Exposure Enabled", .bool, group: "Auto Exposure"),
            environmentField("postProcess.autoExposure.minimumEV", "Auto Exposure Minimum (EV)", .float, group: "Auto Exposure"),
            environmentField("postProcess.autoExposure.maximumEV", "Auto Exposure Maximum (EV)", .float, group: "Auto Exposure"),
            environmentField("postProcess.autoExposure.speedUp", "Auto Exposure Speed Up", .float, minimumValue: 0, group: "Auto Exposure"),
            environmentField("postProcess.autoExposure.speedDown", "Auto Exposure Speed Down", .float, minimumValue: 0, group: "Auto Exposure"),
            environmentField("postProcess.bloom.isEnabled", "Bloom Enabled", .bool, group: "Bloom"),
            environmentField("postProcess.bloom.intensity", "Bloom Intensity", .float, minimumValue: 0, group: "Bloom"),
            environmentField("postProcess.bloom.threshold", "Bloom Threshold", .float, minimumValue: 0, group: "Bloom"),
            environmentField("postProcess.bloom.softKnee", "Bloom Soft Knee", .float, minimumValue: 0, group: "Bloom"),
            environmentField("postProcess.bloom.scatter", "Bloom Scatter", .float, minimumValue: 0, group: "Bloom"),
            environmentField("postProcess.depthOfField.isEnabled", "Depth of Field Enabled", .bool, group: "Depth of Field"),
            environmentField("postProcess.lens.rainAmount", "Rain on Lens", .float, minimumValue: 0, group: "Lens"),
            environmentField("postProcess.lens.rainTime", "Rain Animation Time", .float, minimumValue: 0, group: "Lens"),
            environmentField("postProcess.depthOfField.focusDistance", "Focus Distance", .float, minimumValue: 0, group: "Depth of Field"),
            environmentField("postProcess.depthOfField.aperture", "Aperture", .float, minimumValue: 0, group: "Depth of Field"),
            environmentField("postProcess.depthOfField.maximumBlurRadius", "Maximum Blur Radius (px)", .float, minimumValue: 0, group: "Depth of Field"),
            environmentField("postProcess.colorGrading.saturation", "Saturation", .float, minimumValue: 0, group: "Color Grading"),
            environmentField("postProcess.colorGrading.contrast", "Contrast", .float, minimumValue: 0, group: "Color Grading"),
            environmentField("postProcess.colorGrading.correctionMode", "Correction Mode", .enumeration(ColorCorrectionMode3D.allCases.map(\.rawValue)), group: "Color Correction"),
            environmentField("postProcess.colorGrading.lutIntensity", "Correction Strength (0–1)", .float, minimumValue: 0, group: "Color Correction"),
            environmentField("postProcess.colorGrading.curves", "Color Curves", .string, group: "Color Correction"),
            environmentField("postProcess.colorGrading.lut", "LUT Texture", .assetReference, group: "Color Correction"),
            environmentField("postProcess.vignette.intensity", "Vignette Intensity", .float, minimumValue: 0, group: "Vignette"),
            environmentField("postProcess.vignette.radius", "Vignette Radius", .float, minimumValue: 0, group: "Vignette"),
            environmentField("postProcess.vignette.smoothness", "Vignette Smoothness", .float, minimumValue: 0, group: "Vignette"),
        ],
        makeDefaultPayload: makeDefaultEnvironment3DPayload,
        decode: decodeEnvironment3D
    )

    private static func environmentField(
        _ key: String,
        _ label: String,
        _ kind: EditorComponentFieldKind,
        minimumValue: Double? = nil,
        group: String? = nil
    ) -> EditorComponentField {
        var field = EditorComponentField(key: key, label: label, kind: kind)
        field.valuePath = key.split(separator: ".").map(String.init)
        field.minimumValue = minimumValue
        field.groupPath = group?.split(separator: "/").map(String.init) ?? []
        if key == "postProcess.colorGrading.curves" { field.coding = .json }
        field.defaultValue = EditorSceneValue.object(makeDefaultEnvironment3DPayload()).value(at: field.valuePath[...])
        return field
    }

    private static func makeDefaultEnvironment3DPayload() -> EditorComponentPayload {
        let environment = Environment3D()
        return [
            "localShadows": .object(["isEnabled": .bool(environment.localShadows.isEnabled), "maximumLights": .int(environment.localShadows.maximumLights)]),
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
            "debugView": .string(environment.debugView.rawValue),
            "postProcess": defaultPostProcessPayload(environment.postProcess),
        ]
    }

    private static func defaultPostProcessPayload(_ settings: PostProcess3D) -> EditorSceneValue {
        func number(_ value: Float) -> EditorSceneValue { .double(Double(value)) }
        return .object([
            "exposureEV": number(settings.exposureEV),
            "toneMapper": .string(settings.toneMapper.rawValue),
            "autoExposure": .object([
                "isEnabled": .bool(settings.autoExposure.isEnabled),
                "minimumEV": number(settings.autoExposure.minimumEV),
                "maximumEV": number(settings.autoExposure.maximumEV),
                "speedUp": number(settings.autoExposure.speedUp),
                "speedDown": number(settings.autoExposure.speedDown),
            ]),
            "bloom": .object([
                "isEnabled": .bool(settings.bloom.isEnabled),
                "intensity": number(settings.bloom.intensity),
                "threshold": number(settings.bloom.threshold),
                "softKnee": number(settings.bloom.softKnee),
                "scatter": number(settings.bloom.scatter),
            ]),
            "depthOfField": .object([
                "isEnabled": .bool(settings.depthOfField.isEnabled),
                "focusDistance": number(settings.depthOfField.focusDistance),
                "aperture": number(settings.depthOfField.aperture),
                "maximumBlurRadius": number(settings.depthOfField.maximumBlurRadius),
            ]),
            "colorGrading": .object([
                "saturation": number(settings.colorGrading.saturation),
                "contrast": number(settings.colorGrading.contrast),
                "lutIntensity": number(settings.colorGrading.lutIntensity),
                "correctionMode": .string(settings.colorGrading.correctionMode.rawValue),
                "lut": .null,
                "curves": (try? JSONDecoder().decode(EditorSceneValue.self, from: JSONEncoder().encode(settings.colorGrading.curves))) ?? .object([:]),
            ]),
            "vignette": .object([
                "intensity": number(settings.vignette.intensity),
                "radius": number(settings.vignette.radius),
                "smoothness": number(settings.vignette.smoothness),
            ]),
        ])
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
        var serialized = payload
        serialized.removeValue(forKey: "skybox")
        serialized.removeValue(forKey: "screenSpaceReflection")
        // Inspector references are portable paths; AssetHandle's Codable payload is a different format.
        let lutPath = ["postProcess", "colorGrading", "lut"]
        let lutReference: String? = if case let .string(reference)? = root.value(at: lutPath[...]) { reference } else { nil }
        if lutReference != nil {
            var portable = EditorSceneValue.object(serialized)
            portable.setValue(.null, at: lutPath[...])
            if case let .object(updated) = portable { serialized = updated }
        }
        // Decode the remaining portable quality and IBL settings rather than silently dropping them.
        var result = try EditorComponentPayloadDecoder.decode(Environment3D.self, payload: serialized) as! Environment3D
        result.skybox = skybox
        result.screenSpaceReflection = reflection
        if let lutReference, !lutReference.isEmpty {
            result.postProcess.colorGrading.lut = try? AssetsManager.loadSync(Texture2D.self, at: lutReference)
        }
        if let reference = payload["imageBasedLightingSource"]?.stringValue, !reference.isEmpty {
            let asset = try AssetsManager.loadSync(ImageBasedLighting3D.self, at: reference)
            result.imageBasedLighting = ImageBasedLightingSettings(asset: asset, intensity: Float(payload["imageBasedLightingIntensity"]?.doubleValue ?? 1))
        }
        result.localShadows = LocalShadowSettings3D(
            isEnabled: root.value(at: ["localShadows", "isEnabled"][...])?.boolValue ?? defaults.localShadows.isEnabled,
            maximumLights: Int(root.value(at: ["localShadows", "maximumLights"][...])?.doubleValue ?? Double(defaults.localShadows.maximumLights))
        )
        return result
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
