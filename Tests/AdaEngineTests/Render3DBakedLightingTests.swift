#if os(macOS) || os(Windows) || os(Linux)
import AdaAssets
@testable import AdaCorePipelines
import AdaECS
@_spi(Internal) import AdaRender
import AdaScene
import AdaTransform
import AdaUtils
import Foundation
import Math
import Testing

extension Render3DGPUTests {
    @MainActor
    @Suite("Baked diffuse lighting")
    struct BakedLighting {
        static func texture(width: Int, height: Int, value: (Int, Int) -> Vector4) -> Texture2D {
            // Encode binary16 explicitly so this fixture also compiles on Intel macOS.
            func half(_ f: Float) -> UInt16 {
                let b = f.bitPattern, sign = UInt16((b >> 16) & 0x8000)
                let exponent = Int((b >> 23) & 255) - 112
                if exponent <= 0 { return sign }
                let rounded = (b & 0x7FFFFF) + 0x1000
                return sign | UInt16(min(exponent, 30) << 10) &+ UInt16(rounded >> 13)
            }
            var pixels: [UInt16] = []
            for y in 0..<height { for x in 0..<width {
                let c = value(x,y); pixels.append(contentsOf: [half(c.x),half(c.y),half(c.z),half(c.w)])
            } }
            let map = Texture2D(descriptor: .init(width: width, height: height, pixelFormat: .rgba_16f,
                textureUsage: [.read], textureType: .texture2D, samplerDescription: .init(minFilter: .linear, magFilter: .linear,
                    mipFilter: .notMipmapped, addressModeU: .clampToEdge, addressModeV: .clampToEdge)))
            unsafe pixels.withUnsafeBytes { p in
                if let bytes = p.baseAddress { unsafe map.replaceRegion(.init(x:0,y:0,width:width,height:height),withBytes:bytes,bytesPerRow:width*8) }
            }
            return map
        }

        static func grid(blockLeft: Bool = false, blockAll: Bool = false) throws -> IrradianceProbeGrid3D {
            let sh = texture(width:18,height:4) { x,_ in
                guard x % 9 == 0 else { return [0,0,0,1] }
                return x < 9 ? [2.8359,0,0,1] : [0,0,2.8359,1] // 0.8 irradiance/pi
            }
            let depth = texture(width:32,height:64) { x,_ in
                blockAll || (blockLeft && x < 16) ? [0.25,0.0625,0.25,1] : [100,10000,100,1]
            }
            return try .init(origin:[-3,-2,-3],spacing:[6,4,6],counts:[2,2,2],visibilityResolution:16,coefficients:sh,visibility:depth)
        }

        static func quad(device: RenderDevice, uv1: Bool = true) -> Mesh {
            var d = MeshDescriptor(name:"Lightmap UV1 fixture")
            d[MeshDescriptor.positions] = MeshBuffer<Vector3>([[-2,-1,0],[2,-1,0],[-2,1,0],[2,1,0]])
            d[MeshDescriptor.normals] = MeshBuffer<Vector3>(Array(repeating:[0,0,-1],count:4))
            d[MeshDescriptor.textureCoordinates] = MeshBuffer<Vector2>(Array(repeating:[0.9,0.9],count:4))
            if uv1 { d[MeshDescriptor.textureCoordinates1] = MeshBuffer<Vector2>([[0,1],[1,1],[0,0],[1,0]]) }
            d.indicies = [0,2,1,2,3,1]
            return Mesh.generate(from:[d],renderDevice:device)
        }

        static func scene(pathTracingPresentation: Bool = false) async throws -> DebugViews.Scene {
            let s = try await DebugViews.makeScene(pathTracingPresentation:pathTracingPresentation)
            try s.setSunIntensity(0)
            for entity in s.app.main.getEntities() where entity.id != s.camera.id && entity.id != s.sun.id { s.app.main.removeEntity(entity) }
            s.camera.components[Transform.self] = Transform(position:[0,0,-3.4])
            let diffuse = texture(width:2,height:1) { _,_ in [0,1.25,0,1] }
            let black = texture(width:2,height:2) { _,_ in [0,0,0,1] }
            try s.configure {
                $0.skybox.isEnabled = false; $0.ambientOcclusion.isEnabled = false; $0.screenSpaceReflection.isEnabled = false
                $0.imageBasedLighting = .init(asset:AssetHandle(ImageBasedLighting3D(irradiance:diffuse,specular:black,brdf:black,specularLevels:2)))
            }
            return s
        }

        @Test(.enabled(if: GoldenFrame.activeBackend != nil))
        func lightmapUsesUV1ReplacesDiffuseIBLAndPreservesDirectAndSpecular() async throws {
            let s = try await Self.scene()
            let material = PBRMaterial()
            material.baseColorFactor = .one; material.metallicFactor = 0; material.roughnessFactor = 1
            s.app.main.spawn("Lightmapped receiver") { Mesh3DComponent(mesh:Self.quad(device:s.device),materials:[material]); Transform() }
            let baseline = try await s.render(.none)
            material.occlusionTexture = Texture2D(image:Image(width:1,height:1,color:.black))
            material.lightmapTexture = Self.texture(width:8,height:4) { x,_ in x < 4 ? [0.5,0,0,1] : [0,0,0.5,1] }
            let grid = try Self.grid()
            try s.configure { $0.irradianceProbes = .init(asset:AssetHandle(grid)) }
            let mapped = try await s.render(.none)
            let left = mapped.getPixel(x:220,y:240),right = mapped.getPixel(x:420,y:240)
            #expect(left.red > left.blue+0.15 && right.blue > right.red+0.15, "Lightmap must use UV1, independently of constant UV0.")
            #expect(left.green < 0.03 && right.green < 0.03, "Baked diffuse replaces green IBL; material AO cannot double-occlude baked geometry.")
            try s.setSunIntensity(3)
            material.occlusionTexture = nil
            let direct = try await s.render(.none)
            #expect(direct.getPixel(x:320,y:240).green > mapped.getPixel(x:320,y:240).green+0.02, "Runtime direct lighting survives.")
            try s.setSunIntensity(0)
            let originalIBL = try #require(s.camera.components[Environment3D.self]).imageBasedLighting
            let specular = Self.texture(width:2,height:2) { _,_ in [0.3,0.3,0.3,1] }
            let brdf = Self.texture(width:2,height:2) { _,_ in [1,0,0,1] }
            try s.configure { $0.imageBasedLighting = .init(asset:AssetHandle(ImageBasedLighting3D(irradiance:specular,specular:specular,brdf:brdf,specularLevels:2))) }
            material.metallicFactor = 1
            let metalMapped = try await s.render(.none)
            #expect(metalMapped.getPixel(x:320,y:240).red > 0.1, "Existing specular IBL must remain visible.")
            material.lightmapTexture = nil
            let metalUnmapped = try await s.render(.none)
            #expect(GoldenFrame.compare(metalMapped,metalUnmapped,tolerance:GoldenFrame.activeTolerance).passes(GoldenFrame.activeTolerance), "Metals do not acquire diffuse baked light.")
            material.metallicFactor = 0
            try s.configure { $0.irradianceProbes = nil; $0.imageBasedLighting = originalIBL }
            let disabled = try await s.render(.none)
            #expect(GoldenFrame.compare(disabled,baseline,tolerance:GoldenFrame.activeTolerance).passes(GoldenFrame.activeTolerance))
            try FileManager.default.createDirectory(at:GoldenFrame.outputDirectory,withIntermediateDirectories:true)
            try mapped.writePNG(to:GoldenFrame.outputDirectory.appendingPathComponent("lightmap-uv1.png"))
        }

        @Test(.enabled(if: GoldenFrame.activeBackend != nil))
        func movingReceiverInterpolatesAndOccludedProbesCannotLeakGlobalAmbient() async throws {
            let s = try await Self.scene()
            let material = PBRMaterial(); material.baseColorFactor = .one; material.metallicFactor = 0; material.roughnessFactor = 1
            let receiver = s.app.main.spawn("Moving probe receiver") {
                Mesh3DComponent(mesh:Self.quad(device:s.device),materials:[material]); Transform()
            }
            let grid = try Self.grid()
            try s.configure { $0.irradianceProbes = .init(asset:AssetHandle(grid)) }
            var samples: [Color] = []
            for x: Float in [-1.5,0,1.5] {
                receiver.components[Transform.self] = Transform(position:[x,0,0])
                s.camera.components[Transform.self] = Transform(position:[x,0,-3.4])
                samples.append(try await s.render(.none).getPixel(x:320,y:240))
            }
            #expect(samples[0].red > samples[0].blue+0.1 && samples[2].blue > samples[2].red+0.1)
            #expect(abs(samples[1].red-samples[1].blue) < 0.03, "The midpoint blends neighboring SH probes.")
            receiver.components[Transform.self] = Transform(); s.camera.components[Transform.self] = Transform(position:[0,0,-3.4])
            let blockedGrid = try Self.grid(blockLeft:true)
            try s.configure { $0.irradianceProbes = .init(asset:AssetHandle(blockedGrid)) }
            let blocked = try await s.render(.none)
            let pixel = blocked.getPixel(x:320,y:240)
            #expect(pixel.blue > pixel.red+0.2 && pixel.green < 0.03, "Visibility must reject the red probes behind an occluder.")
            let occludedGrid = try Self.grid(blockAll:true)
            try s.configure { $0.irradianceProbes = .init(asset:AssetHandle(occludedGrid)) }
            let dark = try await s.render(.none).getPixel(x:320,y:240)
            #expect(max(dark.red,max(dark.green,dark.blue)) < 0.03, "No visible probe must stay dark instead of falling back to global IBL.")
            try s.configure { $0.imageBasedLighting = nil }
            let noIBL = try await s.render(.none).getPixel(x:320,y:240)
            #expect(max(noIBL.red,max(noIBL.green,noIBL.blue)) < 0.03, "The legacy procedural fill must not reintroduce ambient through walls.")
            try blocked.writePNG(to:GoldenFrame.outputDirectory.appendingPathComponent("probe-visibility.png"))
        }

        @Test(.enabled(if: GoldenFrame.activeBackend != nil))
        func missingUV1DoesNotSampleAnArbitraryLightmapCorner() async throws {
            let s = try await Self.scene()
            let material = PBRMaterial(); material.baseColorFactor = .one; material.metallicFactor = 0; material.roughnessFactor = 1
            s.app.main.spawn("Uncharted receiver") { Mesh3DComponent(mesh:Self.quad(device:s.device,uv1:false),materials:[material]); Transform() }
            let baseline = try await s.render(.none)
            material.lightmapTexture = Self.texture(width:2,height:2) { _,_ in [1,0,0,1] }
            let missing = try await s.render(.none)
            #expect(GoldenFrame.compare(missing,baseline,tolerance:GoldenFrame.activeTolerance).passes(GoldenFrame.activeTolerance))
            let copy = material.makeInstance()
            #expect(copy.lightmapTexture === material.lightmapTexture)
            copy.lightmapIntensity = 0.2
            #expect(material.lightmapIntensity == 1, "Model instances must not mutate their shared imported material.")
        }

        @Test(.enabled(if: GoldenFrame.activeBackend != nil && ProcessInfo.processInfo.environment["ADAENGINE_BAKED_GI_ASSETS"] != nil))
        func importsTheRealBakedModelAndKeepsSharedMaterialsUntouched() async throws {
            let s = try await Self.scene()
            let directory = URL(fileURLWithPath:try #require(ProcessInfo.processInfo.environment["ADAENGINE_BAKED_GI_ASSETS"]))
            let path = directory.appendingPathComponent("Corridor-Lightmapped.glb").path
            let maps = try #require(try AssetsManager.loadSync(LightmapSet3D.self,at:directory.appendingPathComponent("Corridor.lightmaps").path).asset)
            let grid = try #require(try AssetsManager.loadSync(IrradianceProbeGrid3D.self,at:directory.appendingPathComponent("Grid.probegrid").path).asset)
            let model = try #require(try AssetsManager.loadSync(ModelAsset3D.self,at:path).asset)
            #expect(maps.materials.count == 39 && grid.counts.reduce(1,*) == 1485)
            let owner = s.app.main.spawn("Actual derived lightmap model")
            var reference = Model3DSource(source:path)
            reference.lightmapSource = directory.appendingPathComponent("Corridor.lightmaps").path
            _ = try reference.instantiate(model,in:s.app.main,under:owner)
            var materials: Set<ObjectIdentifier> = []
            for entity in s.app.main.getEntities() {
                if let mesh = entity.components[Mesh3DComponent.self] {
                    for m in mesh.materials where (m as? PBRMaterial)?.lightmapTexture != nil { materials.insert(ObjectIdentifier(m)) }
                }
            }
            #expect(materials.count == maps.materials.count)
            #expect(model.materials.allSatisfy { ($0 as? PBRMaterial)?.lightmapTexture == nil })
            try s.configure { $0.irradianceProbes = .init(asset:AssetHandle(grid)) }
            _ = try await s.render(.none)
        }

        @Test(.enabled(if: GoldenFrame.activeBackend != nil))
        func malformedBakedAssetsFailBeforeUploadingTextures() async throws {
            _ = try await Self.scene()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AdaBakedGI-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            func write(_ name: String, _ value: [String:Any]) throws -> String {
                let path = directory.appendingPathComponent(name)
                try JSONSerialization.data(withJSONObject:value).write(to:path)
                return path.path
            }
            let traversal = try write("Traversal.lightmaps",["version":1,"encoding":"diffuse-irradiance-over-pi","modelFile":"x.glb",
                "materials":["0":["file":"../elsewhere.rgba16f","width":1,"height":1]]])
            #expect(throws:(any Error).self) { _ = try AssetsManager.loadSync(LightmapSet3D.self,at:traversal) }
            let wrongConvention = try write("Direct.lightmaps",["version":1,"encoding":"combined-direct-and-indirect","modelFile":"x.glb","materials":[:]])
            #expect(throws:(any Error).self) { _ = try AssetsManager.loadSync(LightmapSet3D.self,at:wrongConvention) }
            let layout = try write("Layout.probegrid",["version":1,"encoding":"sh9-diffuse-irradiance-over-pi",
                "origin":["x":0,"y":0,"z":0],"spacing":["x":1,"y":1,"z":1],"counts":[2,0,2],"visibilityResolution":16,
                "coefficients":["file":"x.rgba16f","width":18,"height":4],"visibility":["file":"y.rgba16f","width":32,"height":64]])
            #expect(throws:(any Error).self) { _ = try AssetsManager.loadSync(IrradianceProbeGrid3D.self,at:layout) }
        }
    }
}
#endif
