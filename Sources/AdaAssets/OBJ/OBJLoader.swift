//
//  OBJLoader.swift
//  AdaEngine
//

import Foundation
import Math

/// A protocol that defines the interface for loading Wavefront OBJ assets.
public protocol OBJLoader: Sendable {
    func load(url: URL) async throws -> OBJImportResult
}

/// The result of importing a Wavefront OBJ file.
public struct OBJImportResult: Sendable {
    public struct Material: Sendable {
        public let name: String?

        public init(name: String?) {
            self.name = name
        }
    }

    public struct Mesh: Sendable {
        public let name: String
        public let primitives: [Primitive]

        public init(name: String, primitives: [Primitive]) {
            self.name = name
            self.primitives = primitives
        }
    }

    public struct Primitive: Sendable {
        public let positions: [Vector3]
        public let normals: [Vector3]?
        public let textureCoordinates: [Vector2]?
        public let indices: [UInt32]
        public let materialIndex: Int

        public init(
            positions: [Vector3],
            normals: [Vector3]?,
            textureCoordinates: [Vector2]?,
            indices: [UInt32],
            materialIndex: Int
        ) {
            self.positions = positions
            self.normals = normals
            self.textureCoordinates = textureCoordinates
            self.indices = indices
            self.materialIndex = materialIndex
        }
    }

    public let meshes: [Mesh]
    public let materials: [Material]

    public init(meshes: [Mesh], materials: [Material]) {
        self.meshes = meshes
        self.materials = materials
    }
}

/// A resolver for the active OBJ loader.
public final class OBJLoaderResolver: @unchecked Sendable {
    public static let shared = OBJLoaderResolver()

    private var loader: (any OBJLoader)?

    private init() {}

    public func setLoader(_ loader: any OBJLoader) {
        self.loader = loader
    }

    public func getLoader() -> any OBJLoader {
        guard let loader else {
            fatalError("OBJLoader is not set. Please set a loader using OBJLoaderResolver.shared.setLoader(_:)")
        }
        return loader
    }
}
