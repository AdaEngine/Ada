#if os(macOS)
@_spi(Internal) @testable import AdaRender
import AdaScene
import Foundation
import Math
import Testing

@testable import AdaCorePipelines

/// Parallax material settings that need no GPU.
@Suite("3D parallax material settings")
@MainActor
struct Render3DParallaxSettingsTests {
    private func texture() -> Texture2D {
        let device = HeadlessRenderBackend().renderDevice
        return Texture2D(
            gpuTexture: device.createTexture(from: .init(textureUsage: .read, textureType: .texture2D)),
            sampler: device.createSampler(from: SamplerDescriptor()), size: [1, 1]
        )
    }

    @Test func materialsWithoutHeightMapsDisableParallax() {
        let uniform = PBR3DUniform(material: PBRMaterial(), descriptor: VertexDescriptor())
        #expect(uniform.flags.z == 0)
        #expect(uniform.parallax.x == 0)
    }

    @Test func heightMapEnablesParallaxWithClampedSettings() {
        let material = PBRMaterial()
        material.heightTexture = texture()
        material.heightScale = 0.2
        material.heightTextureCoordinate = 7
        material.heightMaxLayers = 1000
        material.heightFadeDistance = -4
        let uniform = PBR3DUniform(material: material, descriptor: VertexDescriptor())
        #expect(uniform.flags.z == 1)
        #expect(uniform.parallax.x == 0.2)
        #expect(uniform.parallax.y == 1)
        #expect(uniform.parallax.z == 64)
        #expect(uniform.parallax.w == 0.1)
    }

    @Test func zeroOrInvalidScaleDisablesParallax() {
        let material = PBRMaterial()
        material.heightTexture = texture()
        material.heightScale = 0
        #expect(PBR3DUniform(material: material, descriptor: VertexDescriptor()).flags.z == 0)
        material.heightScale = .nan
        #expect(PBR3DUniform(material: material, descriptor: VertexDescriptor()).flags.z == 0)
    }

    @Test func editingTheHeightMapInvalidatesTheSharedUniform() {
        let material = PBRMaterial()
        let before = material.uniformRevision
        material.heightTexture = texture()
        #expect(material.uniformRevision != before)
    }
}

extension Render3DGPUTests {
    /// Renders a relief ground through the real Metal pipeline.
    ///
    /// Run alone: `ADAENGINE_GOLDEN_SAGA=1 swift test --filter Render3DParallaxGPUTests`.
    @Suite("3D parallax on GPU")
    @MainActor
    struct Parallax {
        /// A bar of high ground (white) across the V axis on a low floor (black).
        private static func barTexture() -> Texture2D {
            let size = 64
            var bytes = [UInt8](repeating: 255, count: size * size * 4)
            for row in 0..<size {
                let value: UInt8 = (28..<36).contains(row) ? 255 : 0
                for column in 0..<size {
                    let offset = (row * size + column) * 4
                    bytes[offset] = value
                    bytes[offset + 1] = value
                    bytes[offset + 2] = value
                }
            }
            return Texture2D(image: Image(width: size, height: size, data: Data(bytes), format: .rgba8))
        }

        private static func brightRange(in image: Image, column: Int) -> ClosedRange<Int>? {
            let bright = (0..<image.height).filter { image.getPixel(x: column, y: $0).red > 0.5 && image.getPixel(x: column, y: $0).green > 0.5 }
            guard let first = bright.first, let last = bright.last else { return nil }
            return first...last
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func heightMapShiftsTheReliefTowardTheCameraAndZeroScaleChangesNothing() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            let ground = try #require(scene.groundMaterial)
            ground.baseColorFactor = [1, 1, 1, 1]
            ground.baseColorTexture = Self.barTexture()
            let flat = try await scene.render(.none)

            ground.heightTexture = Self.barTexture()
            ground.heightScale = 0
            let zeroScale = try await scene.render(.none)
            #expect(GoldenFrame.compare(flat, zeroScale, tolerance: GoldenFrame.activeTolerance).differingPixels == 0)

            ground.heightScale = 0.4
            let relief = try await scene.render(.none)
            #expect(GoldenFrame.compare(flat, relief, tolerance: GoldenFrame.activeTolerance).differingPixels > 500)
            let flatBar = try #require(Self.brightRange(in: flat, column: 320), "The flat bar must be visible.")
            let reliefBar = try #require(Self.brightRange(in: relief, column: 320), "The relief bar must be visible.")
            // The raised bar's near wall hides floor, so the bright region grows toward the camera (down the image).
            #expect(reliefBar.upperBound > flatBar.upperBound, "Parallax must extend the bar toward the camera: \(flatBar) vs \(reliefBar).")
        }
    }
}
#endif
