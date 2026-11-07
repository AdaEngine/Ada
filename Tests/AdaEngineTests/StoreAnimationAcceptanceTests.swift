#if os(macOS)
import AdaAnimation
import AdaAssets
import AdaEngine
import Foundation
import Testing

extension Render3DGPUTests {
    /// Opt-in acceptance of external Store packages. No downloaded assets enter the repository.
    @Suite("Store animation packages", .serialized)
    @MainActor
    struct StoreAnimations {
        private struct Input: Decodable {
            let id: String
            let pack: String
            let path: String
            let source: String
            let expectedClips: [String]
        }

        @Test(.enabled(if: GoldenFrame.isEnabled && ProcessInfo.processInfo.environment["ADA_STORE_ANIMATION_INPUT"] != nil))
        func importsSamplesAndRendersPackages() async throws {
            let inputPath = try #require(ProcessInfo.processInfo.environment["ADA_STORE_ANIMATION_INPUT"])
            let outputPath = try #require(ProcessInfo.processInfo.environment["ADA_STORE_ANIMATION_OUTPUT"])
            let inputs = try JSONDecoder().decode([Input].self, from: Data(contentsOf: URL(fileURLWithPath: inputPath)))
            try #require(!inputs.isEmpty)
            let output = URL(fileURLWithPath: outputPath, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            for entity in scene.sphereEntities { scene.app.main.removeEntity(entity) }
            scene.camera.components[Transform.self] = Transform(position: [0, 1.1, -4])
            GLTFLoaderResolver.shared.setLoader(NativeGLTFLoader())
            var results: [[String: Any]] = []
            for input in inputs {
                do {
                    // Large KayKit death/transform clips travel toward the camera; keep their whole silhouette in view.
                    let largeRig = input.source.contains("Rig_Large") || input.source.contains("Mannequin_Large")
                    scene.camera.components[Transform.self] = Transform(position: largeRig ? [0, 1.5, -7] : [0, 1.1, -4])
                    let model = try #require(AssetsManager.loadSync(ModelAsset3D.self, at: input.path).asset)
                    #expect(model.animationClips.map(\.name) == input.expectedClips, "Clip inventory: \(input.id)")
                    let rig = try #require(model.animationRig)
                    var player = try SkeletalAnimationPlayer(rig: rig, clips: model.animationClips)
                    var clipResults: [[String: Any]] = []
                    var selected: (name: String, duration: Double, change: Float)?
                    for clip in model.animationClips {
                        try player.play(clip.name, transitionDuration: 0)
                        player.repeats = false
                        player.seek(to: clip.duration * 0.2)
                        let before = player.globalTransforms
                        player.advance(by: clip.duration * 0.45)
                        var change: Float = 0
                        for (left, right) in zip(before, player.globalTransforms) {
                            for column in 0..<4 {
                                for row in 0..<4 { change += abs(left[column, row] - right[column, row]) }
                            }
                        }
                        for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
                            player.seek(to: clip.duration * fraction)
                            #expect(player.globalTransforms.allSatisfy(Self.isFinite), "Nonfinite pose in \(input.id): \(clip.name)")
                        }
                        #expect(clip.duration.isFinite && clip.duration >= 0)
                        clipResults.append(["name": clip.name, "duration": clip.duration, "poseChange": change])
                        if change > (selected?.change ?? 0) { selected = (clip.name, clip.duration, change) }
                    }
                    let blank = try await scene.render(.none)
                    let root = model.instantiate(in: scene.app.main)
                    let entities = Self.descendants(root)
                    var renderedFrames: [String] = []
                    var images: [Image] = []
                    for (index, fraction) in [0.2, 0.65].enumerated() {
                        if let selected {
                            var animation = try #require(root.components[ModelAnimation3DComponent.self])
                            try animation.player.play(selected.name, transitionDuration: 0)
                            animation.player.repeats = false
                            animation.player.seek(to: selected.duration * fraction)
                            animation.player.isPlaying = false
                            root.components[ModelAnimation3DComponent.self] = animation
                        }
                        let frame = try await scene.render(.none)
                        let name = "\(input.id)-\(index).png"
                        try frame.writePNG(to: output.appendingPathComponent(name))
                        renderedFrames.append(name)
                        images.append(frame)
                        #expect(GoldenFrame.compare(frame, blank, tolerance: .metal).differingPixels > 100, "Model must be visible: \(input.id)")
                        for entity in entities {
                            if let skin = entity.components[SkinnedMesh3DComponent.self] {
                                #expect(skin.matrices.allSatisfy(Self.isFinite), "Nonfinite skin palette: \(input.id)")
                            }
                        }
                    }
                    let changedPixels = GoldenFrame.compare(images[0], images[1], tolerance: .metal).differingPixels
                    if selected != nil { #expect(changedPixels > 20, "Animation must change rendered pixels: \(input.id)") }
                    results.append(["id": input.id, "pack": input.pack, "source": input.source,
                                    "import": "passed", "warnings": model.importWarnings,
                                    "jointCounts": model.skins.map { $0.joints.count }, "clips": clipResults,
                                    "renderedClip": selected?.name ?? "rest pose", "frames": renderedFrames,
                                    "changedPixels": changedPixels])
                    for entity in entities.reversed() { scene.app.main.removeEntity(entity) }
                    print("STORE_ACCEPTANCE \(input.id): \(clipResults.count) clips; GPU delta \(changedPixels)")
                } catch {
                    results.append(["id": input.id, "pack": input.pack, "error": String(describing: error)])
                    Issue.record("\(input.id): \(error)")
                }
                let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: output.appendingPathComponent("runtime-report.json"), options: .atomic)
            }
            #expect(results.count == inputs.count)
        }

        private static func descendants(_ root: Entity) -> [Entity] {
            var result = [root]
            var index = 0
            while index < result.count {
                result.append(contentsOf: result[index].children)
                index += 1
            }
            return result
        }

        private static func isFinite(_ matrix: Transform3D) -> Bool {
            (0..<4).allSatisfy { column in (0..<4).allSatisfy { row in matrix[column, row].isFinite } }
        }
    }
}
#endif
