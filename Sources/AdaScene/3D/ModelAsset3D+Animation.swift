import AdaAnimation
import AdaAssets

extension ModelAsset3D {
    static func makeRig(nodes: [GLTFImportResult.Node], meshes: [GLTFImportResult.Mesh] = []) throws -> SkeletalRig {
        try GLTFAnimationAdapter.makeRig(nodes: nodes, meshes: meshes)
    }

    static func makeClips(_ clips: [GLTFImportResult.Animation], nodes: [GLTFImportResult.Node] = [],
                          meshes: [GLTFImportResult.Mesh] = []) throws -> [SkeletalAnimationClip] {
        try GLTFAnimationAdapter.makeClips(clips, nodes: nodes, meshes: meshes)
    }
}
