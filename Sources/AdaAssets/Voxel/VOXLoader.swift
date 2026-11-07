//
//  VOXLoader.swift
//  AdaEngine
//

import Foundation

public enum VOXLoadingError: Error, Equatable, Sendable {
    case invalidHeader
    case unsupportedVersion(Int)
    case missingMainChunk
    case truncated
    case invalidChunk(String)
    case invalidModel(index: Int)
    case invalidRotation(UInt8)
    case invalidAttribute(key: String, value: String)
}

/// A native Swift loader for MagicaVoxel `.vox` files.
///
/// The result stays in MagicaVoxel space (right-handed, Z up); conversion to engine conventions
/// belongs to the scene import layer.
public struct VOXLoader: Sendable {
    public init() {}

    public func load(url: URL) async throws -> VOXFile {
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

    public func load(data: Data) throws -> VOXFile {
        let budget = try VOXDecodeBudget.make(rootBytes: data.count, limits: ModelImportContext.limits)
        var reader = VOXReader(data: data, budget: budget)

        guard try reader.readTag() == "VOX " else {
            throw VOXLoadingError.invalidHeader
        }
        let version = Int(try reader.readInt32())
        guard version >= 150 else {
            throw VOXLoadingError.unsupportedVersion(version)
        }

        guard !reader.isAtEnd, try reader.readTag() == "MAIN" else {
            throw VOXLoadingError.missingMainChunk
        }
        let mainContentSize = try reader.readSize()
        let mainChildrenSize = try reader.readSize()
        try reader.skip(mainContentSize)
        let mainEnd = try reader.offset(advancedBy: mainChildrenSize)

        var state = ParserState()
        while reader.position < mainEnd {
            try parseChunk(reader: &reader, state: &state)
        }

        guard state.pendingSize == nil else {
            throw VOXLoadingError.invalidModel(index: state.models.count)
        }

        return VOXFile(
            version: version,
            models: state.models,
            palette: state.palette ?? .fallback,
            hasCustomPalette: state.palette != nil,
            materials: state.materials,
            layers: state.layers,
            nodes: state.nodes
        )
    }

    // MARK: - Chunks

    private struct ParserState {
        var models: [VOXModel] = []
        var pendingSize: (x: Int, y: Int, z: Int)?
        var palette: VOXPalette?
        var materials: [VOXMaterial] = []
        var layers: [VOXLayer] = []
        var nodes: [Int: VOXNode] = [:]
    }

    private func parseChunk(reader: inout VOXReader, state: inout ParserState) throws {
        let id = try reader.readTag()
        let contentSize = try reader.readSize()
        let childrenSize = try reader.readSize()
        var content = try reader.subReader(length: contentSize)
        try reader.skip(contentSize)
        try reader.skip(childrenSize)

        switch id {
        case "SIZE":
            guard state.pendingSize == nil else {
                throw VOXLoadingError.invalidModel(index: state.models.count)
            }
            state.pendingSize = (
                x: Int(try content.readInt32()),
                y: Int(try content.readInt32()),
                z: Int(try content.readInt32())
            )
        case "XYZI":
            try parseVoxels(content: &content, state: &state)
        case "RGBA":
            state.palette = try parsePalette(content: &content)
        case "MATL":
            state.materials.append(try parseMaterial(content: &content))
        case "LAYR":
            state.layers.append(try parseLayer(content: &content))
        case "nTRN":
            let node = try parseTransformNode(content: &content)
            state.nodes[node.id] = .transform(node)
        case "nGRP":
            let node = try parseGroupNode(content: &content)
            state.nodes[node.id] = .group(node)
        case "nSHP":
            let node = try parseShapeNode(content: &content)
            state.nodes[node.id] = .shape(node)
        default:
            break
        }
    }

    private func parseVoxels(content: inout VOXReader, state: inout ParserState) throws {
        let index = state.models.count
        guard let size = state.pendingSize, size.x > 0, size.y > 0, size.z > 0 else {
            throw VOXLoadingError.invalidModel(index: index)
        }
        state.pendingSize = nil

        let count = try content.readSize()
        guard count <= content.remaining / 4 else {
            throw VOXLoadingError.truncated
        }

        try content.records(VOXModel.self, count: 1)
        try content.records(VOXVoxel.self, count: count)
        var voxels: [VOXVoxel] = []
        voxels.reserveCapacity(count)
        for _ in 0..<count {
            let voxel = VOXVoxel(
                x: try content.readUInt8(),
                y: try content.readUInt8(),
                z: try content.readUInt8(),
                colorIndex: try content.readUInt8()
            )
            guard Int(voxel.x) < size.x, Int(voxel.y) < size.y, Int(voxel.z) < size.z, voxel.colorIndex != 0 else {
                throw VOXLoadingError.invalidModel(index: index)
            }
            voxels.append(voxel)
        }
        state.models.append(VOXModel(sizeX: size.x, sizeY: size.y, sizeZ: size.z, voxels: voxels))
    }

    private func parsePalette(content: inout VOXReader) throws -> VOXPalette {
        var colors: [VOXColor] = []
        colors.reserveCapacity(VOXPalette.count)
        for _ in 0..<VOXPalette.count {
            colors.append(
                VOXColor(
                    red: try content.readUInt8(),
                    green: try content.readUInt8(),
                    blue: try content.readUInt8(),
                    alpha: try content.readUInt8()
                )
            )
        }
        return VOXPalette(colors: colors)
    }

    private func parseMaterial(content: inout VOXReader) throws -> VOXMaterial {
        let id = Int(try content.readInt32())
        return VOXMaterial(paletteIndex: id, properties: try content.readDictionary())
    }

    private func parseLayer(content: inout VOXReader) throws -> VOXLayer {
        let id = Int(try content.readInt32())
        let attributes = try content.readDictionary()
        return VOXLayer(id: id, name: attributes["_name"], isHidden: attributes["_hidden"] == "1")
    }

    // MARK: - Scene graph

    private func parseTransformNode(content: inout VOXReader) throws -> VOXTransformNode {
        let id = Int(try content.readInt32())
        let attributes = try content.readDictionary()
        let childID = Int(try content.readInt32())
        _ = try content.readInt32()
        let layerID = Int(try content.readInt32())
        let frameCount = try content.readSize()
        guard frameCount >= 1, frameCount <= content.remaining / 4 else {
            throw VOXLoadingError.invalidChunk("nTRN")
        }

        try content.records(VOXTransformFrame.self, count: frameCount)
        var frames: [VOXTransformFrame] = []
        frames.reserveCapacity(frameCount)
        for index in 0..<frameCount {
            if index.isMultiple(of: 256) { try content.checkCancellation() }
            frames.append(try parseTransformFrame(attributes: try content.readDictionary()))
        }

        return VOXTransformNode(
            id: id,
            name: attributes["_name"],
            isHidden: attributes["_hidden"] == "1",
            childID: childID,
            layerID: layerID,
            frames: frames
        )
    }

    private func parseTransformFrame(attributes: [String: String]) throws -> VOXTransformFrame {
        var rotation = VOXRotation.identity
        if let value = attributes["_r"] {
            guard let packed = UInt8(value), let decoded = VOXRotation(packed: packed) else {
                throw VOXLoadingError.invalidAttribute(key: "_r", value: value)
            }
            rotation = decoded
        }

        var translation = SIMD3<Int>(repeating: 0)
        if let value = attributes["_t"] {
            let components = value.split(separator: " ", maxSplits: 3)
            guard components.count == 3, let x = Int(components[0]), let y = Int(components[1]), let z = Int(components[2]) else {
                throw VOXLoadingError.invalidAttribute(key: "_t", value: value)
            }
            translation = SIMD3(x, y, z)
        }

        var frameIndex: Int?
        if let value = attributes["_f"] {
            guard let parsed = Int(value) else {
                throw VOXLoadingError.invalidAttribute(key: "_f", value: value)
            }
            frameIndex = parsed
        }

        return VOXTransformFrame(rotation: rotation, translation: translation, frameIndex: frameIndex)
    }

    private func parseGroupNode(content: inout VOXReader) throws -> VOXGroupNode {
        let id = Int(try content.readInt32())
        _ = try content.readDictionary()
        let count = try content.readSize()
        guard count <= content.remaining / 4 else {
            throw VOXLoadingError.invalidChunk("nGRP")
        }
        var children: [Int] = []
        children.reserveCapacity(count)
        for _ in 0..<count {
            children.append(Int(try content.readInt32()))
        }
        return VOXGroupNode(id: id, childIDs: children)
    }

    private func parseShapeNode(content: inout VOXReader) throws -> VOXShapeNode {
        let id = Int(try content.readInt32())
        _ = try content.readDictionary()
        let count = try content.readSize()
        guard count <= content.remaining / 8 else {
            throw VOXLoadingError.invalidChunk("nSHP")
        }
        var models: [VOXShapeNode.ModelReference] = []
        models.reserveCapacity(count)
        for _ in 0..<count {
            let modelIndex = Int(try content.readInt32())
            let attributes = try content.readDictionary()
            models.append(.init(modelIndex: modelIndex, frameIndex: attributes["_f"].flatMap { Int($0) }))
        }
        return VOXShapeNode(id: id, models: models)
    }
}

// MARK: - Reader

private struct VOXReader {
    private let data: Data
    private let end: Int
    private let budget: VOXDecodeBudget?
    private(set) var position: Int

    init(data: Data, budget: VOXDecodeBudget?) {
        self.data = data
        self.position = data.startIndex
        self.end = data.endIndex
        self.budget = budget
    }

    private init(data: Data, start: Int, end: Int, budget: VOXDecodeBudget?) {
        self.data = data
        self.position = start
        self.end = end
        self.budget = budget
    }

    func records<T>(_ type: T.Type, count: Int) throws { try budget?.records(type, count: count) }
    func checkCancellation() throws { if budget != nil { try Task.checkCancellation() } }

    var isAtEnd: Bool { position >= end }
    var remaining: Int { end - position }

    func offset(advancedBy count: Int) throws -> Int {
        guard count >= 0, count <= remaining else {
            throw VOXLoadingError.truncated
        }
        return position + count
    }

    mutating func skip(_ count: Int) throws {
        position = try offset(advancedBy: count)
    }

    func subReader(length: Int) throws -> Self {
        Self(data: data, start: position, end: try offset(advancedBy: length), budget: budget)
    }

    mutating func readUInt8() throws -> UInt8 {
        guard remaining >= 1 else {
            throw VOXLoadingError.truncated
        }
        defer { position += 1 }
        return data[position]
    }

    mutating func readInt32() throws -> Int32 {
        guard remaining >= 4 else {
            throw VOXLoadingError.truncated
        }
        var value: UInt32 = 0
        for shift in 0..<4 {
            value |= UInt32(data[position + shift]) << UInt32(shift * 8)
        }
        position += 4
        return Int32(bitPattern: value)
    }

    /// Reads a non-negative Int32 used as a size or count.
    mutating func readSize() throws -> Int {
        let value = try readInt32()
        guard value >= 0 else {
            throw VOXLoadingError.truncated
        }
        return Int(value)
    }

    mutating func readTag() throws -> String {
        guard remaining >= 4 else {
            throw VOXLoadingError.truncated
        }
        let bytes = data[position..<position + 4]
        position += 4
        guard let result = String(bytes: bytes, encoding: .utf8) else { throw VOXLoadingError.invalidChunk("Invalid UTF-8") }
        return result
    }

    mutating func readString() throws -> String {
        let length = try readSize()
        guard length <= remaining else {
            throw VOXLoadingError.truncated
        }
        try budget?.charge(length, stride: 4)
        let bytes = data[position..<position + length]
        position += length
        guard let result = String(bytes: bytes, encoding: .utf8) else { throw VOXLoadingError.invalidChunk("Invalid UTF-8") }
        return result
    }

    mutating func readDictionary() throws -> [String: String] {
        let count = try readSize()
        // Each pair takes at least 8 bytes (two length prefixes).
        guard count <= remaining / 8 else {
            throw VOXLoadingError.truncated
        }
        try budget?.charge(count, stride: 96)
        var result: [String: String] = [:]
        for _ in 0..<count {
            let key = try readString()
            result[key] = try readString()
        }
        return result
    }
}
