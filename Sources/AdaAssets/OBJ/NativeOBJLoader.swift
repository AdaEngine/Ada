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
        if let limits = ModelImportContext.limits {
            guard limits.maximumEncodedBytes > 0, limits.maximumDecodedBytes > 0 else { throw ModelImportLimitError.invalidLimits }
            #if WASM
                throw AssetError.message("Bounded direct model URL reads are unavailable in the browser; provide root data")
            #else
                return try load(data: await AssetsManager.readBoundedFile(url: url, maximumBytes: limits.maximumEncodedBytes))
            #endif
        }
        return try load(data: Data(contentsOf: url))
    }

    /// Loads an OBJ document from its UTF-8 representation.
    public func load(data: Data) throws -> OBJImportResult {
        var budget = try OBJImportBudget(data: data)
        guard let source = String(bytes: data, encoding: .utf8) else {
            throw OBJLoadingError.invalidEncoding
        }
        return try parse(source, budget: &budget)
    }

    private func parse(_ source: String, budget: inout OBJImportBudget) throws -> OBJImportResult {
        var state = ParserState()

        for (lineIndex, rawLine) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = lineIndex + 1
            let line = rawLine.prefix { $0 != "#" }
            let fields = line.split(maxSplits: budget.maximumFields + 1, whereSeparator: \Character.isWhitespace)
            try budget.fields(fields.count, line: lineNumber)
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
        guard let result = Float(value), result.isFinite else {
            throw OBJLoadingError.invalidNumber(line: line, value: String(value))
        }
        return result
    }

    private func parseFaceVertex(_ value: Substring, state: ParserState, line: Int) throws -> FaceVertex {
        let components = value.split(separator: "/", maxSplits: 3, omittingEmptySubsequences: false)
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

private struct OBJVertexSource {
    let positions: [Vector3]
    let normals: [Vector3]
    let textureCoordinates: [Vector2]
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

    // Numeric identity is compared only across one synchronous append, never dereferenced.
    var indexStorage: UInt {
        unsafe indices.withUnsafeBufferPointer { buffer in
            unsafe UInt(bitPattern: buffer.baseAddress)
        }
    }

    mutating func index(for vertex: FaceVertex, source: OBJVertexSource) -> UInt32 {
        if let index = vertexIndices[vertex] {
            return index
        }

        let index = UInt32(positions.count)
        positions.append(source.positions[vertex.position])
        normals.append(vertex.normal.map { source.normals[$0] } ?? Vector3())
        textureCoordinates.append(vertex.textureCoordinate.map { source.textureCoordinates[$0] } ?? Vector2())
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

private final class OBJLookupMetrics {
    private(set) var comparisons: UInt64 = 0

    func compare() {
        if comparisons < .max { comparisons += 1 }
    }
}

private struct OBJMaterialKey: Hashable {
    let id: Int
    let metrics: OBJLookupMetrics

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.metrics.compare()
        return lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

private struct MeshBuilder {
    var name: String
    var primitives: [PrimitiveBuilder] = []
    let lookupMetrics = OBJLookupMetrics()
    var primitiveIndices: [OBJMaterialKey: Int] = [:]

    var isEmpty: Bool {
        primitives.allSatisfy(\.indices.isEmpty)
    }

    mutating func primitiveIndex(for materialIndex: Int) -> Int {
        let key = OBJMaterialKey(id: materialIndex, metrics: lookupMetrics)
        let proposed = primitives.count
        let slot = Self.resolve(&primitiveIndices[key, default: -1], proposed: proposed)
        if slot.inserted { primitives.append(PrimitiveBuilder(materialIndex: materialIndex)) }
        return slot.index
    }

    private static func resolve(_ value: inout Int, proposed: Int) -> (index: Int, inserted: Bool) {
        guard value < 0 else {
            return (value, false)
        }
        value = proposed
        return (proposed, true)
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
    var faceCount = 0
    var copiedIndexBytes: UInt64 = 0

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
        let previousStorage = meshes[activeMeshIndex].primitives[primitiveIndex].indexStorage
        let previousCount = meshes[activeMeshIndex].primitives[primitiveIndex].indices.count
        // Pass only immutable input streams, never a ParserState retaining the destination.
        let source = OBJVertexSource(positions: positions, normals: normals, textureCoordinates: textureCoordinates)
        let first = meshes[activeMeshIndex].primitives[primitiveIndex].index(for: vertices[0], source: source)
        for index in 1..<(vertices.count - 1) {
            let second = meshes[activeMeshIndex].primitives[primitiveIndex].index(for: vertices[index], source: source)
            let third = meshes[activeMeshIndex].primitives[primitiveIndex].index(for: vertices[index + 1], source: source)
            meshes[activeMeshIndex].primitives[primitiveIndex].indices.append(first)
            meshes[activeMeshIndex].primitives[primitiveIndex].indices.append(second)
            meshes[activeMeshIndex].primitives[primitiveIndex].indices.append(third)
        }
        if previousCount > 0, previousStorage != meshes[activeMeshIndex].primitives[primitiveIndex].indexStorage {
            let bytes = UInt64(previousCount).multipliedReportingOverflow(by: UInt64(MemoryLayout<UInt32>.stride))
            let total = copiedIndexBytes.addingReportingOverflow(bytes.partialValue)
            copiedIndexBytes = bytes.overflow || total.overflow ? .max : total.partialValue
        }
        faceCount += 1
    }

    func makeResult() -> OBJImportResult {
        var result = OBJImportResult(
            meshes: meshes.filter { !$0.isEmpty }.map { $0.makeMesh() },
            materials: materials
        )
        let comparisons = meshes.reduce(UInt64(0)) { total, mesh in
            let sum = total.addingReportingOverflow(mesh.lookupMetrics.comparisons)
            return sum.overflow ? .max : sum.partialValue
        }
        result.importDiagnostics = .init(faces: faceCount, copiedIndexBytes: copiedIndexBytes, materialComparisons: comparisons)
        return result
    }
}
