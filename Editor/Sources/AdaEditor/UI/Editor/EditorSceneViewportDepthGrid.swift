@_spi(AdaEngine) import AdaEngine
import Math

@MainActor
enum EditorSceneViewportDepthGrid {
    private static let extent = 240

    static func install(in world: World, isVisible: Bool) -> [Entity.ID] {
        guard let renderEngine = unsafe RenderEngine.shared else {
            return []
        }

        let device = renderEngine.renderDevice
        let minorOffsets = (-extent...extent).filter { $0 != 0 && !$0.isMultiple(of: 5) }
        let majorOffsets = stride(from: -extent, through: extent, by: 5).filter { $0 != 0 }

        let definitions: [(String, [Vector3], Color, Float)] = [
            ("Minor", gridPositions(offsets: minorOffsets), Color.fromHex(0x8190A2).opacity(0.20), 0.012),
            ("Major", gridPositions(offsets: majorOffsets), Color.fromHex(0x98A6B8).opacity(0.34), 0.020),
            ("X", [Vector3(-Float(extent), 0, 0), Vector3(Float(extent), 0, 0)], Color.fromHex(0xF04463).opacity(0.94), 0.035),
            ("Y", [Vector3(0, -Float(extent), 0), Vector3(0, Float(extent), 0)], Color.fromHex(0x80D400).opacity(0.94), 0.035),
            ("Z", [Vector3(0, 0, -Float(extent)), Vector3(0, 0, Float(extent))], Color.fromHex(0x198AF8).opacity(0.94), 0.035),
        ]

        return definitions.map { name, positions, color, width in
            let mesh = ribbonMesh(name: "Editor Viewport Grid \(name)", segments: positions, width: width, renderDevice: device)
            let material = CustomMaterial(ColorCanvasMaterial(color: color))
            let entity = world.spawn("EditorViewportGrid_\(name)") {
                Mesh2D(mesh: mesh, materials: [material])
                Transform()
                NoFrustumCulling()
                isVisible ? Visibility.visible : Visibility.hidden
            }
            return entity.id
        }
    }

    static func setVisibility(_ isVisible: Bool, entityIDs: [Entity.ID], in world: World) {
        let visibility: Visibility = isVisible ? .visible : .hidden
        for entityID in entityIDs {
            world.getEntityByID(entityID)?.components += visibility
        }
    }

    static func centerGrid(at position: Vector3, entityIDs: [Entity.ID], in world: World) {
        for entityID in entityIDs.prefix(2) {
            guard
                let entity = world.getEntityByID(entityID),
                var transform = entity.components[Transform.self]
            else {
                continue
            }
            let gridPosition = Vector3(floor(position.x), 0, floor(position.z))
            guard transform.position != gridPosition else {
                continue
            }
            transform.position = gridPosition
            entity.components += transform
        }
    }

    private static func gridPositions(offsets: [Int]) -> [Vector3] {
        var positions: [Vector3] = []
        positions.reserveCapacity(offsets.count * 4)
        for offset in offsets {
            let distance = Float(offset)
            positions.append(contentsOf: [
                Vector3(-Float(extent), 0, distance),
                Vector3(Float(extent), 0, distance),
                Vector3(distance, 0, -Float(extent)),
                Vector3(distance, 0, Float(extent)),
            ])
        }
        return positions
    }

    private static func ribbonMesh(name: String, segments: [Vector3], width: Float, renderDevice: RenderDevice) -> Mesh {
        var positions: [Vector3] = []
        var indices: [UInt32] = []
        positions.reserveCapacity(segments.count * 2)
        indices.reserveCapacity(segments.count * 3)

        for index in stride(from: 0, to: segments.count, by: 2) {
            let start = segments[index]
            let end = segments[index + 1]
            let direction = (end - start).normalized
            if abs(direction.y) > 0.9 {
                appendRibbon(from: start, to: end, perpendicular: .right, width: width, positions: &positions, indices: &indices)
                appendRibbon(from: start, to: end, perpendicular: Vector3(0, 0, 1), width: width, positions: &positions, indices: &indices)
            } else {
                let perpendicular = Vector3(-direction.z, 0, direction.x)
                appendRibbon(from: start, to: end, perpendicular: perpendicular, width: width, positions: &positions, indices: &indices)
            }
        }

        var descriptor = Quad().meshDescriptors()[0]
        descriptor.name = name
        descriptor.primitiveTopology = .triangleList
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = nil
        descriptor.textureCoordinates = nil
        descriptor.indicies = indices
        return Mesh.generate(from: [descriptor], renderDevice: renderDevice)
    }

    private static func appendRibbon(
        from start: Vector3,
        to end: Vector3,
        perpendicular: Vector3,
        width: Float,
        positions: inout [Vector3],
        indices: inout [UInt32]
    ) {
        let offset = perpendicular * (width * 0.5)
        let base = UInt32(positions.count)
        positions.append(contentsOf: [start - offset, end - offset, end + offset, start + offset])
        indices.append(contentsOf: [base, base + 1, base + 2, base + 2, base + 3, base])
    }
}
