#if os(macOS)
import AdaECS
@_spi(Internal) import AdaRender
import AdaScene
import AdaUtils
import Foundation
import Math
import Testing

@testable import AdaCorePipelines

/// Tile bounds for local lights; no GPU needed.
@Suite("3D light tiles")
struct Render3DLightTilesMathTests {
    private static let width = 640, height = 480
    private static let layout = LightTiles3DMath.layout(width: width, height: height)
    private static let viewport = Rect(x: 0, y: 0, width: Float(width), height: Float(height))
    private static let projection = Transform3D.perspective(fieldOfView: .degrees(60), aspectRatio: Float(width) / Float(height), zNear: 0.1, zFar: 100)

    private static func masks(_ lights: [(center: Vector3, range: Float)]) -> [UInt32] {
        LightTiles3DMath.masks(spheres: lights, projection: projection, viewport: viewport, layout: layout)
    }

    private static func tile(x: Int, y: Int) -> Int {
        (y / layout.tileSize) * layout.columns + x / layout.tileSize
    }

    @Test func layoutKeepsTileCountWithinTheMaskBuffer() {
        let full = LightTiles3DMath.layout(width: 1920, height: 1080)
        #expect(full == .init(tileSize: 32, columns: 60, rows: 34))
        for (width, height) in [(3840, 2160), (7680, 4320), (1, 1), (100_000, 10)] {
            let layout = LightTiles3DMath.layout(width: width, height: height)
            #expect(layout.count <= LightTiles3DMath.maximumTiles && layout.columns * layout.tileSize >= width && layout.rows * layout.tileSize >= height)
        }
    }

    @Test func allLightsSetsTheLowBits() {
        #expect(LightTiles3DMath.allLights(0) == 0)
        #expect(LightTiles3DMath.allLights(3) == 0b111)
        #expect(LightTiles3DMath.allLights(32) == UInt32.max)
        #expect(LightTiles3DMath.allLights(99) == UInt32.max)
    }

    @Test func aSmallLightAheadReachesOnlyTilesAroundItsProjection() {
        let masks = Self.masks([(center: [0, 0, 10], range: 1)])
        #expect(masks[Self.tile(x: 320, y: 240)] == 1, "The tile under the light must list it.")
        #expect(masks[Self.tile(x: 5, y: 5)] == 0 && masks[Self.tile(x: 630, y: 470)] == 0, "Far corners cannot be reached.")
        #expect(masks.filter { $0 != 0 }.count < Self.layout.count / 4)
    }

    @Test func lightsBehindTheCameraOrOffToTheSideReachNothing() {
        let behind = Self.masks([(center: [0, 0, -10], range: 2)])
        #expect(behind.allSatisfy { $0 == 0 })
        let aside = Self.masks([(center: [100, 0, 10], range: 1)])
        #expect(aside.allSatisfy { $0 == 0 })
    }

    @Test func aLightReachingTheCameraPlaneCoversEveryTile() {
        let masks = Self.masks([(center: [0, 0, 1], range: 3)])
        #expect(masks.allSatisfy { $0 == 1 })
    }

    @Test func eachLightGetsItsOwnBit() {
        let masks = Self.masks([(center: [-4, 0, 10], range: 1), (center: [4, 0, 10], range: 1)])
        #expect(masks[Self.tile(x: 100, y: 240)] & 1 != 0 && masks[Self.tile(x: 100, y: 240)] & 2 == 0)
        #expect(masks[Self.tile(x: 540, y: 240)] & 2 != 0 && masks[Self.tile(x: 540, y: 240)] & 1 == 0)
    }

    @Test func lightsBeyondThirtyTwoAreIgnored() {
        let lights = (0..<40).map { _ in (center: Vector3(0, 0, 10), range: Float(1)) }
        let masks = Self.masks(lights)
        #expect(masks[Self.tile(x: 320, y: 240)] == UInt32.max)
    }

    @Test func aViewportOffsetMovesTheTiles() {
        let offset = Rect(x: 320, y: 0, width: 320, height: 480)
        let masks = LightTiles3DMath.masks(spheres: [(center: [0, 0, 10], range: 0.5)], projection: Self.projection, viewport: offset, layout: Self.layout)
        #expect(masks[Self.tile(x: 480, y: 240)] == 1 && masks[Self.tile(x: 100, y: 240)] == 0)
    }

    @Test func tilingDefaultsOnAndOlderPayloadsDecode() throws {
        #expect(Environment3D().tiledLocalLights)
        #expect(try JSONDecoder().decode(Environment3D.self, from: Data("{}".utf8)).tiledLocalLights)
        var environment = Environment3D()
        environment.tiledLocalLights = false
        #expect(try !JSONDecoder().decode(Environment3D.self, from: JSONEncoder().encode(environment)).tiledLocalLights)
    }
}

extension Render3DGPUTests {
    /// Run alone: `ADAENGINE_GOLDEN_SAGA=1 swift test --filter Render3DGPUTests/LightTiles`.
    @Suite("3D light tiles on GPU")
    @MainActor
    struct LightTiles {
        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func tiledLightingMatchesTheFlatLoop() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            for index in 0..<10 {
                let side: Float = index % 2 == 0 ? -1 : 1
                scene.app.main.spawn("Fill \(index)") {
                    PointLightComponent(radiance: [0.4 + 0.06 * Float(index), 0.6, 1 - 0.07 * Float(index)], intensity: 6, castShadows: false, range: 2.2)
                    Transform(position: [side * Float(index) * 0.45, 0.4 + Float(index % 3) * 0.3, Float(index) * 0.2 - 0.6])
                }
            }
            scene.app.main.spawn("Shadowed") {
                PointLightComponent(radiance: [1, 0.8, 0.6], intensity: 8, castShadows: true, range: 4)
                Transform(position: [0, 1.5, -1])
            }
            try scene.configure { $0.tiledLocalLights = false }
            let flat = try await scene.render(.none)
            try scene.configure { $0.tiledLocalLights = true }
            let tiled = try await scene.render(.none)
            #expect(
                GoldenFrame.compare(flat, tiled, tolerance: GoldenFrame.activeTolerance).passes(GoldenFrame.activeTolerance),
                "Tile masks are conservative, so they must not change the lit image."
            )
        }
    }
}
#endif
