import AdaAssets
import AdaGeometry
@_spi(Internal) import AdaRender
import Foundation
import Math

/// Geometry stays indexed for queries and collision. The display mesh carries a
/// separate triangle-field address; overlapping sheets never share atlas texels.
struct MeshTerrainMaterialPreparation {
    private struct UniformSample: Hashable {
        let ids: Vector4
        let weights: Vector4
    }

    private struct UniformVertex: Hashable {
        let vertex: UInt32
        let sample: UniformSample
    }

    let palette: TerrainMaterialPalette
    private let resolver: TerrainMaterialResolver
    private let surfaceLayers: [UInt32: UInt16]
    private let writers: [MeshTerrainContactField.Writer]
    private var work = 32 * 1_024 * 1_024

    init(palette: TerrainMaterialPalette, document: MeshTerrainDocument) throws {
        self.palette = palette
        resolver = try TerrainMaterialResolver(palette)
        let ids = palette.layers.map(\.id).sorted()
        let slots = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        var layers: [UInt32: UInt16] = [:], writers: [MeshTerrainContactField.Writer] = []
        let ordered = document.modifiers.filter(\.enabled).sorted {
            $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order
        }
        for modifier in ordered {
            let id = modifier.materialLayer ?? (modifier.operation == .subtract ? palette.interiorLayerID : nil)
            guard let id else { continue }
            guard let slot = slots[id] else {
                throw TerrainSourceError.resourceLoadingFailed("Mesh Terrain refers to material layer \(id), which is missing from its palette.")
            }
            switch modifier.operation {
            case .union, .subtract:
                layers[modifier.sourceID] = id
                if modifier.operation == .union, modifier.contactWidth > 0 {
                    writers.append(.init(source: modifier.sourceID, layer: slot, width: modifier.contactWidth))
                }
            default: break
            }
        }
        for stamp in document.paint {
            if case let .paint(layer) = stamp.operation, slots[layer] == nil {
                throw TerrainSourceError.resourceLoadingFailed("Painted terrain layer \(layer) is missing from the palette")
            }
        }
        surfaceLayers = layers
        self.writers = writers
    }

    static func charge(for surface: TriangleSurface) -> Int {
        // Expanded display vertices and triangle field rows, renderer buffers and upload staging.
        surface.indices.count * 160 + 1_024
    }

    mutating func prepare(_ surface: TriangleSurface, paint: MeshTerrainCompiledPaint?, canonical: inout MeshDescriptor,
                          maximumScratchBytes: Int, sharesUniformVertices: Bool) throws -> MeshDescriptor {
        let count = surface.indices.count
        let cost = resolver.evaluationWorkCost
        guard count <= work / cost else { throw TerrainSourceError.meshBudgetExceeded }
        work -= count * cost
        let contact = try MeshTerrainContactField.build(surface, writers: writers, maximumBytes: maximumScratchBytes, work: &work)
        let columns = max(1, Int(ceil(Double(count / 3).squareRoot())))
        let width = columns * 2, height = max(1, (count / 3 + columns - 1) / columns) * 2
        var ids = [Vector4](repeating: .zero, count: width * height)
        var weights = ids
        var positions: [Vector3] = [], normals: [Vector3] = [], fieldUV: [Vector2] = []
        var indices: [UInt32] = []
        var shared: [UniformVertex: UInt32] = [:]
        var addresses: [UniformSample: Vector2] = [:]
        positions.reserveCapacity(count); normals.reserveCapacity(count); fieldUV.reserveCapacity(count)
        indices.reserveCapacity(count)
        guard let canonicalNormals = canonical.normals?.elements else { throw TerrainSourceError.changedDuringBuild }
        let authored = paint?.samples ?? []
        var authoredIndex = 0
        for face in 0..<count / 3 {
            if face.isMultiple(of: 128) { try Task.checkCancellation() }
            let x = (face % columns) * 2, y = (face / columns) * 2
            let source = surface.faceSources.isEmpty ? 0 : surface.faceSources[face]
            for corner in 0..<3 {
                let vertex = Int(surface.indices[face * 3 + corner])
                let position = surface.positions[vertex], normal = canonicalNormals[vertex]
                let cornerIndex = face * 3 + corner
                var manual: MeshTerrainCompiledPaint.Sample?
                if authoredIndex < authored.count, authored[authoredIndex].corner == cornerIndex {
                    manual = authored[authoredIndex]
                    authoredIndex += 1
                }
                let sample = try resolver.resolveMesh(
                    position: position, normal: normal, contact: source == 0 ? contact?.contact(at: vertex) : nil,
                    sourceLayer: surfaceLayers[source], paint: manual
                )
                let dx = corner == 1 ? 1 : 0, dy = corner == 2 ? 1 : 0
                let texel = (y + dy) * width + x + dx
                ids[texel] = sample.ids; weights[texel] = sample.weights
            }
            let texel = y * width + x
            let sample = UniformSample(ids: ids[texel], weights: weights[texel])
            // Constant fields can share one exact texel address. Varying paint
            // keeps the original three corners and their triangle-local address.
            let uniform = sharesUniformVertices && ids[texel + 1] == sample.ids && ids[texel + width] == sample.ids
                && weights[texel + 1] == sample.weights && weights[texel + width] == sample.weights
            let address = Vector2(Float(x), Float(y))
            // Keep interpolation roundoff away from the adjacent field cell.
            let uniformAddress = uniform ? addresses[sample, default: address + [0.5, 0.5]] : address
            if uniform { addresses[sample] = uniformAddress }
            for corner in 0..<3 {
                let vertex = surface.indices[face * 3 + corner]
                let key = UniformVertex(vertex: vertex, sample: sample)
                if uniform, let index = shared[key] {
                    indices.append(index)
                    continue
                }
                let index = UInt32(positions.count)
                indices.append(index)
                positions.append(surface.positions[Int(vertex)])
                normals.append(canonicalNormals[Int(vertex)])
                if uniform {
                    shared[key] = index
                    fieldUV.append(uniformAddress)
                } else {
                    fieldUV.append(address + [corner == 1 ? 1 : 0, corner == 2 ? 1 : 0])
                }
            }
        }
        canonical[TerrainSourceMaterials.layerIDs] = MeshBuffer(ids)
        canonical[TerrainSourceMaterials.weights] = MeshBuffer(weights)
        var display = MeshDescriptor(name: canonical.name)
        display.positions = MeshBuffer(positions); display.normals = MeshBuffer(normals)
        display.textureCoordinates = MeshBuffer(positions.map { [$0.x, $0.z] })
        display[MeshDescriptor.textureCoordinates1] = MeshBuffer(fieldUV)
        display.indicies = indices
        return display
    }
}

struct MeshTerrainPreparedMaterials: Sendable {
    let palette: TerrainMaterialPalette
    let maps: TerrainPreparedMaterialMaps
}
