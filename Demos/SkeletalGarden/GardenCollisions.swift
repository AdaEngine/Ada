import AdaEngine

@MainActor
func makeGardenCollisions(in world: World) {
    // Collision sizes are world-space proxies for the authored props, including their demo scale.
    let boxes: [(String, Vector3, Vector3)] = [
        ("Courtyard floor", [0, -0.1, 0], [12, 0.2, 12]),
        ("Crate", [-2.3, 0.4, -0.8], [0.93, 0.86, 0.92]),
        ("Small crate", [2.4, 0.32, -1.5], [0.744, 0.688, 0.736]),
        ("Bench seat", [-2.8, 0.55, 2.5], [1.8, 0.13, 0.55]),
        ("Bench back", [-2.8, 0.92, 2.28], [1.8, 0.55, 0.12]),
        ("Bench leg", [-3.45, 0.25, 2.5], [0.15, 0.5, 0.4]),
        ("Bench leg", [-2.15, 0.25, 2.5], [0.15, 0.5, 0.4]),
        ("Pedestal", [3.1, 0.48, 0.5], [0.9, 0.96, 0.9]),
        ("Lantern", [3.1, 1.39, 0.5], [0.48, 0.78, 0.48]),
        ("Reference robot", [1.5, 0.83, 1.8], [0.85, 1.66, 0.7]),
    ]
    for (name, position, size) in boxes {
        world.spawn("\(name) collider") {
            PhysicsBody3DComponent(shapes: [.generateBox(width: size.x, height: size.y, depth: size.z)], mode: .static)
            Transform(position: position)
        }
    }
    let spheres: [(String, Vector3, Float)] = [
        ("Chrome sphere", [2.3, 0.35, -0.15], 0.35),
        ("Plant pot", [-3.2, 0.3, -2.2], 0.384),
        ("Plant pot", [2.8, 0.275, 2.4], 0.352),
    ]
    for (name, position, radius) in spheres {
        world.spawn("\(name) collider") {
            PhysicsBody3DComponent(shapes: [.generateSphere(radius: radius)], mode: .static)
            Transform(position: position)
        }
    }
}
