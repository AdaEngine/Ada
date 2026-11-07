#if os(macOS) || os(Windows) || os(Linux)
    import AdaRender
    import AdaUtils
    import Foundation
    import Testing

    extension Render3DGPUTests.TerrainMaterials {
        @Test("Fading height layers retain bounded influence and equal-height base mixtures", arguments: ["neutral", "high"])
        func terrainMaterialHeightBlendFadePixels(kind: String) async throws {
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            let directory = root.appendingPathComponent("TerrainHeightFade-" + UUID().uuidString, isDirectory: true).standardizedFileURL
            try #require(directory.deletingLastPathComponent() == root)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let scene = try await makeScene(in: directory, textured: true, heightFade: kind)
            let image = try #require(try await scene.engine.renderDevice.readImage(from: scene.target))
            // Albedo debug output is display encoded; compare the underlying linear material proportions.
            func linear(_ color: Color) -> Color {
                func channel(_ value: Float) -> Float { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
                return Color(channel(color.red), channel(color.green), channel(color.blue), color.alpha)
            }
            let present = linear(image.getPixel(x: 80, y: 64)), absent = linear(image.getPixel(x: 176, y: 64))
            try #require(present.red + present.green + present.blue > 0.8 && absent.red + absent.blue > 0.8)
            // Equal map heights must preserve the red/blue base ratio after the third rule fades to zero.
            #expect(abs(absent.red - 0.6) < 0.03 && abs(absent.blue - 0.4) < 0.03 && absent.green < 0.01)
            if kind == "neutral" {
                #expect(abs(present.red - absent.red) < 0.03 && abs(present.blue - absent.blue) < 0.03 && present.green < 0.02)
            } else {
                // Even a high map cannot discard the base at a small positive weight (one 8-bit field step).
                #expect(present.green > 0.3 && present.green < 0.65 && present.red > 0.2 && present.blue > 0.1)
            }
        }
    }
#endif
