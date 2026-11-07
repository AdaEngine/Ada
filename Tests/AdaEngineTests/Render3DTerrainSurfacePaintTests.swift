#if os(macOS) || os(Windows) || os(Linux)
    import AdaRender
    import AdaUtils
    import Foundation
    import Testing

    extension Render3DGPUTests.TerrainMaterials {
        @Test("Native layer paint, tint and roughness reach real terrain pixels", arguments: ["layer", "tint", "roughness"])
        func terrainMaterialSurfacePaintPixels(kind: String) async throws {
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            let directory = root.appendingPathComponent("TerrainSurfacePixels-" + UUID().uuidString, isDirectory: true).standardizedFileURL
            try #require(directory.deletingLastPathComponent() == root)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let scene = try await makeScene(
                in: directory, textured: kind == "layer", view: kind == "roughness" ? .roughness : .albedo, surfaceMode: kind
            )
            let image = try #require(try await scene.engine.renderDevice.readImage(from: scene.target))
            let outside = image.getPixel(x: 80, y: 64), inside = image.getPixel(x: kind == "layer" ? 112 : 128, y: 64)
            if kind == "layer" {
                try #require(outside.red > 0.8 && outside.blue < 0.1)
                #expect(inside.blue > 0.9 && inside.red < 0.1)
            } else if kind == "roughness" {
                try #require(abs(outside.red - 0.8) < 0.02)
                #expect(abs(inside.red - 0.5) < 0.02 && abs(inside.green - inside.red) < 0.02 && abs(inside.blue - inside.red) < 0.02)
            } else {
                try #require(outside.red > 0.95 && outside.green > 0.95 && outside.blue > 0.95)
                func linear(_ value: Float) -> Float { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
                #expect(abs(linear(inside.red) - 0.625) < 0.02 && abs(linear(inside.green) - 0.75) < 0.02 && abs(linear(inside.blue) - 0.875) < 0.02)
                let seam = image.getPixel(x: 127, y: 64)
                #expect(abs(seam.red - inside.red) < 0.02 && abs(seam.green - inside.green) < 0.02 && abs(seam.blue - inside.blue) < 0.02)
            }
        }
    }
#endif
