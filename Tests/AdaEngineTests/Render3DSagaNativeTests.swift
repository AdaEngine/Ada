#if os(macOS) || os(Windows) || os(Linux)
    @testable import AdaCorePipelines
    @_spi(Internal) import AdaRender
    import AdaUtils
    import Foundation
    import Math
    import Testing

    private let compareSagaWithMetal = ProcessInfo.processInfo.environment["ADAENGINE_COMPARE_SAGA_METAL"] == "1"

    extension Render3DGPUTests {
        /// Renders the real 3D pipeline (`flat3d.wesl` and the other WESL shaders) through SAGA's native runtime.
        /// Run with `ADAENGINE_GOLDEN_SAGA=1 ADAENGINE_SAGA_NATIVE=1 swift test --filter Render3DGPUTests/SagaNative`.
        @Suite("SAGA native")
        @MainActor
        struct SagaNative {
            #if SAGA_NATIVE || SAGA_METAL_NATIVE_PASS
            @Test(.enabled(if: GoldenFrame.activeBackend == .saga && sagaNativeTestDeviceAvailable()))
            func gpuVisibilityCompactsAndDrawsTheProductionScene() async throws {
                let scene = try await DebugViews.makeScene()
                try scene.configure { $0.gpuOcclusionEnabled = false }
                let ordinary = try await scene.render(.none)
                try scene.configure { $0.gpuOcclusionEnabled = true }
                let world = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.main)
                var compacted = ordinary
                // Read back each preparation frame so the next frame sees completed SAGA resource work.
                for _ in 0..<4 {
                    compacted = try await scene.render(.none, frames: 1)
                    if world.getResource(GPUVisibility3DState.self)?.output(for: scene.camera.id) != nil { break }
                }
                let output = try #require(
                    world.getResource(GPUVisibility3DState.self)?.output(for: scene.camera.id),
                    "GPU visibility must produce indirect draws after the preparation frames."
                )
                #expect(output.drawCount > 0)
                let comparison = GoldenFrame.compare(compacted, ordinary, tolerance: GoldenFrame.activeTolerance)
                #expect(comparison.passes(GoldenFrame.activeTolerance))
            }
            #endif

            private static var legacyReference: URL {
                GoldenFrame.outputDirectory.appendingPathComponent("legacy-metal-spheres.png")
            }

            @Test(.enabled(if: GoldenFrame.activeBackend == .saga))
            func theLitSphereRowRendersWithTheWESLShaders() async throws {
                let scene = try await DebugViews.makeScene()
                let image = try await scene.render(.none, frames: 4)
                try image.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("saga-native-spheres.png"))
                if compareSagaWithMetal {
                    let reference = try Image(contentsOf: Self.legacyReference)
                    let comparison = GoldenFrame.compare(image, reference, tolerance: .metal)
                    #expect(comparison.passes(.metal),
                            "SAGA differs from the recorded Metal frame: \(comparison.differingPixels) pixels, max step \(comparison.largestStep)")
                }

                let background = Color(red: 0.55, green: 0.7, blue: 0.9)
                func isBackground(_ color: Color) -> Bool {
                    abs(color.red - background.red) < 0.06 && abs(color.green - background.green) < 0.06 && abs(color.blue - background.blue) < 0.06
                }
                // The camera looks along +Z at four spheres whose centers cross the middle row.
                var shaded = 0
                var lit = 0
                var luminance: Float = 0
                let row = image.height / 2
                for x in 0..<image.width {
                    let pixel = image.getPixel(x: x, y: row)
                    if !isBackground(pixel) {
                        shaded += 1
                        luminance = max(luminance, (pixel.red + pixel.green + pixel.blue) / 3)
                        if pixel.red > pixel.blue { lit += 1 }
                    }
                }
                #expect(shaded > image.width / 4, "The spheres must cover a good share of the middle row: \(shaded)")
                #expect(lit > 0, "Their warm base color must show: \(lit)")
                #expect(luminance > 0.05, "The spheres must be lit: \(luminance)")
            }

            /// A Shader Graph material goes through the WGSL generator and the `flat3d.wesl` template at runtime.
            @Test(.enabled(if: GoldenFrame.activeBackend == .saga))
            func aShaderGraphMaterialRendersThroughTheWESLTemplate() async throws {
                let scene = try await DebugViews.makeScene()
                let ground = try #require(scene.groundMaterial)
                let graph = ShaderGraph(target: .pbrSurface, output: "output", nodes: [
                    .init(id: "tint", operation: .parameter, type: .color, value: [0.9, 0.08, 0.08, 1], reference: "tint"),
                    .init(id: "output", operation: .output, inputs: ["baseColor": .init("tint")]),
                ])
                let instance = try ShaderGraphMaterial(source: .init(graph: graph))
                ground.graphMaterial = instance
                let image = try await scene.render(.none, frames: 4)
                try image.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("saga-native-graph.png"))
                #expect(instance.compilationError == nil, "\(instance.compilationError ?? "")")
                #expect(instance.hasPreparedPipeline)
                // The floor fills the bottom of the frame: its graph color is red, the unlit original is gray-green.
                let pixel = image.getPixel(x: image.width / 2, y: image.height - 20)
                #expect(pixel.red > pixel.green * 2 && pixel.red > pixel.blue, "Graph color must reach the floor: \(pixel)")
            }
        }
    }
#endif
