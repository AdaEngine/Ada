import AdaECS
import AdaRender
import Math

/// Per-draw material parameters; vertex instance data retains color and metal/rough factors.
public struct PBR3DUniform: Sendable {
    public let emissiveFactor: Vector4
    public let properties: Vector4
    public let flags: Vector4
    public let coordinates: Vector4
    public let emission: Vector4

    public init(material: PBRMaterial?, descriptor _: VertexDescriptor) {
        func coordinate(_ slot: Int) -> Int {
            guard let material, material.textureCoordinates.indices.contains(slot) else {
                return 0
            }
            return material.textureCoordinates[slot]
        }
        emissiveFactor = Vector4(material?.emissiveFactor ?? .one, 0)
        properties = Vector4(material?.normalScale ?? 1, material?.occlusionStrength ?? 1, material?.alphaCutoff ?? 0.5, Float(material?.alphaMode.rawValue ?? 0))
        flags = Vector4(material?.doubleSided ?? true ? 1 : 0, material?.occlusionTexture != nil ? 1 : 0, 0, 0)
        coordinates = Vector4(Float(coordinate(0)), Float(coordinate(1)), Float(coordinate(2)), Float(coordinate(3)))
        emission = Vector4(Float(coordinate(4)), material?.baseColorFactor.w ?? 1, 1, 0)
    }
}

/// Reuses triple-buffered material uniforms and prunes entries after material removal.
public struct PBR3DUniforms: Resource {
    public static let binding = 15
    private struct Entry { var buffers: [(any UniformBuffer)?]; var frame: Int }
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var currentIndex = 0
    private var frame = 0
    private let count: Int

    public init() { count = max(1, unsafe RenderEngine.configurations.maxFramesInFlight) }

    public mutating func beginFrame() {
        for (key, entry) in entries where entry.frame != frame { entries.removeValue(forKey: key) }
        frame &+= 1
        currentIndex = (currentIndex + 1) % count
    }

    public mutating func write(material: Material, descriptor: VertexDescriptor, device: RenderDevice) {
        let key = ObjectIdentifier(material)
        var entry = entries[key] ?? Entry(buffers: Array(repeating: nil, count: count), frame: frame)
        if entry.buffers[currentIndex] == nil { entry.buffers[currentIndex] = device.createUniformBuffer(PBR3DUniform.self, binding: Self.binding) }
        let uniform = PBR3DUniform(material: material as? PBRMaterial, descriptor: descriptor)
        entry.buffers[currentIndex]?.setData(uniform)
        entry.frame = frame
        entries[key] = entry
    }

    public func buffer(for material: Material) -> (any UniformBuffer)? {
        entries[ObjectIdentifier(material)]?.buffers[currentIndex]
    }
}
