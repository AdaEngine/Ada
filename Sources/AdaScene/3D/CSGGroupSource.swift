import AdaAssets
import AdaGeometry
import AdaPhysics
@_spi(Internal) import AdaRender
import AdaTransform
import Foundation
import Math
import Synchronization

/// A solid in a CSG group's local coordinates. Scale sets its dimensions.
public struct CSGBoxOperand: Codable, Equatable, Sendable {
    public var transform: Transform
    public var operation: TriangleBooleanOperation
    private var authoredShape: CSGShape?

    public var shape: CSGShape { authoredShape ?? .box }

    public init(transform: Transform = .init(), operation: TriangleBooleanOperation = .union, shape: CSGShape = .box) {
        self.transform = transform
        self.operation = operation
        authoredShape = shape == .box ? nil : shape
    }
}

public enum CSGTextureSource: Codable, Equatable, Sendable {
    case checker
    case image(URL, modified: Date? = nil)
}

/// An ordered group of editable solids. The first operand supplies the starting volume.
public struct CSGGroupSource: Codable, Equatable, Sendable {
    public static let maximumBoxes = 128
    public static var isAvailable: Bool { TriangleMeshBoolean.isAvailable }
    public var boxes: [CSGBoxOperand]
    public var uvRepeats: Int?
    public var texture: CSGTextureSource?

    public init(boxes: [CSGBoxOperand], uvRepeats: Int? = nil, texture: CSGTextureSource? = nil) {
        self.boxes = boxes
        self.uvRepeats = uvRepeats
        self.texture = texture
    }

    /// Evaluates an immutable snapshot away from the caller's actor.
    @concurrent
    public func evaluate() async throws -> CSGSurface {
        guard Self.isAvailable else { throw TriangleGeometryError.kernelUnavailable }
        guard boxes.count <= Self.maximumBoxes else { throw TriangleGeometryError.budgetExceeded }
        let repeats = uvRepeats ?? 1
        guard (1...64).contains(repeats) else { throw TriangleGeometryError.invalidInput }

        let budget = TriangleGeometryBudget(maximumInputTriangles: 16_384, maximumOutputTriangles: 16_384, maximumBytes: 32 * 1_024 * 1_024)
        var result = TriangleSurface(positions: [], indices: [])
        for (index, box) in boxes.enumerated() {
            try Task.checkCancellation()
            let surface = try box.shape.surface(source: UInt32(index + 1)).transformed(by: box.transform.matrix)
            if index == 0 {
                result = surface
            } else {
                result = try await TriangleMeshBoolean.applyCancellable(box.operation, base: result, operand: surface, budget: budget)
            }
        }
        try Task.checkCancellation()
        if !result.indices.isEmpty {
            // Float placement can collapse an edge even when its transform is finite.
            _ = try Shape3DResource.generateTriangleMesh(vertices: result.positions, indices: result.indices)
        }
        let mesh = try makeMesh(from: result, repeats: Float(repeats))
        let evaluated = try CSGSurface(surface: result, mesh: mesh, textureSource: texture)
        try Task.checkCancellation()
        return evaluated
    }

    private func makeMesh(from surface: TriangleSurface, repeats: Float) throws -> ProceduralMeshData {
        var mesh = ProceduralMeshData()
        mesh.positions.reserveCapacity(surface.indices.count)
        mesh.normals.reserveCapacity(surface.indices.count)
        mesh.uvs.reserveCapacity(surface.indices.count)
        for start in stride(from: 0, to: surface.indices.count, by: 3) {
            if start.isMultiple(of: 3072) { try Task.checkCancellation() }
            let indices = surface.indices[start..<(start + 3)].map(Int.init)
            let points = indices.map { surface.positions[$0] }
            let normal = (points[1] - points[0]).cross(points[2] - points[0]).normalized
            mesh.positions.append(contentsOf: points.map { SIMD3($0.x, $0.y, $0.z) })
            mesh.normals.append(contentsOf: repeatElement(SIMD3(normal.x, normal.y, normal.z), count: 3))

            // The Boolean kernel interpolates each source chart, including cutter faces.
            for index in indices {
                let uv = surface.textureCoordinates[index]
                mesh.uvs.append(SIMD2(uv.x * repeats, uv.y * repeats))
            }
        }
        mesh.indices = mesh.positions.indices.map { UInt32($0) }
        return mesh
    }
}

/// Shared CPU output for the preview, Play and native export.
public struct CSGSurface: Equatable, Sendable {
    public let surface: TriangleSurface
    private let mesh: ProceduralMeshData
    private let texture: CSGTexture?
    public var isEmpty: Bool { surface.indices.isEmpty }

    init(surface: TriangleSurface, mesh: ProceduralMeshData, textureSource: CSGTextureSource?) throws {
        self.surface = surface
        self.mesh = mesh
        texture = surface.indices.isEmpty ? nil : try textureSource.map(CSGTexture.load)
    }

    private static let material = ProceduralMaterial(name: "CSG", baseColor: [0.66, 0.7, 0.76, 1], roughness: 0.78)

    public func renderComponent(renderDevice: RenderDevice) -> Mesh3DComponent? {
        guard !isEmpty else {
            return nil
        }
        var descriptor = MeshDescriptor(name: "CSG")
        descriptor.positions = .init(mesh.positions.map { Vector3($0.x, $0.y, $0.z) })
        descriptor.normals = .init(mesh.normals.map { Vector3($0.x, $0.y, $0.z) })
        descriptor.textureCoordinates = .init(mesh.uvs.map { Vector2($0.x, $0.y) })
        descriptor.indicies = mesh.indices
        let material = PBRMaterial()
        let tint = Self.material.baseColor
        material.baseColorFactor = Vector4(tint.x, tint.y, tint.z, tint.w)
        material.metallicFactor = Self.material.metallic
        material.roughnessFactor = Self.material.roughness
        if let texture {
            material.baseColorTexture = texture.uploaded(to: renderDevice)
        }
        let renderMesh = Mesh.generate(from: [descriptor], renderDevice: renderDevice)
        return Mesh3DComponent(mesh: renderMesh, materials: [material])
    }

    public func modelData() throws -> Data {
        var material = Self.material
        material.baseColorPNG = texture?.png
        return try GLBWriter().encode(.init(materials: [material], nodes: [.init(name: "CSG", mesh: mesh)]))
    }

    /// Places the surface in world space for a static body at the scene root.
    public func collisionShape(worldMatrix: Transform3D) throws -> Shape3DResource? {
        guard !isEmpty else {
            return nil
        }
        return try StaticTriangleMesh3DSource(surface: surface).makeShape(worldMatrix: worldMatrix)
    }
}

private final class CSGTexture: Equatable, Sendable {
    private struct TextureCache: Sendable {
        var textures: [String: CSGTexture] = [:]
        var bytes = 0
    }

    private static let cache = Mutex(TextureCache())
    private static let cacheBudget = 192 * 1_024 * 1_024

    private let image: Image
    private let gpu = Mutex<(ObjectIdentifier, Texture2D)?>(nil)
    let png: Data

    static func load(_ source: CSGTextureSource) throws -> CSGTexture {
        let key: String
        switch source {
        case .checker:
            key = "checker"
        case let .image(url, modified):
            let revision = modified ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            key = "\(url.absoluteString)|\(revision?.timeIntervalSinceReferenceDate ?? -1)"
        }
        if let loaded = cache.withLock({ $0.textures[key] }) {
            return loaded
        }
        let loaded = try CSGTexture(source)
        let cost = loaded.image.data.count * 2 + loaded.png.count
        guard cost <= cacheBudget else {
            return loaded
        }
        return cache.withLock { value in
            if let cached = value.textures[key] {
                return cached
            }
            if value.bytes + cost > cacheBudget {
                value = TextureCache()
            }
            value.textures[key] = loaded
            value.bytes += cost
            return loaded
        }
    }

    func uploaded(to device: RenderDevice) -> Texture2D {
        let deviceID = ObjectIdentifier(device)
        return gpu.withLock { entry in
            if let entry, entry.0 == deviceID {
                return entry.1
            }
            let sampler = SamplerDescriptor(
                minFilter: .linear, magFilter: .linear, mipFilter: .notMipmapped, addressModeU: .repeat, addressModeV: .repeat
            )
            let texture = Texture2D(image: image, samplerDescription: sampler)
            entry = (deviceID, texture)
            return texture
        }
    }

    private init(_ source: CSGTextureSource) throws {
        let pixels: Image
        switch source {
        case .checker:
            let size = 64
            var bytes: [UInt8] = []
            bytes.reserveCapacity(size * size * 4)
            for y in 0..<size {
                for x in 0..<size {
                    let light = (x / 8 + y / 8).isMultiple(of: 2)
                    bytes.append(contentsOf: light ? [222, 222, 222, 255] : [43, 50, 62, 255])
                }
            }
            pixels = Image(width: size, height: size, data: Data(bytes))
        case let .image(url, _):
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard (1...(32 * 1_024 * 1_024)).contains(size) else { throw TriangleGeometryError.budgetExceeded }
            let bytes = try Data(contentsOf: url)
            guard bytes.count <= 32 * 1_024 * 1_024 else { throw TriangleGeometryError.budgetExceeded }
            guard try Image.decodedImportByteCount(from: bytes) <= 4_096 * 4_096 * 4 else { throw TriangleGeometryError.budgetExceeded }
            pixels = try Image.decode(from: bytes, fileExtension: url.pathExtension.lowercased())
            guard pixels.width <= 4_096, pixels.height <= 4_096 else { throw TriangleGeometryError.budgetExceeded }
        }
        png = try pixels.pngData()
        guard let normalized = try ImageMipmaps.make(from: pixels, colorSpace: .sRGB, includeMipmaps: false).first else {
            throw TriangleGeometryError.invalidInput
        }
        image = normalized
    }

    static func == (lhs: CSGTexture, rhs: CSGTexture) -> Bool {
        lhs.png == rhs.png
    }
}
