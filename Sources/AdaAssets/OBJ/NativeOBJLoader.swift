//
//  NativeOBJLoader.swift
//  AdaEngine
//

import Foundation
import Math

public enum OBJLoadingError: Error, Equatable, Sendable {
    case invalidEncoding
    case invalidNumber(line: Int, value: String)
    case invalidVertex(line: Int)
    case invalidTextureCoordinate(line: Int)
    case invalidNormal(line: Int)
    case invalidFace(line: Int)
    case invalidIndex(line: Int, value: String)
}

/// A native Swift loader for Wavefront OBJ geometry.
public struct NativeOBJLoader: OBJLoader {
    public init() {}

    public func load(url: URL) async throws -> OBJImportResult {
        try load(data: Data(contentsOf: url))
    }

    /// Loads an OBJ document from its UTF-8 representation.
    public func load(data: Data) throws -> OBJImportResult {
        guard let source = String(bytes: data, encoding: .utf8) else {
            throw OBJLoadingError.invalidEncoding
        }
        return try parse(source)
    }

    private func parse(_ source: String) throws -> OBJImportResult {
        var state = ParserState()

        for (lineIndex, rawLine) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = lineIndex + 1
            let line = rawLine.prefix { $0 != "#" }
            let fields = line.split(whereSeparator: \Character.isWhitespace)
            guard let keyword = fields.first else {
                continue
            }

            switch keyword {
            case "v":
                guard fields.count >= 4 else {
                    throw OBJLoadingError.invalidVertex(line: lineNumber)
                }
                state.positions.append(
                    Vector3(
                        x: try parseFloat(fields[1], line: lineNumber),
                        y: try parseFloat(fields[2], line: lineNumber),
                        z: try parseFloat(fields[3], line: lineNumber)
                    )
                )
            case "vt":
                guard fields.count >= 2 else {
                    throw OBJLoadingError.invalidTextureCoordinate(line: lineNumber)
                }
                state.textureCoordinates.append(
                    Vector2(
                        x: try parseFloat(fields[1], line: lineNumber),
                        y: fields.count >= 3 ? try parseFloat(fields[2], line: lineNumber) : 0
                    )
                )
            case "vn":
                guard fields.count >= 4 else {
                    throw OBJLoadingError.invalidNormal(line: lineNumber)
                }
                state.normals.append(
                    Vector3(
                        x: try parseFloat(fields[1], line: lineNumber),
                        y: try parseFloat(fields[2], line: lineNumber),
                        z: try parseFloat(fields[3], line: lineNumber)
                    )
                )
            case "f":
                guard fields.count >= 4 else {
                    throw OBJLoadingError.invalidFace(line: lineNumber)
                }
                let vertices = try fields.dropFirst()
                    .map {
                        try parseFaceVertex($0, state: state, line: lineNumber)
                    }
                state.appendFace(vertices)
            case "o",
                "g":
                let name = fields.dropFirst().map(String.init).joined(separator: " ")
                state.selectMesh(named: name.isEmpty ? "Unnamed" : name)
            case "usemtl":
                let name = fields.dropFirst().map(String.init).joined(separator: " ")
                state.selectMaterial(named: name.isEmpty ? nil : name)
            default:
                continue
            }
        }

        return state.makeResult()
    }

    private func parseFloat(_ value: Substring, line: Int) throws -> Float {
        guard let result = Float(value) else {
            throw OBJLoadingError.invalidNumber(line: line, value: String(value))
        }
        return result
    }

    private func parseFaceVertex(_ value: Substring, state: ParserState, line: Int) throws -> FaceVertex {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count), !components[0].isEmpty else {
            throw OBJLoadingError.invalidFace(line: line)
        }

        let position = try resolveIndex(components[0], count: state.positions.count, line: line)
        let textureCoordinate: Int?
        let normal: Int?

        if components.count >= 2, !components[1].isEmpty {
            textureCoordinate = try resolveIndex(components[1], count: state.textureCoordinates.count, line: line)
        } else {
            textureCoordinate = nil
        }

        if components.count == 3, !components[2].isEmpty {
            normal = try resolveIndex(components[2], count: state.normals.count, line: line)
        } else {
            normal = nil
        }

        return FaceVertex(position: position, textureCoordinate: textureCoordinate, normal: normal)
    }

    private func resolveIndex(_ value: Substring, count: Int, line: Int) throws -> Int {
        guard let sourceIndex = Int(value), sourceIndex != 0 else {
            throw OBJLoadingError.invalidIndex(line: line, value: String(value))
        }
        let index = sourceIndex > 0 ? sourceIndex - 1 : count + sourceIndex
        guard (0..<count).contains(index) else {
            throw OBJLoadingError.invalidIndex(line: line, value: String(value))
        }
        return index
    }
}

private struct FaceVertex: Hashable {
    let position: Int
    let textureCoordinate: Int?
    let normal: Int?
}

private struct PrimitiveBuilder {
    let materialIndex: Int
    var positions: [Vector3] = []
    var normals: [Vector3] = []
    var textureCoordinates: [Vector2] = []
    var indices: [UInt32] = []
    var vertexIndices: [FaceVertex: UInt32] = [:]
    var hasNormals = false
    var hasTextureCoordinates = false

    mutating func index(for vertex: FaceVertex, state: ParserState) -> UInt32 {
        if let index = vertexIndices[vertex] {
            return index
        }

        let index = UInt32(positions.count)
        positions.append(state.positions[vertex.position])
        normals.append(vertex.normal.map { state.normals[$0] } ?? Vector3())
        textureCoordinates.append(vertex.textureCoordinate.map { state.textureCoordinates[$0] } ?? Vector2())
        hasNormals = hasNormals || vertex.normal != nil
        hasTextureCoordinates = hasTextureCoordinates || vertex.textureCoordinate != nil
        vertexIndices[vertex] = index
        return index
    }

    func makePrimitive() -> OBJImportResult.Primitive {
        OBJImportResult.Primitive(
            positions: positions,
            normals: hasNormals ? normals : nil,
            textureCoordinates: hasTextureCoordinates ? textureCoordinates : nil,
            indices: indices,
            materialIndex: materialIndex
        )
    }
}

private struct MeshBuilder {
    var name: String
    var primitives: [PrimitiveBuilder] = []

    var isEmpty: Bool {
        primitives.allSatisfy(\.indices.isEmpty)
    }

    mutating func primitiveIndex(for materialIndex: Int) -> Int {
        if let index = primitives.firstIndex(where: { $0.materialIndex == materialIndex }) {
            return index
        }
        primitives.append(PrimitiveBuilder(materialIndex: materialIndex))
        return primitives.count - 1
    }

    func makeMesh() -> OBJImportResult.Mesh {
        OBJImportResult.Mesh(
            name: name,
            primitives: primitives.filter { !$0.indices.isEmpty }.map { $0.makePrimitive() }
        )
    }
}

private struct ParserState {
    var positions: [Vector3] = []
    var normals: [Vector3] = []
    var textureCoordinates: [Vector2] = []
    var materials: [OBJImportResult.Material] = [OBJImportResult.Material(name: nil)]
    var materialIndices: [String: Int] = [:]
    var meshes: [MeshBuilder] = [MeshBuilder(name: "Default")]
    var activeMeshIndex = 0
    var activeMaterialIndex = 0

    mutating func selectMesh(named name: String) {
        if meshes[activeMeshIndex].isEmpty {
            meshes[activeMeshIndex].name = name
            return
        }
        meshes.append(MeshBuilder(name: name))
        activeMeshIndex = meshes.count - 1
    }

    mutating func selectMaterial(named name: String?) {
        guard let name else {
            activeMaterialIndex = 0
            return
        }
        if let index = materialIndices[name] {
            activeMaterialIndex = index
            return
        }
        let index = materials.count
        materials.append(OBJImportResult.Material(name: name))
        materialIndices[name] = index
        activeMaterialIndex = index
    }

    mutating func appendFace(_ vertices: [FaceVertex]) {
        let primitiveIndex = meshes[activeMeshIndex].primitiveIndex(for: activeMaterialIndex)
        var primitive = meshes[activeMeshIndex].primitives[primitiveIndex]
        let first = primitive.index(for: vertices[0], state: self)

        for index in 1..<(vertices.count - 1) {
            primitive.indices.append(first)
            primitive.indices.append(primitive.index(for: vertices[index], state: self))
            primitive.indices.append(primitive.index(for: vertices[index + 1], state: self))
        }
        meshes[activeMeshIndex].primitives[primitiveIndex] = primitive
    }

    func makeResult() -> OBJImportResult {
        OBJImportResult(
            meshes: meshes.filter { !$0.isEmpty }.map { $0.makeMesh() },
            materials: materials
        )
    }
}
