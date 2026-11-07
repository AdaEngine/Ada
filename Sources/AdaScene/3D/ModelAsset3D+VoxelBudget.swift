import AdaAssets
import Foundation

extension ModelAsset3D {
    /// Validate before the legacy recursive scene builder or dense voxel-grid allocation.
    static func validateVoxelBudget(_ file: VOXFile, rootBytes: Int, options: VoxelImportOptions, limits: ModelImportLimits) throws {
        guard options.voxelSize.isFinite, options.voxelSize > 0,
            options.framesPerSecond.isFinite, options.framesPerSecond > 0
        else {
            throw AssetError.message("Invalid bounded voxel import options")
        }
        guard !options.mergeStatic else {
            throw AssetError.message("Bounded voxel imports do not support static merging")
        }
        guard file.nodes.count <= 4_096, file.layers.count <= 4_096 else { throw ModelImportLimitError.decodedBudgetExceeded }
        var budget = VoxelImportBudget(remaining: limits.maximumDecodedBytes)
        try budget.charge(1, stride: 4_096)
        try budget.charge(rootBytes, stride: 16)
        try budget.charge(file.models.count, stride: 512)
        try budget.charge(file.nodes.count, stride: 256)
        try budget.charge(file.layers.count, stride: 128)
        try budget.charge(file.materials.count, stride: 256)
        let hiddenLayers = Set(file.layers.filter(\.isHidden).map(\.id))
        var selected: Set<Int> = []
        if file.rootNode != nil {
            var stack: [(id: Int, depth: Int)] = [(0, 0)]
            var visited: Set<Int> = []
            while let entry = stack.popLast() {
                try Task.checkCancellation()
                guard entry.depth <= 64, let node = file.nodes[entry.id] else {
                    throw AssetError.message("Invalid or overly deep bounded voxel hierarchy")
                }
                if case let .transform(transform) = node,
                    transform.isHidden || hiddenLayers.contains(transform.layerID) {
                    continue
                }
                guard visited.insert(entry.id).inserted else {
                    throw AssetError.message("Bounded voxel hierarchy must be an acyclic tree")
                }
                switch node {
                case let .transform(transform):
                    guard !transform.isAnimated else { throw AssetError.message("Bounded terrain voxel imports require static transforms") }
                    for frame in transform.frames {
                        for component in [frame.translation.x, frame.translation.y, frame.translation.z] {
                            guard abs(Double(component) * Double(options.voxelSize)) <= Double(Float.greatestFiniteMagnitude) else {
                                throw AssetError.message("Voxel transform exceeds the supported coordinate range")
                            }
                        }
                    }
                    stack.append((transform.childID, entry.depth + 1))
                case let .group(group):
                    try budget.charge(group.childIDs.count, stride: 32)
                    for child in group.childIDs { stack.append((child, entry.depth + 1)) }
                case let .shape(shape):
                    guard !shape.isAnimated else { throw AssetError.message("Bounded terrain voxel imports require static models") }
                    for reference in shape.models {
                        guard file.models.indices.contains(reference.modelIndex) else { throw AssetError.message("Invalid voxel model reference") }
                        selected.insert(reference.modelIndex)
                    }
                }
            }
        } else {
            selected = Set(file.models.indices)
        }
        for index in selected.sorted() {
            try Task.checkCancellation()
            let model = file.models[index]
            let size = [model.sizeX, model.sizeY, model.sizeZ]
            guard size.allSatisfy({ $0 > 0 && Double($0) * Double(options.voxelSize) <= Double(Float.greatestFiniteMagnitude) }) else {
                throw AssetError.message("Invalid bounded voxel dimensions")
            }
            try budget.product(size, stride: 1)
            // The dense grid, largest greedy face mask, CPU/GPU surface streams and
            // derived trace/cluster storage must fit even when occupancy is sparse.
            let mask = max(model.sizeX * model.sizeY, max(model.sizeX * model.sizeZ, model.sizeY * model.sizeZ))
            try budget.charge(mask, stride: 128)
            try budget.charge(model.voxels.count, stride: 8_192)
        }
    }
}

private struct VoxelImportBudget {
    var remaining: Int

    mutating func charge(_ count: Int, stride: Int) throws {
        guard count >= 0, count <= remaining / stride else { throw ModelImportLimitError.decodedBudgetExceeded }
        remaining -= count * stride
    }

    mutating func product(_ dimensions: [Int], stride: Int) throws {
        var count = 1
        let maximum = remaining / stride
        for size in dimensions {
            guard size > 0, count <= maximum / size else { throw ModelImportLimitError.decodedBudgetExceeded }
            count *= size
        }
        try charge(count, stride: stride)
    }
}
