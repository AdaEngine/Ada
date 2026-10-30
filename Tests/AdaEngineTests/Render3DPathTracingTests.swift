#if os(macOS) || os(Windows) || os(Linux)
import AdaAssets
@testable import AdaCorePipelines
import AdaECS
@_spi(Internal) @testable import AdaRender
import AdaScene
import AdaTransform
import AdaUtils
import Foundation
import Math
import Testing

@Suite("Path tracing settings and BVH")
struct Render3DPathTracingSettingsTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["ADAENGINE_VALIDATE_TINT"] == "1"))
    func pathShadersCompileFreshWithoutAGPU() async throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["path_tracing_3d.glsl","path_tracing_composite_3d.glsl"] {
            let compiler = try ShaderCompiler(from:root.appendingPathComponent("Sources/AdaCorePipelines/Assets/Shaders/\(name)"))
            for stage in [ShaderStage.vertex,.fragment] {
                let binary = try compiler.compileSpirvBin(for:stage,ignoreCache:true)
                let result = try await WGSLShaderCompiler().compile(spirvData:binary.data,entryPoint:"path_validation",stage:stage,defines:[])
                #expect(result.source.contains("fn path_validation("))
            }
        }
    }
    @Test func oldScenesStayOptedOutAndSettingsRoundTrip() throws {
        #expect(try JSONDecoder().decode(Environment3D.self,from:Data("{}".utf8)).pathTracing.isEnabled == false)
        var environment = Environment3D()
        environment.pathTracing = .init(isEnabled:true,samplesPerPixel:4,maximumBounces:6,resolutionScale:0.75,historyLimit:64)
        #expect(try JSONDecoder().decode(Environment3D.self,from:JSONEncoder().encode(environment)).pathTracing == environment.pathTracing)
        #expect(try JSONDecoder().decode(PathTracing3D.self,from:Data("{\"isEnabled\":true}".utf8)).maximumBounces == 3)
        var invalid = PathTracing3D(isEnabled:true,samplesPerPixel:0,maximumBounces:100,resolutionScale:.nan,historyLimit:-1)
        invalid.rayBias = .infinity; invalid.maximumDistance = -.infinity
        #expect(invalid.sanitized.samplesPerPixel == 1 && invalid.sanitized.maximumBounces == 8)
        #expect(invalid.sanitized.resolutionScale == 0.5 && invalid.sanitized.historyLimit == 1)
        #expect(invalid.sanitized.rayBias.isFinite && invalid.sanitized.maximumDistance.isFinite)
    }

    @Test func stacklessBVHCoversEveryTriangleAndHasValidEscapes() {
        let input: [PathTracing3DBVH.Triangle] = (0..<39).map { index in
            let x = Float(index%7)-4, z = Float(index/7)-3
            return .init(vertices:[Vector4(x,0,z,Float(index)),Vector4(x+0.3,0,z,0),Vector4(x,0.3,z,0)]+Array(repeating:.zero,count:9))
        }
        let bvh = PathTracing3DBVH(input)
        #expect(bvh.nodes.first?.escape == bvh.nodes.count)
        #expect(bvh.triangles.count == input.count)
        #expect(Set(bvh.triangles.map { $0.vertices[0].w }) == Set((0..<39).map(Float.init)))
        #expect(bvh.nodes.filter { $0.count > 0 }.reduce(0) { $0+$1.count } == input.count)
        for (index,node) in bvh.nodes.enumerated() {
            #expect(node.escape > index && node.escape <= bvh.nodes.count)
            #expect(node.count <= 4)
            for triangle in bvh.triangles.dropFirst(node.first).prefix(node.count) {
                #expect(triangle.minimum.x >= node.minimum.x && triangle.maximum.x <= node.maximum.x)
                #expect(triangle.minimum.z >= node.minimum.z && triangle.maximum.z <= node.maximum.z)
            }
        }
        #expect(PathTracing3DBVH([]).nodes.isEmpty)
        var refitted = bvh
        var moved = input.reversed().map { $0 }
        for t in moved.indices { for v in 0..<3 { moved[t].vertices[v] += Vector4(20,3,-10,0) } }
        refitted.refit(moved)
        #expect(refitted.nodes[0].minimum == bvh.nodes[0].minimum+Vector3(20,3,-10))
        #expect(refitted.nodes[0].maximum == bvh.nodes[0].maximum+Vector3(20,3,-10))
        #expect(Set(refitted.triangles.map { $0.vertices[0].w }) == Set(bvh.triangles.map { $0.vertices[0].w }))
        refitted.refit(Array(moved.prefix(5)))
        #expect(refitted.triangles.count == 5)
    }
}

extension Render3DGPUTests {
    @MainActor @Suite("World path tracing")
    struct PathTracing {
        static func scene(bounces: Int = 1) async throws -> DebugViews.Scene {
            let s = try await BakedLighting.scene(pathTracingPresentation:true)
            try s.configure {
                $0.imageBasedLighting = nil; $0.skybox.isEnabled = false
                $0.fog.isEnabled = false; $0.localShadows.isEnabled = false; $0.shadows.isEnabled = false
                $0.pathTracing = .init(isEnabled:true,samplesPerPixel:4,maximumBounces:bounces,resolutionScale:0.5,historyLimit:16)
            }
            return s
        }
        static func receiver(_ s: DebugViews.Scene, metal: Float = 0) -> PBRMaterial {
            let pbr = PBRMaterial(); pbr.baseColorFactor = .one; pbr.metallicFactor = metal; pbr.roughnessFactor = metal > 0 ? 0.04 : 1
            s.app.main.spawn("Receiver") { Mesh3DComponent(mesh:BakedLighting.quad(device:s.device),materials:[pbr]); Transform() }
            return pbr
        }
        static func stats(_ s: DebugViews.Scene) throws -> Render3DPathTracingStatistics {
            try #require(s.app.getSubworldBuilder(by:.renderWorld)?.getResource(Render3DPathTracingStatistics.self))
        }
        static func red(_ image: Image) -> Float {
            var sum: Float = 0
            for y in 225..<255 { for x in 305..<335 { sum += image.getPixel(x:x,y:y).red } }
            return sum/900
        }

        @Test(.enabled(if:GoldenFrame.activeBackend != nil))
        func realOffscreenBlockerShadowsWithoutAnyShadowMapsAndLightOffClearsHistory() async throws {
            let s = try await Self.scene(); _ = Self.receiver(s)
            let lamp = s.app.main.spawn("Offscreen point") { PointLightComponent(intensity:400,range:20); Transform(position:[-6,0,-6]) }
            let lit = try await s.render(.none,frames:3)
            let blocker = s.app.main.spawn("Blocker behind camera") {
                Mesh3DComponent(mesh:Mesh.generateCube(size:[1,4,1],renderDevice:s.device),materials:[PBRMaterial()])
                Transform(position:[-4,0,-4])
            }
            let blocked = try await s.render(.none,frames:2)
            #expect(Self.red(lit) > Self.red(blocked)+0.1,"Actual offscreen triangles must block a light without a shadow atlas")
            var mesh = try #require(blocker.components[Mesh3DComponent.self]); mesh.castShadows = false; blocker.components[Mesh3DComponent.self] = mesh
            let restored = try await s.render(.none,frames:2)
            #expect(Self.red(restored) > Self.red(blocked)+0.1)
            let stats = try Self.stats(s)
            #expect(stats.snapshots.values.allSatisfy { $0.failure == nil && $0.encodedFrames >= 7 && $0.historyResets >= 3 && $0.triangles >= 14 })
            lamp.components[PointLightComponent.self] = PointLightComponent(intensity:0,range:20)
            let off = try await s.render(.none,frames:1)
            #expect(Self.red(off)<0.01,"Turning the lamp off must discard the previous lit history immediately")
            try s.configure { $0.pathTracing.isEnabled = false }
            _ = try await s.render(.none,frames:1)
            #expect(stats.snapshots.isEmpty)
            try FileManager.default.createDirectory(at:GoldenFrame.outputDirectory,withIntermediateDirectories:true)
            try lit.writePNG(to:GoldenFrame.outputDirectory.appendingPathComponent("path-point.png"))
            try blocked.writePNG(to:GoldenFrame.outputDirectory.appendingPathComponent("path-offscreen-blocker.png"))
        }

        @Test(.enabled(if:GoldenFrame.activeBackend != nil))
        func hiddenWallBouncesLightAndMetalReflectsGeometryBehindCamera() async throws {
            let s = try await Self.scene(bounces:3); let receiver = Self.receiver(s)
            let red = PBRMaterial(); red.baseColorFactor = [0.9,0.01,0.005,1]; red.metallicFactor = 0; red.roughnessFactor = 1
            s.app.main.spawn("Hidden red wall") { Mesh3DComponent(mesh:Mesh.generateCube(size:[16,16,0.1],renderDevice:s.device),materials:[red]); Transform(position:[0,0,-4.55]) }
            let lamp = s.app.main.spawn("Hidden local lamp") { PointLightComponent(intensity:80,range:2); Transform(position:[0,0,-3.8]) }
            try s.configure { $0.pathTracing.maximumBounces = 1 }
            let direct = try await s.render(.none,frames:3)
            try s.configure { $0.pathTracing.maximumBounces = 3; $0.pathTracing.samplesPerPixel = 8 }
            let bounce = try await s.render(.none,frames:16)
            #expect(Self.red(bounce)>Self.red(direct)+0.02,"A receiver outside the light range must see bounce from a wall behind the camera")
            red.emissiveFactor = [1,0.005,0.001]; red.emissiveStrength = 3
            lamp.components[PointLightComponent.self] = PointLightComponent(intensity:0,range:2)
            receiver.metallicFactor = 1; receiver.roughnessFactor = 0.04
            let reflection = try await s.render(.none,frames:4)
            let pixel = reflection.getPixel(x:320,y:240)
            #expect(pixel.red>pixel.green+0.1 && pixel.red>0.2,"A mirror must reflect offscreen emissive triangles")
            try bounce.writePNG(to:GoldenFrame.outputDirectory.appendingPathComponent("path-hidden-bounce.png"))
            try reflection.writePNG(to:GoldenFrame.outputDirectory.appendingPathComponent("path-hidden-reflection.png"))
        }

        @Test(.enabled(if:GoldenFrame.activeBackend != nil))
        func spotConeTextureAtlasAndResizeWork() async throws {
            let s = try await Self.scene(); let pbr = Self.receiver(s)
            pbr.baseColorTexture = Texture2D(image:Image(width:2,height:2,color:Color(0.9,0.01,0.005,1)))
            let lamp = s.app.main.spawn("Spot behind camera") {
                SpotLightComponent(intensity:400,range:20,innerConeAngle:15,outerConeAngle:25)
                Transform(rotation:Quat(axis:.up,angle:Float.pi/4),position:[-6,0,-6])
            }
            let on = try await s.render(.none,frames:3)
            #expect(try Self.stats(s).snapshots.values.allSatisfy { $0.failure == nil && $0.encodedFrames > 0 })
            let pixel = on.getPixel(x:320,y:240)
            #expect(pixel.red>pixel.green+0.1)
            lamp.components[Transform.self] = Transform(rotation:Quat(axis:.up,angle:Float.pi*1.25),position:[-6,0,-6])
            let off = try await s.render(.none,frames:1)
            #expect(Self.red(off)<0.01)
            try s.configure { $0.pathTracing.resolutionScale = 0.25 }
            _ = try await s.render(.none,frames:1)
            #expect(try Self.stats(s).snapshots.values.allSatisfy { $0.width == 160 && $0.height == 120 && $0.accumulatedFrames == 1 && $0.failure == nil })
        }

        @Test(.enabled(if:GoldenFrame.activeBackend != nil), arguments:[false,true])
        func cosmeticGraphsCompositeAfterTracingAndRespectOpaqueDepth(blended: Bool) async throws {
            let s = try await Self.scene(); _ = Self.receiver(s)
            var graph = ShaderGraph(target:.pbrSurface,output:"output",nodes:[
                .init(id:"green",operation:.constant,type:.vector3,value:[0,3,0]),
                .init(id:"black",operation:.constant,type:.color,value:[0,0,0,1]),
                .init(id:"output",operation:.output,inputs:["baseColor":.init("black"),"emission":.init("green")])
            ])
            graph.renderSettings.mode = blended ? .blend : .opaque
            graph.renderSettings.doubleSided = true
            let instance = try ShaderGraphMaterial(source:.init(graph:graph))
            let material = PBRMaterial(); material.graphMaterial = instance; material.metallicFactor = 0
            let card = s.app.main.spawn("Cosmetic graph") {
                Mesh3DComponent(mesh:BakedLighting.quad(device:s.device),materials:[material],castShadows:false,receiveShadows:false)
                Transform(position:[0,0,-0.5])
            }
            let front = try await s.render(.none,frames:6)
            let pixel = front.getPixel(x:320,y:240)
            #expect(pixel.green>pixel.red+0.3 && pixel.green>0.5)
            #expect(try Self.stats(s).snapshots.values.allSatisfy { $0.failure == nil && $0.encodedFrames >= 6 && $0.triangles == 2 })
            #expect(instance.compilationError == nil && instance.hasPreparedPipeline)
            card.components[Transform.self] = Transform(position:[0,0,0.5])
            let behind = try await s.render(.none,frames:2)
            #expect(behind.getPixel(x:320,y:240).green<0.01,"The graph pass must load opaque depth and never clear traced HDR")
        }
    }
}
#endif
