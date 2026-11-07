#if canImport(CManifold)
import CManifold
#endif
import Foundation
import Math

/// Editable triangle geometry. Attribute vertices may split UV/normal seams;
/// provenance identifies source faces independently of render buffer identity.
public struct TriangleSurface: Codable, Equatable, Sendable {
    public var positions: [Vector3]
    public var normals: [Vector3]
    public var textureCoordinates: [Vector2]
    public var indices: [UInt32]
    public var faceSources: [UInt32]
    public var faceIDs: [UInt32]

    public init(positions: [Vector3], indices: [UInt32], normals: [Vector3] = [], textureCoordinates: [Vector2] = [], faceSources: [UInt32] = [], faceIDs: [UInt32] = []) {
        self.positions = positions; self.indices = indices; self.normals = normals; self.textureCoordinates = textureCoordinates
        self.faceSources = faceSources; self.faceIDs = faceIDs
    }

    public func validate(maximumTriangles: Int = 262_144) throws {
        guard maximumTriangles >= 0, maximumTriangles <= 1_048_576, indices.count.isMultiple(of: 3), indices.count / 3 <= maximumTriangles,
            positions.count <= maximumTriangles * 3, normals.isEmpty || normals.count == positions.count,
            textureCoordinates.isEmpty || textureCoordinates.count == positions.count,
            faceSources.isEmpty || faceSources.count == indices.count / 3, faceIDs.isEmpty || faceIDs.count == indices.count / 3,
            positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
            normals.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
            textureCoordinates.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), indices.allSatisfy({ $0 < UInt32(positions.count) })
        else { throw TriangleGeometryError.invalidInput }
    }

    /// Applies complete source placement, including inverse-transpose normals and reflected winding.
    public func transformed(by matrix: Transform3D) throws -> Self {
        guard indices.count.isMultiple(of: 3) else { throw TriangleGeometryError.invalidInput }
        try ScalarSolid.validateTransform(matrix)
        var result = self
        result.positions = positions.map { (matrix * Vector4($0, 1)).xyz }
        let inverse = matrix.inverse
        result.normals = normals.map { normal in
            let value = Vector3(inverse.x.xyz.dot(normal), inverse.y.xyz.dot(normal), inverse.z.xyz.dot(normal))
            return value.squaredLength > 0 ? value.normalized : .up
        }
        if matrix.determinant < 0 {
            for start in stride(from: 0, to: result.indices.count, by: 3) { result.indices.swapAt(start + 1, start + 2) }
        }
        try result.validate()
        return result
    }
}

public enum TriangleGeometryError: LocalizedError, Equatable, Sendable {
    case invalidInput, nonManifold, budgetExceeded, cancelled, kernelUnavailable, kernelFailure(Int)
    case operandOutsideTerrain

    public var errorDescription: String? {
        switch self {
        case .operandOutsideTerrain: return "Move the whole joined mesh inside the terrain boundary."
        default: return nil
        }
    }
}

public enum TriangleBooleanOperation: String, Codable, Sendable {
    case union, subtract, intersect
}

public struct TriangleGeometryBudget: Sendable {
    public var maximumInputTriangles: Int
    public var maximumOutputTriangles: Int
    public var maximumBytes: Int
    public var maximumCandidatePairs: Int

    public init(maximumInputTriangles: Int = 65_536, maximumOutputTriangles: Int = 262_144,
                maximumBytes: Int = 256 * 1_024 * 1_024, maximumCandidatePairs: Int = 1_048_576) {
        self.maximumInputTriangles = maximumInputTriangles; self.maximumOutputTriangles = maximumOutputTriangles
        self.maximumBytes = maximumBytes; self.maximumCandidatePairs = maximumCandidatePairs
    }
}

/// Triangle processing at the kernel's declared floating-point tolerance;
/// this route never silently resamples the inputs into a density grid.
#if canImport(CManifold)
public enum TriangleMeshBoolean {
    public static var isAvailable: Bool { true }
    public static func apply(_ operation: TriangleBooleanOperation, base: TriangleSurface, operand: TriangleSurface,
                             budget: TriangleGeometryBudget = .init()) throws -> TriangleSurface {
        try base.validate(maximumTriangles: budget.maximumInputTriangles)
        try operand.validate(maximumTriangles: budget.maximumInputTriangles)
        if let identity = try emptyResult(operation, base: base, operand: operand, budget: budget) { return identity }
        try Task.checkCancellation()
        try TriangleGeometryAdmission.validate(base: base, operand: operand, budget: budget)
        return unsafe try evaluate(operation, base: base, operand: operand, budget: budget, cancellation: TriangleBooleanCancellation())
    }

    public static func applyCancellable(_ operation: TriangleBooleanOperation, base: TriangleSurface, operand: TriangleSurface,
                                        budget: TriangleGeometryBudget = .init()) async throws -> TriangleSurface {
        try base.validate(maximumTriangles: budget.maximumInputTriangles)
        try operand.validate(maximumTriangles: budget.maximumInputTriangles)
        if let identity = try emptyResult(operation, base: base, operand: operand, budget: budget) { return identity }
        try Task.checkCancellation()
        try TriangleGeometryAdmission.validate(base: base, operand: operand, budget: budget)
        let cancellation = unsafe try TriangleBooleanCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return unsafe try evaluate(operation, base: base, operand: operand, budget: budget, cancellation: cancellation)
        } onCancel: { unsafe cancellation.cancel() }
    }

    private static func emptyResult(_ operation: TriangleBooleanOperation, base: TriangleSurface, operand: TriangleSurface,
                                    budget: TriangleGeometryBudget) throws -> TriangleSurface? {
        guard base.indices.isEmpty || base.indices.count >= 12, operand.indices.isEmpty || operand.indices.count >= 12 else {
            throw TriangleGeometryError.nonManifold
        }
        guard base.indices.isEmpty || operand.indices.isEmpty else { return nil }
        try Task.checkCancellation()
        try TriangleGeometryAdmission.validate(base: base, operand: operand, budget: budget)
        switch operation {
        case .union: return base.indices.isEmpty ? operand : base
        case .subtract: return base
        case .intersect: return .init(positions: [], indices: [])
        }
    }

    private static func evaluate(_ operation: TriangleBooleanOperation, base: TriangleSurface, operand: TriangleSurface,
                                 budget: TriangleGeometryBudget, cancellation: TriangleBooleanCancellation) throws -> TriangleSurface {
        let first = PackedTriangleInput(base), second = PackedTriangleInput(operand)
        var status: Int32 = 0
        let result = unsafe first.withInput { a in
            unsafe second.withInput { b in
                unsafe ada_mesh_boolean(cancellation.handle, a, b, operation == .union ? 0 : operation == .subtract ? 1 : 2,
                                 budget.maximumOutputTriangles, budget.maximumBytes, &status)
            }
        }
        guard let result = unsafe result else {
            switch status {
            case 1: throw TriangleGeometryError.invalidInput
            case 2: throw TriangleGeometryError.nonManifold
            case 3: throw TriangleGeometryError.budgetExceeded
            case 4: throw CancellationError()
            default: throw TriangleGeometryError.kernelFailure(Int(status))
            }
        }
        defer { unsafe ada_mesh_result_destroy(result) }
        try Task.checkCancellation()
        let vertices = unsafe ada_mesh_result_vertex_count(result), count = unsafe ada_mesh_result_index_count(result)
        guard count > 0 else { return .init(positions: [], indices: []) }
        guard let properties = unsafe ada_mesh_result_properties(result), let indices = unsafe ada_mesh_result_indices(result),
            let sources = unsafe ada_mesh_result_sources(result), let faces = unsafe ada_mesh_result_faces(result) else { throw TriangleGeometryError.invalidInput }
        var positions: [Vector3] = [], normals: [Vector3] = [], uv: [Vector2] = []
        positions.reserveCapacity(vertices); normals.reserveCapacity(vertices); uv.reserveCapacity(vertices)
        for index in 0..<vertices {
            if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
            let start = index * 8
            unsafe positions.append([Float(properties[start]), Float(properties[start + 1]), Float(properties[start + 2])])
            let normal = unsafe Vector3(Float(properties[start + 3]), Float(properties[start + 4]), Float(properties[start + 5]))
            normals.append(normal.squaredLength > 0 ? normal.normalized : .up)
            unsafe uv.append([Float(properties[start + 6]), Float(properties[start + 7])])
        }
        let surface = unsafe TriangleSurface(positions: positions, indices: Array(UnsafeBufferPointer(start: indices, count: count)), normals: normals,
                                      textureCoordinates: uv, faceSources: Array(UnsafeBufferPointer(start: sources, count: count / 3)),
                                      faceIDs: Array(UnsafeBufferPointer(start: faces, count: count / 3)))
        try surface.validate(maximumTriangles: budget.maximumOutputTriangles)
        return surface
    }
}

/// The handle is immutable and owned until evaluation exits. The native execution
/// context explicitly synchronizes Cancel() with evaluation; no Swift mutable state is shared.
@unsafe
private final class TriangleBooleanCancellation: @unchecked Sendable {
    let handle: OpaquePointer
    init() throws {
        guard let handle = unsafe ada_mesh_context_create() else { throw TriangleGeometryError.budgetExceeded }
        unsafe self.handle = handle
    }
    deinit { unsafe ada_mesh_context_destroy(handle) }
    func cancel() { unsafe ada_mesh_context_cancel(handle) }
}

private struct PackedTriangleInput {
    let properties: [Double]
    let indices: [UInt32]
    let sources: [UInt32]
    let faces: [UInt32]

    init(_ surface: TriangleSurface) {
        indices = surface.indices
        sources = surface.faceSources.isEmpty ? Array(repeating: 0, count: indices.count / 3) : surface.faceSources
        faces = surface.faceIDs.isEmpty ? Array(0..<UInt32(indices.count / 3)) : surface.faceIDs
        var normals = surface.normals
        if normals.isEmpty {
            normals = Array(repeating: .zero, count: surface.positions.count)
            for start in stride(from: 0, to: indices.count, by: 3) {
                let a = Int(indices[start]), b = Int(indices[start + 1]), c = Int(indices[start + 2])
                let normal = (surface.positions[b] - surface.positions[a]).cross(surface.positions[c] - surface.positions[a])
                normals[a] += normal; normals[b] += normal; normals[c] += normal
            }
        }
        var values: [Double] = []
        values.reserveCapacity(surface.positions.count * 8)
        for (index, point) in surface.positions.enumerated() {
            let normal = normals[index].squaredLength > 0 ? normals[index].normalized : .up
            let uv = surface.textureCoordinates.isEmpty ? Vector2(point.x, point.z) : surface.textureCoordinates[index]
            values.append(contentsOf: [Double(point.x), Double(point.y), Double(point.z), Double(normal.x), Double(normal.y), Double(normal.z), Double(uv.x), Double(uv.y)])
        }
        properties = values
    }

    func withInput<Result>(_ body: (AdaMeshBooleanInput) -> Result) -> Result {
        unsafe properties.withUnsafeBufferPointer { properties in
            unsafe indices.withUnsafeBufferPointer { indices in
                unsafe sources.withUnsafeBufferPointer { sources in
                    unsafe faces.withUnsafeBufferPointer { faces in
                        unsafe body(.init(properties: properties.baseAddress, vertexCount: properties.count / 8, indices: indices.baseAddress,
                                   indexCount: indices.count, faceSources: sources.baseAddress, faceIDs: faces.baseAddress))
                    }
                }
            }
        }
    }
}

#else
public enum TriangleMeshBoolean {
    public static var isAvailable: Bool { false }
    public static func apply(_ operation: TriangleBooleanOperation, base: TriangleSurface, operand: TriangleSurface,
                             budget: TriangleGeometryBudget = .init()) throws -> TriangleSurface {
        throw TriangleGeometryError.kernelUnavailable
    }
    public static func applyCancellable(_ operation: TriangleBooleanOperation, base: TriangleSurface, operand: TriangleSurface,
                                        budget: TriangleGeometryBudget = .init()) async throws -> TriangleSurface {
        throw TriangleGeometryError.kernelUnavailable
    }
}
#endif
