#if os(macOS) || os(Windows) || os(Linux)
@_spi(Internal) @testable import AdaApp
import AdaAssets
import AdaECS
@_spi(Internal) @testable import AdaRender
import AdaScene
import AdaTransform
import AdaUtils
import Foundation
import Math
import Testing

@testable import AdaCorePipelines

enum SponzaBenchmarkData {
    struct Pose: Codable {
        var sourceCamera: String
        var position: [Float]
        var rotation: [Float]
    }

    struct Route: Codable {
        var id: String
        var start: Pose
        var end: Pose

        func transform(sample: Int, count: Int) -> Transform {
            let t = Float(sample) / Float(count - 1)
            let a = start.rotation, b = end.rotation
            let sign: Float = zip(a, b).reduce(Float.zero) { $0 + $1.0 * $1.1 } < 0 ? -1 : 1
            let q = Quat(x: a[0] * (1 - t) + b[0] * t * sign, y: a[1] * (1 - t) + b[1] * t * sign,
                z: a[2] * (1 - t) + b[2] * t * sign, w: a[3] * (1 - t) + b[3] * t * sign).normalized
            let p = zip(start.position, end.position).map { pair in pair.0 * (1 - t) + pair.1 * t }
            return Transform(rotation: q, position: [p[0], p[1], p[2]])
        }
    }

    struct Routes: Codable {
        var schema: Int
        var samples: Int
        var fieldOfViewDegrees: Float
        var near: Float
        var far: Float
        var interpolation: String
        var rotationConvention: String
        var routes: [Route]

        static func load(_ path: String) throws -> Self {
            let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            try #require(value.schema == 1 && value.samples == 600 && value.interpolation == "linear-position-shortest-nlerp-v1")
            try #require(value.fieldOfViewDegrees > 1 && value.fieldOfViewDegrees < 170 && value.near > 0 && value.far > value.near)
            try #require(Set(value.routes.map(\.id)).count == value.routes.count && !value.routes.isEmpty)
            for pose in value.routes.flatMap({ [$0.start, $0.end] }) {
                try #require(pose.position.count == 3 && pose.rotation.count == 4)
                let finite = (pose.position + pose.rotation).allSatisfy { $0.isFinite }
                try #require(finite)
                let length = pose.rotation.reduce(Float.zero) { $0 + $1 * $1 }
                try #require(abs(length - 1) < 0.001)
            }
            return value
        }
    }

    struct Archive: Codable {
        var id: String
        var sha256: String?
        var geometrySHA256: String
        var geometryProfileExcludedTriangles: Int
    }

    struct Receipt: Codable {
        var schema: Int
        var status: String
        var profiles: [String]
        var dataset: String
        var profileGenerator: Int
        var archives: [Archive]
    }

    @MainActor
    static func scene(preset: String, quality: String, root: URL, size: SizeInt, routes: Routes) async throws -> MeshletBaselineFixtures.Scene {
        let scene = try await MeshletBaselineFixtures.empty(size: size, shadows: quality == "pbr")
        // Fixed exposure makes the unlit interior readable without changing authored materials.
        var settings = try #require(scene.camera.components[Environment3D.self])
        settings.exposureEV = quality == "pbr" ? 3 : 0
        scene.camera.components[Environment3D.self] = settings
        var camera = try #require(scene.camera.components[Camera.self])
        camera.projection = .perspective(PerspectiveProjection(near: routes.near, far: routes.far, fieldOfView: .degrees(routes.fieldOfViewDegrees)))
        scene.camera.components[Camera.self] = camera
        let environment = scene.app.main.spawn("Environment") { Transform() }
        let entries = preset == "sponza-ivy" ? ["base", "ivy"] : ["base"]
        for entry in entries {
            let folder = entry == "base" ? "main_sponza" : "pkg_b_ivy"
            let filename = quality == "geometry" ? "benchmark-opaque.gltf" : "benchmark-pbr.gltf"
            let path = root.appendingPathComponent(folder).appendingPathComponent(filename)
            print("SPONZA importing \(path.lastPathComponent) (\(entry), \(quality))")
            let model = try #require(try await AssetsManager.load(ModelAsset3D.self, at: path.path).asset)
            try #require(model.skins.isEmpty && model.animationClips.isEmpty)
            let expected = entry == "ivy" ? 5_065_558 : quality == "geometry" ? 3_738_878 : 3_747_018
            let triangles = model.meshes.flatMap(\.models).flatMap(\.parts).reduce(0) { $0 + $1.indexCount / 3 }
            try #require(triangles == expected, "Production importer must retain the selected dataset's geometry")
            try #require(model.meshes.flatMap(\.models).flatMap(\.parts).allSatisfy { $0.primitiveTopology == .triangleList })
            try #require(model.importWarnings.allSatisfy { $0 == "The extension KHR_lights_punctual is not supported and was ignored." })
            let instance = model.instantiate(in: scene.app.main)
            environment.addChild(instance)
        }
        return scene
    }
}
#endif
