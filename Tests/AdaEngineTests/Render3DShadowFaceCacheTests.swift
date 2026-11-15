#if os(macOS)
import AdaECS
@_spi(Internal) import AdaRender
import AdaScene
import AdaTransform
import AdaUtils
import Foundation
import Math
import Testing

@testable import AdaCorePipelines

@Suite("3D local shadow face cache settings")
struct Render3DShadowFaceCacheSettingsTests {
    @Test func reuseDefaultsOnAndOlderPayloadsDecode() throws {
        #expect(LocalShadowSettings3D().reusesStaticFaces)
        let decoded = try JSONDecoder().decode(LocalShadowSettings3D.self, from: Data(#"{"isEnabled":true,"maximumLights":2}"#.utf8))
        #expect(decoded.reusesStaticFaces && decoded.maximumLights == 2)
        let off = LocalShadowSettings3D(reusesStaticFaces: false)
        #expect(try !JSONDecoder().decode(LocalShadowSettings3D.self, from: JSONEncoder().encode(off)).reusesStaticFaces)
    }

    @Test func digestsDependOnEveryWord() {
        var first = FrameDigest3D()
        var second = FrameDigest3D()
        first.combine(Transform3D.identity)
        second.combine(Transform3D.identity)
        #expect(first.value == second.value)
        second.combine(1 as Float)
        #expect(first.value != second.value)
        var moved = FrameDigest3D()
        moved.combine(Vector4(0, 0, 0.001, 1))
        #expect(moved.value != FrameDigest3D().value)
    }
}

extension Render3DGPUTests {
    /// Run alone: `ADAENGINE_GOLDEN_SAGA=1 swift test --filter Render3DGPUTests/ShadowFaceCache`.
    @Suite("3D local shadow face cache on GPU")
    @MainActor
    struct ShadowFaceCache {
        struct Fixture {
            let scene: Render3DGPUTests.DebugViews.Scene
            let caster: Entity
            let light: Entity
            let renderWorld: World

            var snapshot: Render3DLightStatistics.Snapshot? {
                renderWorld.getResource(Render3DLightStatistics.self)?.snapshots.values.first
            }

            func moveCaster(to position: Vector3) {
                caster.components[Transform.self] = Transform(position: position)
            }
        }

        private static func makeFixture() async throws -> Fixture {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            let caster = scene.app.main.spawn("Caster") {
                Mesh3DComponent(mesh: Mesh.generateSphere(radius: 0.25, renderDevice: scene.device), materials: [PBRMaterial()])
                Transform(position: [0.2, 1.1, -0.4])
            }
            let light = scene.app.main.spawn("Shadow Point") {
                PointLightComponent(radiance: [1, 0.85, 0.7], intensity: 9, castShadows: true, range: 5)
                Transform(position: [0, 1.6, -1.2])
            }
            let renderWorld = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.main)
            return Fixture(scene: scene, caster: caster, light: light, renderWorld: renderWorld)
        }

        private static func matches(_ left: Image, _ right: Image) -> Bool {
            GoldenFrame.compare(left, right, tolerance: GoldenFrame.activeTolerance).passes(GoldenFrame.activeTolerance)
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func aStaticSceneReusesEveryFaceAndLooksTheSame() async throws {
            let fixture = try await Self.makeFixture()
            try fixture.scene.configure { $0.localShadows.reusesStaticFaces = false }
            let uncached = try await fixture.scene.render(.none)
            #expect(fixture.snapshot?.reusedShadowFaces == 0)
            try fixture.scene.configure { $0.localShadows.reusesStaticFaces = true }
            _ = try await fixture.scene.render(.none, frames: 2)
            let faces = try #require(fixture.snapshot).shadowFaces
            #expect(faces == 6)
            let cached = try await fixture.scene.render(.none)
            #expect(fixture.snapshot?.reusedShadowFaces == faces, "Nothing changed, so every face must be kept.")
            #expect(Self.matches(uncached, cached), "Reused faces must show exactly what a redraw shows.")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func movingACasterRedrawsOnlyTheFacesItTouches() async throws {
            let fixture = try await Self.makeFixture()
            _ = try await fixture.scene.render(.none, frames: 3)
            fixture.moveCaster(to: [0.2, 1.1, 0.6])
            // One frame: only the first frame after a change redraws, later frames reuse the new faces again.
            let cached = try await fixture.scene.render(.none, frames: 1)
            let snapshot = try #require(fixture.snapshot)
            #expect(snapshot.reusedShadowFaces < snapshot.shadowFaces, "A moved caster must dirty a face.")
            #expect(snapshot.reusedShadowFaces > 0, "Faces the caster never reaches must be kept, so the load path is exercised.")
            #expect(snapshot.reusedShadowFaces > 0, "Faces the caster never touches must be kept, which exercises the partial redraw.")
            try fixture.scene.configure { $0.localShadows.reusesStaticFaces = false }
            let redrawn = try await fixture.scene.render(.none)
            #expect(Self.matches(redrawn, cached), "A partly reused atlas must equal a full redraw after the caster moved.")
            try fixture.scene.configure { $0.localShadows.reusesStaticFaces = true }
            fixture.moveCaster(to: [0.2, 1.1, -0.4])
            let back = try await fixture.scene.render(.none, frames: 1)
            fixture.moveCaster(to: [0.2, 1.1, -0.4])
            try fixture.scene.configure { $0.localShadows.reusesStaticFaces = false }
            let backRedrawn = try await fixture.scene.render(.none)
            #expect(Self.matches(back, backRedrawn))
        }

        private func preparedPasses(_ fixture: Fixture) throws -> Int {
            try #require(fixture.renderWorld.getResource(VisibleMesh3DLists.self)).preparedPassCount
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func anUnchangedSceneDoesNotRebuildFaceLists() async throws {
            let fixture = try await Self.makeFixture()
            try fixture.scene.configure { $0.localShadows.reusesStaticFaces = false }
            _ = try await fixture.scene.render(.none, frames: 3)
            let before = try preparedPasses(fixture)
            _ = try await fixture.scene.render(.none, frames: 1)
            let rebuilding = try preparedPasses(fixture) - before
            try fixture.scene.configure { $0.localShadows.reusesStaticFaces = true }
            _ = try await fixture.scene.render(.none, frames: 3)
            let kept = try preparedPasses(fixture)
            _ = try await fixture.scene.render(.none, frames: 1)
            let reusing = try preparedPasses(fixture) - kept
            #expect(rebuilding - reusing == 6, "The six local faces must not be prepared again (\(rebuilding) without reuse, \(reusing) with).")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func aNewCasterIsNoticedWithoutRebuildingEverything() async throws {
            let fixture = try await Self.makeFixture()
            _ = try await fixture.scene.render(.none, frames: 3)
            fixture.scene.app.main.spawn("Late Caster") {
                Mesh3DComponent(mesh: Mesh.generateSphere(radius: 0.3, renderDevice: fixture.scene.device), materials: [PBRMaterial()])
                Transform(position: [-0.4, 0.9, -0.6])
            }
            let cached = try await fixture.scene.render(.none, frames: 1)
            #expect(try #require(fixture.snapshot).reusedShadowFaces < 6, "A caster entering the light's range must dirty a face.")
            try fixture.scene.configure { $0.localShadows.reusesStaticFaces = false }
            let redrawn = try await fixture.scene.render(.none)
            #expect(Self.matches(cached, redrawn))
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func movingTheLightRedrawsEveryFace() async throws {
            let fixture = try await Self.makeFixture()
            _ = try await fixture.scene.render(.none, frames: 3)
            fixture.light.components[Transform.self] = Transform(position: [0.3, 1.6, -1.2])
            _ = try await fixture.scene.render(.none, frames: 1)
            #expect(fixture.snapshot?.reusedShadowFaces == 0)
        }
    }
}
#endif
