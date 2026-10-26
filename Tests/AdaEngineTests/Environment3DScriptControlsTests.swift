import AdaAssets
import AdaCorePipelines
import AdaECS
@_spi(Internal) @testable import AdaRender
import AdaScripting
import AdaUtils
import Testing

@_spi(Internal) @testable import AdaApp

@MainActor
@Suite("Environment3D script controls", .serialized)
struct Environment3DScriptControlsTests {
    @Test(arguments: [false, true])
    func scriptWritesReachNativeFieldsAndExtraction(hasIBL: Bool) async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        Environment3D.registerComponent()
        let texture = Texture2D(image: Image(width: 1, height: 1, color: .white))
        let skyTexture = AssetHandle(texture)
        let ibl = AssetHandle(ImageBasedLighting3D(irradiance: texture, specular: texture, brdf: texture, specularLevels: 2, radiance: texture))
        var initial = Environment3D()
        initial.skybox.texture = skyTexture
        initial.skybox.isEnabled = false
        initial.skybox.starfield = Starfield3D(isEnabled: false, density: 0.3, intensity: 0.6, size: 2, seed: 17)
        if hasIBL { initial.imageBasedLighting = ImageBasedLightingSettings(asset: ibl, intensity: 2, rotation: 0.7) }
        initial.fog = Fog3D(isEnabled: true, color: .red, density: 0.08, heightFalloff: 0.2, baseHeight: 3,
                            startDistance: 2, maximumOpacity: 0.8, skyInfluence: 0.4, sunInscattering: 0.5)
        initial.shadows.cascadeCount = 3
        initial.postProcess.bloom.intensity = 0.65

        let plugin = try AdaScriptPlugin(source: """
        @access(write: [Environment3D])
        @system(id: "test.environment-controls", scheduler: "update")
        class EnvironmentControls {
            @query(Environment3D) var cameras;
            func update(context) {
                for (var row in cameras) {
                    row.environment3D.skyZenithColor = Color(0.125,0.25,0.5,1.0);
                    row.environment3D.skyHorizonColor = [0.5,0.25,0.125,1.0];
                    row.environment3D.skyGroundColor = Color(0.0625,0.125,0.25,1.0);
                    row.environment3D.skyIntensity = 0.5;
                    row.environment3D.skyIntensity += 0.25;
                    row.environment3D.starfieldEnabled = true;
                    row.environment3D.starfieldIntensity = 0.125;
                    row.environment3D.imageBasedLightingIntensity = 0.375;
                    row.environment3D.fogColor = Color(0.25,0.375,0.5,0.75);
                    row.environment3D.exposureEV = row.environment3D.imageBasedLightingIntensity;
                }
            }
        }
        """, name: "Environment controls")
        let world = World(name: "Environment controls")
        let camera = world.spawn { Camera(); initial }
        let app = AppWorlds(main: world)
        plugin.setup(in: app)
        defer { plugin.destroy(for: app) }
        await world.runScheduler(.update)
        try #require(plugin.diagnostics.isEmpty, "\(plugin.diagnostics)")

        let native = try #require(camera.components[Environment3D.self])
        let render = World(name: "Extracted environment controls")
        render.insertResource(MainWorld(world: world))
        render.insertResource(ExtractedEnvironment3D())
        render.addSystem(ExtractEnvironment3DSystem.self, on: .extract)
        await render.runScheduler(.extract)
        let extracted = try #require(render.getResource(ExtractedEnvironment3D.self)?.environments[camera.id])

        var expectedFog = initial.fog
        expectedFog.color = Color(red: 0.25, green: 0.375, blue: 0.5, alpha: 0.75)
        for value in [native, extracted] {
            #expect(value.skybox.zenithColor == Color(red: 0.125, green: 0.25, blue: 0.5))
            #expect(value.skybox.horizonColor == Color(red: 0.5, green: 0.25, blue: 0.125))
            #expect(value.skybox.groundColor == Color(red: 0.0625, green: 0.125, blue: 0.25))
            #expect(value.skybox.intensity == 0.75)
            #expect(value.skybox.starfield.isEnabled && value.skybox.starfield.intensity == 0.125)
            #expect(value.skybox.starfield.density == initial.skybox.starfield.density)
            #expect(value.skybox.starfield.size == initial.skybox.starfield.size && value.skybox.starfield.seed == initial.skybox.starfield.seed)
            #expect(value.skybox.texture === skyTexture && !value.skybox.isEnabled)
            #expect(value.fog == expectedFog)
            #expect(value.shadows.cascadeCount == 3 && value.postProcess.bloom.intensity == 0.65)
            if hasIBL {
                let settings = try #require(value.imageBasedLighting)
                #expect(settings.intensity == 0.375 && value.postProcess.exposureEV == 0.375)
                #expect(settings.rotation == 0.7 && settings.asset === ibl)
                let asset = try #require(settings.asset.asset)
                #expect(asset.irradiance === texture && asset.specular === texture && asset.brdf === texture && asset.radiance === texture)
                #expect(asset.specularLevels == 2)
            } else {
                #expect(value.imageBasedLighting == nil && value.postProcess.exposureEV == 0)
            }
        }
        let fields = Environment3D.componentDescriptor.fields
        for name in ["skyZenithColor", "skyHorizonColor", "skyGroundColor", "fogColor"] {
            let field = try #require(fields.first { $0.key == name })
            #expect(field.kind == .color && field.isWritable)
        }
        for name in ["skyIntensity", "starfieldIntensity", "imageBasedLightingIntensity"] {
            let field = try #require(fields.first { $0.key == name })
            #expect(field.kind == .float && field.isWritable)
        }
        let stars = try #require(fields.first { $0.key == "starfieldEnabled" })
        #expect(stars.kind == .bool && stars.isWritable)
    }
}
