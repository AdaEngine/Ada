import AdaApp
import AdaAssets
import AdaCorePipelines
import AdaECS
import AdaRender
import AdaScene
import AdaTransform
import AdaUtils
import Foundation
import Math
import Testing

@Suite("Skybox IBL display settings")
struct SkyboxIBLDisplaySettingsTests {
    @Test func legacyDefaultsAndReflectedFalseRoundTrip() throws {
        let field = try #require(Environment3D.componentDescriptor.fields.first { $0.key == "skyboxUsesImageBasedLighting" })
        #expect(field.kind == .bool && field.isWritable)
        let legacy = try JSONDecoder().decode(Environment3D.self, from: Data("{}".utf8))
        #expect(field.read(legacy) == .bool(true))
        let changed = try #require(field.write(legacy, .bool(false)) as? Environment3D)
        let encoded = try JSONEncoder().encode(changed)
        let payload = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(payload["skyboxUsesImageBasedLighting"] as? Bool == false)
        let decoded = try JSONDecoder().decode(Environment3D.self, from: encoded)
        #expect(field.read(decoded) == .bool(false))
    }
}

#if os(macOS)
extension Render3DGPUTests {
    @Suite("Skybox display independent of IBL lighting")
    @MainActor
    struct SkyboxIBLDisplay {
        @Test(.enabled(if: GoldenFrame.activeBackend == .metal))
        func displayFlagChangesSkyAndPreservesPBRLighting() async throws {
            let scene = try await DebugViews.makeScene()
            for entity in scene.app.main.getEntities() where entity.id != scene.camera.id && entity.id != scene.sun.id {
                scene.app.main.removeEntity(entity)
            }
            try scene.setSunIntensity(0)
            let radiance = Texture2D(image: Image(width: 2, height: 1, color: Color(red: 0.8, green: 0, blue: 0)))
            let diffuse = Texture2D(image: Image(width: 2, height: 1, color: Color(red: 0.5, green: 0.5, blue: 0.5)))
            let specular = Texture2D(image: Image(width: 2, height: 2, color: Color(red: 0.25, green: 0.25, blue: 0.25)))
            let brdf = Texture2D(image: Image(width: 2, height: 2, color: .white))
            let ibl = AssetHandle(ImageBasedLighting3D(irradiance: diffuse, specular: specular, brdf: brdf, specularLevels: 2, radiance: radiance))
            try scene.configure {
                $0.imageBasedLighting = ImageBasedLightingSettings(asset: ibl, intensity: 1, rotation: 0.35)
                $0.skybox = Skybox3D(zenithColor: .green, horizonColor: .green, groundColor: .green)
                $0.screenSpaceReflection.isEnabled = false
                $0.ambientOcclusion.isEnabled = false
                $0.postProcess.bloom.isEnabled = false
                $0.fog.isEnabled = false
            }
            let material = PBRMaterial()
            material.baseColorFactor = [0.65, 0.65, 0.65, 1]
            material.metallicFactor = 0.3
            material.roughnessFactor = 0.6
            scene.app.main.spawn("IBL-lit sphere") {
                Mesh3DComponent(mesh: Mesh.generateSphere(radius: 0.5, renderDevice: scene.device), materials: [material])
                Transform(position: [0, 0.5, 0])
            }
            let flag = try #require(Environment3D.componentDescriptor.fields.first { $0.key == "skyboxUsesImageBasedLighting" })
            func setDisplay(_ enabled: Bool) throws {
                let current = try #require(scene.camera.components[Environment3D.self])
                scene.camera.components[Environment3D.self] = try #require(flag.write(current, .bool(enabled)) as? Environment3D)
            }
            let original = try await scene.render(.none)
            let redSky = original.getPixel(x: 20, y: 20)
            #expect(redSky.red > 0.7 && redSky.green < 0.05, "Default display must use red IBL radiance: \(redSky).")
            try setDisplay(true)
            let explicitDefault = try await scene.render(.none)
            #expect(GoldenFrame.compare(explicitDefault, original, tolerance: .metal).passes(.metal))
            try setDisplay(false)
            let procedural = try await scene.render(.none)
            let greenSky = procedural.getPixel(x: 20, y: 20)
            #expect(greenSky.green > 0.7 && greenSky.red < 0.05, "False must reveal green procedural sky: \(greenSky).")
            var largestObjectStep: Float = 0
            for y in 230...250 {
                for x in 310...330 {
                    let a = original.getPixel(x: x, y: y), b = procedural.getPixel(x: x, y: y)
                    largestObjectStep = max(largestObjectStep, abs(a.red - b.red), abs(a.green - b.green), abs(a.blue - b.blue))
                }
            }
            #expect(largestObjectStep * 255 <= 2, "Changing sky display must preserve opaque PBR pixels: \(largestObjectStep).")
            let settings = try #require(scene.camera.components[Environment3D.self]?.imageBasedLighting)
            #expect(settings.asset === ibl && settings.intensity == 1 && settings.rotation == 0.35)
            let maps = try #require(settings.asset.asset)
            #expect(maps.radiance === radiance && maps.irradiance === diffuse && maps.specular === specular && maps.brdf === brdf)

            try scene.configure { $0.imageBasedLighting = nil }
            let unlit = try await scene.render(.none)
            let litCenter = procedural.getPixel(x: 320, y: 240), unlitCenter = unlit.getPixel(x: 320, y: 240)
            #expect(abs(litCenter.red - unlitCenter.red) > 0.05, "The unchanged sphere must actually receive IBL lighting.")
            try FileManager.default.createDirectory(at: GoldenFrame.outputDirectory, withIntermediateDirectories: true)
            for (name, image) in [("ibl", original), ("procedural", procedural), ("no-ibl-lighting", unlit)] {
                try image.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("skybox-display-\(name).png"))
            }
        }
    }
}
#endif
