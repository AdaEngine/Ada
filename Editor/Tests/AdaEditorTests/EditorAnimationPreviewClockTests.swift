@_spi(AdaEngine) import AdaEngine
import Foundation
import Testing

@testable import AdaEditor

extension EditorAnimationAuthoringTests {
    @Test func previewSeekWaitsForTheCenterViewportPlayer() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tests/AdaEngineTests/Fixtures/SkeletalGardenAssets/GardenRobot.glb")
        let asset = try #require(AssetsManager.loadSync(ModelAsset3D.self, at: source.path).asset)
        let preview = EditorModelAssetPreviewModel()
        preview.asset = asset
        preview.playsAnimation = false
        preview.selectedAnimation = "Walk"
        // API preview can arrive while the GPU viewport is still being mounted.
        preview.seekGraph(to: 0.25)
        let world = World(name: "Center animation viewport")
        _ = asset.instantiate(in: world)
        preview.bind(to: world)
        let player = try #require(preview.capturedAnimationPlayer())
        #expect(abs(player.time - 0.25) < 0.000001)
        #expect(!player.isPlaying)
    }
}
