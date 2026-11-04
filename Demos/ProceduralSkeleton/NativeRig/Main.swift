import AdaAssets
import Foundation

@main
struct AuthorSkeleton {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard (3...4).contains(arguments.count) else { throw RigAuthorError.invalidSource("Usage: SkeletonRig input.glb output.glb [capture-poses.glb]") }
        let input = URL(fileURLWithPath: arguments[1])
        let output = URL(fileURLWithPath: arguments[2])
        let source = try NativeGLTFLoader().load(data: Data(contentsOf: input))
        guard source.skins.isEmpty, source.animations.isEmpty, source.textures.isEmpty else {
            throw RigAuthorError.invalidSource("This author is specialized for the static procedural skeleton")
        }
        let meshes = try MeshSkinning.make(source)
        let materials = source.materials.enumerated().map { index, material in
            let color = material.baseColorFactor
            let glow = material.emissiveFactor
            return ProceduralMaterial(name: material.name ?? "Material \(index)", baseColor: [color.x, color.y, color.z, color.w],
                                      metallic: material.metallicFactor, roughness: material.roughnessFactor, emissive: [glow.x, glow.y, glow.z])
        }
        let model = ProceduralModel(materials: materials, nodes: SkeletonRig.nodes + meshes,
                                    skins: [SkeletonRig.skin], animations: [WalkClip.bindPose(), WalkClip.make()])
        let data = try GLBWriter().encode(model)
        // Round-trip through the same native importer used by the real engine.
        let imported = try NativeGLTFLoader().load(data: data)
        guard imported.skins.count == 1, imported.skins[0].joints.count == Joint.allCases.count,
            imported.animations.contains(where: { $0.name == "Walk" && abs($0.duration - WalkClip.duration) < 0.0001 }),
            imported.meshes.allSatisfy({ $0.primitives.allSatisfy { $0.skinning != nil } })
        else { throw RigAuthorError.invalidSource("Rig round-trip failed") }
        try data.write(to: output, options: .atomic)
        if arguments.count == 4 {
            var poses = model
            poses.animations = WalkClip.capturePoses()
            try GLBWriter().encode(poses).write(to: URL(fileURLWithPath: arguments[3]), options: .atomic)
        }
        let report: [String: Any] = ["source": input.path, "output": output.path, "bytes": data.count,
                                     "joints": Joint.allCases.map { ["name": $0.name, "node": $0.node, "paletteIndex": $0.rawValue] },
                                     "meshes": meshes.count, "clips": imported.animations.map { ["name": $0.name ?? "", "duration": $0.duration] },
                                     "skinning": "JOINTS_0 uint16 + WEIGHTS_0 float32, four slots; rigid bones and blended clothing",
                                     "author": "Native Swift using AdaAssets NativeGLTFLoader and GLBWriter"]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: json, as: UTF8.self))
    }
}
