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
    @MainActor @Suite("Dynamic world irradiance")
    struct DynamicIrradiance {
        typealias Helpers = BakedLighting
        static func paths() throws -> (IrradianceProbeGrid3D, ProbeTransport3D) {
            let samples = 128
            func direction(_ i: Int) -> Vector3 {
                let y: Float = 1-2*(Float(i)+0.5)/Float(samples)
                let r: Float = Math.sqrt(max(1-y*y,0))
                let phi: Float = Float(i)*2.399963229728653
                return Vector3(r*Math.cos(phi),y,r*Math.sin(phi))
            }
            let positions = Helpers.texture(width:2*samples,height:4) { x,row in
                let probe = Vector3(Float(x/samples)*2-1,Float(row%2)*2-1,Float(row/2)*2-1)
                let d = direction(x%samples)
                guard d.z < -0.1 else { return .zero }
                let t: Float = (-4.5-probe.z)/d.z
                let position: Vector3 = probe + d * t
                if abs(position.x)>6 || abs(position.y)>6 { return .zero }
                return Vector4(position,Float(1))
            }
            let normals = Helpers.texture(width:2*samples,height:4) { _,_ in [0,0,1,1] }
            let albedo = Helpers.texture(width:2*samples,height:4) { _,_ in [0.8,0.015,0.005,1] }
            let sh = Helpers.texture(width:18,height:4) { _,_ in [0,0,0,1] }
            let visibility = Helpers.texture(width:32,height:64) { _,_ in [100,10000,100,1] }
            return (try .init(origin:[-1,-1,-1],spacing:[2,2,2],counts:[2,2,2],visibilityResolution:16,coefficients:sh,visibility:visibility),
                try .init(origin:[-1,-1,-1],spacing:[2,2,2],counts:[2,2,2],samples:samples,positions:positions,normals:normals,albedo:albedo))
        }
        static func fixture() async throws -> (DebugViews.Scene, PBRMaterial, IrradianceProbeGrid3D, ProbeTransport3D) {
            let s = try await Helpers.scene()
            s.camera.components[Transform.self] = Transform(position:[0,0,-1.5])
            let material = PBRMaterial(); material.baseColorFactor = .one; material.metallicFactor = 0; material.roughnessFactor = 1
            s.app.main.spawn("Visible receiver") { Mesh3DComponent(mesh:Helpers.quad(device:s.device),materials:[material]); Transform() }
            let red = PBRMaterial(); red.baseColorFactor = [0.8,0.015,0.005,1]; red.metallicFactor = 0
            s.app.main.spawn("Hidden red bounce wall") {
                Mesh3DComponent(mesh:Mesh.generateCube(size:[12,12,0.1],renderDevice:s.device),materials:[red])
                Transform(position:[0,0,-4.55])
            }
            let (grid,paths) = try Self.paths()
            try s.configure {
                $0.imageBasedLighting = nil
                $0.irradianceProbes = .init(asset:AssetHandle(grid))
            }
            return (s,material,grid,paths)
        }

        @Test(.enabled(if: GoldenFrame.activeBackend != nil))
        func hiddenPointLightRelightsLightmappedReceiverMovesAndClears() async throws {
            let (s,material,grid,paths) = try await Self.fixture()
            material.lightmapTexture = Helpers.texture(width:2,height:2) { _,_ in [0,0,0,1] }
            // The light's complete range is behind the camera; receiver is outside its direct range.
            let lamp = s.app.main.spawn("Offscreen point") {
                PointLightComponent(intensity:200,range:2,indirectIntensity:1)
                Transform(position:[0,0,-3.8])
            }
            let baseline = try await s.render(.none)
            try s.configure { $0.irradianceProbes = .init(asset:AssetHandle(grid),dynamic:.init(transport:AssetHandle(paths),probesPerFrame:2,historyWeight:0)) }
            let bounced = try await s.render(.none,frames:12)
            let before = baseline.getPixel(x:320,y:240), after = bounced.getPixel(x:320,y:240)
            #expect(after.red > before.red+0.025 && after.red > after.green+0.025, "Hidden red wall must transfer light to a lightmapped receiver.")
            let stats = try #require(s.app.getSubworldBuilder(by:.renderWorld)?.getResource(Render3DDynamicGIStatistics.self))
            #expect(stats.snapshots.values.allSatisfy { $0.updatedProbes == 2 && $0.sweeps >= 3 })
            lamp.components[Transform.self] = Transform(position:[8,0,-3.8])
            let moved = try await s.render(.none,frames:8)
            #expect(moved.getPixel(x:320,y:240).red < after.red*0.7, "Moving a lamp must relight cached world paths.")
            lamp.components[PointLightComponent.self] = PointLightComponent(intensity:0,range:2,indirectIntensity:1)
            let off = try await s.render(.none,frames:1)
            #expect(abs(off.getPixel(x:320,y:240).red-before.red)<0.01, "No active lights clears every probe immediately.")
            #expect(stats.snapshots.values.allSatisfy { $0.updatedProbes == 8 && $0.lightCount == 0 })
            try s.configure { $0.irradianceProbes?.dynamic = nil }
            _ = try await s.render(.none,frames:1)
            #expect(stats.snapshots.isEmpty, "Disabled relighting releases per-view work/history/statistics.")
            try FileManager.default.createDirectory(at:GoldenFrame.outputDirectory,withIntermediateDirectories:true)
            try baseline.writePNG(to:GoldenFrame.outputDirectory.appendingPathComponent("world-gi-off.png"))
            try bounced.writePNG(to:GoldenFrame.outputDirectory.appendingPathComponent("world-gi-hidden-point.png"))
        }

        @Test(.enabled(if: GoldenFrame.activeBackend != nil))
        func hiddenSpotConeAndShadowOccluderControlBounce() async throws {
            let (s,_,grid,paths) = try await Self.fixture()
            let lamp = s.app.main.spawn("Offscreen spot") {
                SpotLightComponent(intensity:200,range:2,innerConeAngle:35,outerConeAngle:55,indirectIntensity:1)
                Transform(rotation:Quat(axis:.up,angle:.pi),position:[0,0,-3.8])
            }
            try s.configure { $0.irradianceProbes = .init(asset:AssetHandle(grid),dynamic:.init(transport:AssetHandle(paths),probesPerFrame:8,historyWeight:0)) }
            let lit = try await s.render(.none,frames:6)
            lamp.components[Transform.self] = Transform(position:[0,0,-3.8])
            let away = try await s.render(.none,frames:4)
            #expect(lit.getPixel(x:320,y:240).red > away.getPixel(x:320,y:240).red+0.02, "Offscreen spotlight cone must change diffuse transport.")
            lamp.components[Transform.self] = Transform(rotation:Quat(axis:.up,angle:.pi),position:[0,0,-3.8])
            // A real blocker between the source and hidden bounce plane, submitted only to light-volume shadows.
            let blocker = s.app.main.spawn("Hidden blocker") {
                Mesh3DComponent(mesh:Mesh.generateCube(size:[4,4,0.1],renderDevice:s.device),materials:[PBRMaterial()])
                Transform(position:[0,0,-4.05])
            }
            let blocked = try await s.render(.none,frames:5)
            #expect(blocked.getPixel(x:320,y:240).red < lit.getPixel(x:320,y:240).red*0.65, "Shadow atlas must prevent injection through a blocker.")
            s.app.main.removeEntity(blocker)
            let restored = try await s.render(.none,frames:5)
            #expect(restored.getPixel(x:320,y:240).red > blocked.getPixel(x:320,y:240).red+0.02)
            try restored.writePNG(to:GoldenFrame.outputDirectory.appendingPathComponent("world-gi-hidden-spot.png"))
        }

        @Test
        func oldLightsOptOutAndInvalidTransportLayoutsFail() throws {
            #expect(try JSONDecoder().decode(PointLightComponent.self,from:Data("{}".utf8)).indirectIntensity == 0)
            #expect(try JSONDecoder().decode(SpotLightComponent.self,from:Data("{}".utf8)).indirectIntensity == 0)
            #expect(!ProbeTransport3D.valid(origin:.zero,spacing:.one,counts:[],samples:128))
            #expect(!ProbeTransport3D.valid(origin:.zero,spacing:.one,counts:[64,2,2],samples:128))
            #expect(!ProbeTransport3D.valid(origin:.zero,spacing:[0,1,1],counts:[2,2,2],samples:128))
            let lamp = ExtractedLocalLight3D(entity:1,kind:.point,position:[0,0,-3.8],range:2,indirectIntensity:1)
            #expect(LocalLighting3DMath.select([lamp],viewProjection:.identity,cameraPosition:.zero).isEmpty)
            let selected = LocalLighting3DMath.select([lamp],viewProjection:.identity,cameraPosition:.zero,
                irradianceBounds:AABB(center:[0,0,-4.5],halfExtents:[6,6,0.1]))
            #expect(selected.count == 1, "A hidden source can hit cached surfaces outside the receiver grid.")
        }
    }
}
#endif
