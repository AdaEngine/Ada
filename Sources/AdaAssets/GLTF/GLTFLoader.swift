//
//  GLTFLoader.swift
//  AdaEngine
//
//  Created by v.prusakov on 04/21/26.
//

import Foundation
import Math

/// A protocol that defines the interface for loading glTF assets.
public protocol GLTFLoader: Sendable {
    func load(url: URL) async throws -> GLTFImportResult
}

/// The result of importing a glTF file.
public struct GLTFImportResult: Sendable {
    public struct Node: Sendable {
        public let name: String?
        public let transform: Transform3D
        public let children: [Int]
        public let meshIndex: Int?
        /// Index into the imported skins array.
        public let skinIndex: Int?
        /// Authored local TRS; nil for nodes authored with a matrix.
        public let restPose: NodeTRS?
        /// Morph target weights of this node's mesh instance; they replace the mesh's default weights.
        public let weights: [Float]?

        public init(
            name: String?,
            transform: Transform3D,
            children: [Int],
            meshIndex: Int?,
            skinIndex: Int? = nil,
            restPose: NodeTRS? = nil,
            weights: [Float]? = nil
        ) {
            self.weights = weights
            self.name = name
            self.transform = transform
            self.children = children
            self.meshIndex = meshIndex
            self.skinIndex = skinIndex
            self.restPose = restPose
        }
    }

    /// Per-vertex displacement of one morph target of a primitive. A target that leaves an attribute alone has an empty
    /// array for it; otherwise each array has one entry per vertex. Tangent deltas are directions only (xyz).
    public struct MorphTarget: Sendable, Equatable {
        public let positionDeltas: [Vector3]
        public let normalDeltas: [Vector3]
        public let tangentDeltas: [Vector3]

        public init(positionDeltas: [Vector3] = [], normalDeltas: [Vector3] = [], tangentDeltas: [Vector3] = []) {
            self.positionDeltas = positionDeltas
            self.normalDeltas = normalDeltas
            self.tangentDeltas = tangentDeltas
        }
    }

    public struct Mesh: Sendable {
        public let name: String?
        public let primitives: [Primitive]
        /// Default morph target weights, one per target; empty when the mesh has no morph targets.
        public let defaultWeights: [Float]
        /// Morph target names (from `extras.targetNames`); empty or one per target.
        public let targetNames: [String]

        /// Number of morph targets every primitive of this mesh has.
        public var morphTargetCount: Int { primitives.first?.morphTargets.count ?? 0 }

        public init(name: String?, primitives: [Primitive], defaultWeights: [Float] = [], targetNames: [String] = []) {
            self.name = name
            self.primitives = primitives
            self.defaultWeights = defaultWeights
            self.targetNames = targetNames
        }
    }

    public struct Primitive: Sendable {
        public let attributes: [Attribute: Accessor]
        public let indices: [UInt32]?
        public let materialIndex: Int?
        public let mode: PrimitiveMode
        public let skinning: Skinning?
        /// Morph targets of this primitive, in target order.
        public let morphTargets: [MorphTarget]

        public init(
            attributes: [Attribute: Accessor],
            indices: [UInt32]?,
            materialIndex: Int?,
            mode: PrimitiveMode,
            skinning: Skinning? = nil,
            morphTargets: [MorphTarget] = []
        ) {
            self.morphTargets = morphTargets
            self.attributes = attributes
            self.indices = indices
            self.materialIndex = materialIndex
            self.mode = mode
            self.skinning = skinning
        }
    }

    /// A decoded, tightly-packed accessor.
    public struct Accessor: Sendable {
        public let values: [Float]
        public let componentCount: Int

        public var count: Int {
            componentCount > 0 ? values.count / componentCount : 0
        }

        public init(values: [Float], componentCount: Int) {
            self.values = values
            self.componentCount = componentCount
        }

        public func vector2Values() -> [Vector2] {
            guard componentCount == 2, values.count.isMultiple(of: 2) else {
                return []
            }
            return stride(from: 0, to: values.count, by: 2)
                .map {
                    Vector2(x: values[$0], y: values[$0 + 1])
                }
        }

        public func vector3Values() -> [Vector3] {
            guard componentCount == 3, values.count.isMultiple(of: 3) else {
                return []
            }
            return stride(from: 0, to: values.count, by: 3)
                .map {
                    Vector3(x: values[$0], y: values[$0 + 1], z: values[$0 + 2])
                }
        }

        public func vector4Values() -> [Vector4] {
            guard componentCount == 4, values.count.isMultiple(of: 4) else {
                return []
            }
            return stride(from: 0, to: values.count, by: 4)
                .map {
                    Vector4(x: values[$0], y: values[$0 + 1], z: values[$0 + 2], w: values[$0 + 3])
                }
        }
    }

    public enum Attribute: Hashable, Sendable {
        case position
        case normal
        case tangent
        case texCoord(Int)
        case color(Int)
        case joints(Int)
        case weights(Int)
        case custom(String)
    }

    public enum PrimitiveMode: Int, Sendable {
        case points = 0
        case lines = 1
        case lineLoop = 2
        case lineStrip = 3
        case triangles = 4
        case triangleStrip = 5
        case triangleFan = 6
    }

    public struct Texture: Sendable {
        public let source: Int
        public let sampler: Int?

        public init(source: Int, sampler: Int?) {
            self.source = source
            self.sampler = sampler
        }
    }

    public struct Image: Sendable {
        public let uri: URL?
        public let data: Data?
        public let mimeType: String?

        public init(uri: URL?, data: Data?, mimeType: String?) {
            self.uri = uri
            self.data = data
            self.mimeType = mimeType
        }
    }

    public let nodes: [Node]
    public let meshes: [Mesh]
    public let materials: [Material]
    public let textures: [Texture]
    public let samplers: [Sampler]
    public let images: [Image]
    public let scenes: [[Int]]
    public let defaultScene: Int?
    public let skins: [Skin]
    public let animations: [Animation]
    /// Content the importer read but could not honor, such as an optional extension it does not implement.
    public let warnings: [String]
    /// Accounting for a bounded native import; absent for unconstrained/custom results.
    @_spi(Internal) public var importFootprint: ModelImportFootprint?

    public init(
        nodes: [Node],
        meshes: [Mesh],
        materials: [Material],
        textures: [Texture],
        images: [Image],
        scenes: [[Int]],
        defaultScene: Int?,
        skins: [Skin] = [],
        animations: [Animation] = [],
        samplers: [Sampler] = [],
        warnings: [String] = []
    ) {
        self.nodes = nodes
        self.meshes = meshes
        self.materials = materials
        self.textures = textures
        self.images = images
        self.scenes = scenes
        self.defaultScene = defaultScene
        self.skins = skins
        self.animations = animations
        self.samplers = samplers
        self.warnings = warnings
    }
}

/// Supplies the native glTF loader before rendering plugins start, with support for custom loaders.
/// Loader selection is synchronized; a returned loader remains valid while a new one is installed.
public final class GLTFLoaderResolver: @unchecked Sendable {
    public static let shared = GLTFLoaderResolver()

    // The lock protects loader selection. Loading runs outside it through a Sendable snapshot.
    private let lock = NSLock()
    private var loader: any GLTFLoader = NativeGLTFLoader()

    public func setLoader(_ loader: any GLTFLoader) {
        lock.withLock { self.loader = loader }
    }

    public func getLoader() -> any GLTFLoader {
        lock.withLock { loader }
    }
}
