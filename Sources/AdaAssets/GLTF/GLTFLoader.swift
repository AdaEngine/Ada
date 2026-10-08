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

        public init(name: String?, transform: Transform3D, children: [Int], meshIndex: Int?, skinIndex: Int? = nil, restPose: NodeTRS? = nil) {
            self.name = name
            self.transform = transform
            self.children = children
            self.meshIndex = meshIndex
            self.skinIndex = skinIndex
            self.restPose = restPose
        }
    }

    public struct Mesh: Sendable {
        public let name: String?
        public let primitives: [Primitive]

        public init(name: String?, primitives: [Primitive]) {
            self.name = name
            self.primitives = primitives
        }
    }

    public struct Primitive: Sendable {
        public let attributes: [Attribute: Accessor]
        public let indices: [UInt32]?
        public let materialIndex: Int?
        public let mode: PrimitiveMode
        public let skinning: Skinning?

        public init(attributes: [Attribute: Accessor], indices: [UInt32]?, materialIndex: Int?, mode: PrimitiveMode, skinning: Skinning? = nil) {
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
        samplers: [Sampler] = []
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
    }
}

/// A resolver for the GLTFLoader.
public final class GLTFLoaderResolver: @unchecked Sendable {
    public static let shared = GLTFLoaderResolver()

    private var loader: (any GLTFLoader)?

    public func setLoader(_ loader: any GLTFLoader) {
        self.loader = loader
    }

    public func getLoader() -> any GLTFLoader {
        guard let loader else {
            fatalError("GLTFLoader is not set. Please set a loader using GLTFLoaderResolver.shared.setLoader(_:)")
        }
        return loader
    }
}
