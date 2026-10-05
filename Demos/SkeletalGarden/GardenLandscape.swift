import AdaEngine

@MainActor
func makeGardenLandscape(in world: World, device: RenderDevice) throws {
    let terrain = GardenTerrain()
    let grass = PBRMaterial()
    grass.baseColorFactor = .one
    grass.metallicFactor = 0
    grass.roughnessFactor = 0.95
    let collision = try Shape3DResource.generateTriangleMesh(vertices: terrain.vertices, indices: terrain.indices)
    world.spawn("Rolling landscape") {
        Mesh3DComponent(mesh: .generate(from: [terrain.descriptor()], renderDevice: device), materials: [grass])
        PhysicsBody3DComponent(shapes: [collision], mode: .static)
        Transform()
    }
    let tree = try landscapeModel("Tree")
    let rock = try landscapeModel("Rock")
    let tuft = try landscapeModel("Grass")
    var random = GardenRandom()
    var trees = 0, rocks = 0, grasses = 0
    for row in -4...4 {
        for column in -4...4 {
            let x = Float(column) * 4.8 + random.next(-1.4, 1.4)
            let z = Float(row) * 4.8 + random.next(-1.4, 1.4)
            guard max(abs(x), abs(z)) > 8, abs(x - GardenTerrain.trailX(z: z)) > 2.5 else { continue }
            let size = random.next(0.65, 1.25)
            let height = terrain.surfaceHeight(x: x, z: z)
            let root = tree.instantiate(in: world)
            root.components[Transform.self] = Transform(rotation: Quat(axis: .up, angle: random.next(0, .pi * 2)), scale: Vector3(size), position: [x, height, z])
            world.spawn("Tree trunk collider") {
                PhysicsBody3DComponent(shapes: [
                    .generateBox(width: 0.45 * size, height: 2.8 * size, depth: 0.45 * size),
                    .generateSphere(radius: 1.45 * size).offsetBy(x: 0, y: 1.9 * size, z: 0),
                ], mode: .static)
                Transform(position: [x, height + 1.4 * size, z])
            }
            trees += 1
        }
    }
    for _ in 0..<50 {
        let x = random.next(-22, 22), z = random.next(-22, 22)
        guard max(abs(x), abs(z)) > 6.5, abs(x - GardenTerrain.trailX(z: z)) > 1.8 else { continue }
        let scale = random.next(0.45, 1.35)
        let height = terrain.surfaceHeight(x: x, z: z)
        let root = rock.instantiate(in: world)
        root.components[Transform.self] = Transform(rotation: Quat(axis: .up, angle: random.next(0, .pi * 2)), scale: Vector3(scale), position: [x, height, z])
        world.spawn("Rock collider") {
            PhysicsBody3DComponent(shapes: [.generateSphere(radius: 0.72 * scale)], mode: .static)
            Transform(position: [x, height + 0.5 * scale, z])
        }
        rocks += 1
    }
    for _ in 0..<220 {
        let x = random.next(-23, 23), z = random.next(-23, 23)
        guard max(abs(x), abs(z)) > 6.2, abs(x - GardenTerrain.trailX(z: z)) > 1.3 else { continue }
        let root = tuft.instantiate(in: world)
        root.components[Transform.self] = Transform(
            rotation: Quat(axis: .up, angle: random.next(0, .pi * 2)),
            scale: Vector3(random.next(0.8, 1.5)),
            position: [x, terrain.surfaceHeight(x: x, z: z), z]
        )
        grasses += 1
    }
    try makeGardenLandmarks(in: world, terrain: terrain, device: device)
    gardenLog("[SkeletalGarden] landscape 48x48m, \(terrain.indices.count / 3) terrain triangles; \(trees) trees, \(rocks) rocks, \(grasses) grass tufts")
}

@MainActor
private func landscapeModel(_ name: String) throws -> ModelAsset3D {
    guard let model = try AssetsManager.loadSync(ModelAsset3D.self, at: "Assets/\(name).glb", from: gardenBundle).asset else {
        throw AssetError.message("Missing landscape asset \(name)")
    }
    return model
}

@MainActor
private func makeGardenLandmarks(in world: World, terrain: GardenTerrain, device: RenderDevice) throws {
    let stone = PBRMaterial()
    stone.baseColorFactor = [0.39, 0.38, 0.31, 1]
    stone.roughnessFactor = 0.85
    stone.metallicFactor = 0
    let wood = PBRMaterial()
    wood.baseColorFactor = [0.32, 0.16, 0.065, 1]
    wood.roughnessFactor = 0.8
    wood.metallicFactor = 0
    // Ascending platforms are sized for the existing 1.2m jump, with a walkway to the hill.
    for index in 0..<5 {
        let x = 7.3 + Float(index) * 1.55
        let z: Float = 4
        let base = terrain.surfaceHeight(x: x, z: z)
        let height = 0.35 + Float(index) * 0.24
        gardenBlock(in: world, name: "Jump terrace", position: [x, base + height / 2, z], size: [1.25, height, 2.4], material: stone, device: device)
    }
    let hill = Vector3(12, terrain.surfaceHeight(x: 12, z: 11), 11)
    gardenBlock(in: world, name: "Hill lookout deck", position: hill + [0, 0.18, 0], size: [4, 0.36, 3], material: wood, device: device)
    for x: Float in [-1.8, 1.8] {
        for z: Float in [-1.25, 1.25] {
            gardenBlock(in: world, name: "Lookout pillar", position: hill + [x, 1.9, z], size: [0.18, 3.6, 0.18], material: wood, device: device)
        }
    }
    gardenBlock(in: world, name: "Lookout canopy", position: hill + [0, 3.8, 0], size: [4.5, 0.18, 3.5], material: wood, device: device)
    // A covered passage gives the orbit camera a real occluder to sweep against.
    for x: Float in [-1.5, 1.5] {
        gardenBlock(in: world, name: "Garden gateway", position: [x, 1.9, 6], size: [0.42, 3.8, 0.42], material: stone, device: device)
    }
    gardenBlock(in: world, name: "Gateway lintel", position: [0, 3.9, 6], size: [3.8, 0.4, 0.7], material: stone, device: device)
    let bench = try landscapeModel("Bench")
    let plant = try landscapeModel("Plant")
    for (x, z): (Float, Float) in [(-13, 10), (10, -12), (-8, -6.5)] {
        let y = terrain.surfaceHeight(x: x, z: z)
        let root = bench.instantiate(in: world)
        root.components[Transform.self] = Transform(position: [x, y, z])
        gardenBlock(in: world, name: "Outer bench collider", position: [x, y + 0.6, z], size: [1.8, 1.2, 0.55], material: nil, device: device)
        let pot = plant.instantiate(in: world)
        let potY = terrain.surfaceHeight(x: x + 1.7, z: z)
        pot.components[Transform.self] = Transform(position: [x + 1.7, potY, z])
        gardenBlock(in: world, name: "Outer planter collider", position: [x + 1.7, potY + 0.6, z], size: [0.7, 1.2, 0.7], material: nil, device: device)
    }
    let water = PBRMaterial()
    water.baseColorFactor = [0.075, 0.25, 0.3, 1]
    water.roughnessFactor = 0.16
    water.metallicFactor = 0.3
    world.spawn("Shallow garden pond") {
        Mesh3DComponent(mesh: .generatePlane(size: [3.2, 2.6], renderDevice: device), materials: [water])
        Transform(position: [-11, -0.55, -10])
    }
}

@MainActor
private func gardenBlock(in world: World, name: String, position: Vector3, size: Vector3, material: PBRMaterial?, device: RenderDevice) {
    let root = world.spawn(name) {
        PhysicsBody3DComponent(shapes: [.generateBox(width: size.x, height: size.y, depth: size.z)], mode: .static)
        Transform(position: position)
    }
    if let material {
        root.components[Mesh3DComponent.self] = Mesh3DComponent(mesh: .generateCube(size: size, renderDevice: device), materials: [material])
    }
}
