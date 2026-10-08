@_spi(AdaEngine) import AdaEngine
import Foundation

enum EditorMeshPrimitive: String, CaseIterable, Sendable {
    case quad = "Quad"
    case circle = "Circle"
    case cube = "Cube"
    case sphere = "Sphere"
    case plane = "Plane"

    func makeMesh(size: Float = 1, renderDevice: RenderDevice) -> Mesh {
        switch self {
        case .quad: Mesh.generate(from: Quad(size: Vector2(size, size)), renderDevice: renderDevice)
        case .circle: Mesh.generateCircle(radius: size / 2, renderDevice: renderDevice)
        case .cube: Mesh.generateCube(size: Vector3(size, size, size), renderDevice: renderDevice)
        case .sphere: Mesh.generateSphere(radius: size / 2, renderDevice: renderDevice)
        case .plane: Mesh.generatePlane(size: Vector2(size, size), renderDevice: renderDevice)
        }
    }
}

extension EditorComponentRegistry {
    static let mesh2DDescriptor = meshDescriptor(is3D: false)
    static let mesh3DDescriptor = meshDescriptor(is3D: true)

    private static func meshDescriptor(is3D: Bool) -> EditorComponentDescriptor {
        let defaultPrimitive: EditorMeshPrimitive = is3D ? .cube : .quad
        let defaultSize: Double = is3D ? 1 : 64
        let white = EditorSceneValue.object(["red": .double(1), "green": .double(1), "blue": .double(1), "alpha": .double(1)])
        let choices = EditorMeshPrimitive.allCases.filter { is3D || $0 != .plane }.map(\.rawValue)
        var mesh = EditorComponentField(key: "mesh", label: "Mesh", kind: .enumeration(choices))
        mesh.defaultValue = .string(defaultPrimitive.rawValue)
        var size = EditorComponentField(key: "size", label: "Size", kind: .float)
        size.defaultValue = .double(defaultSize)
        size.minimumValue = 0.0001
        var color = EditorComponentField(key: "color", label: "Material Color", kind: .color)
        color.defaultValue = white
        var fields = [mesh, size, color]
        if is3D {
            var metallic = EditorComponentField(key: "metallic", label: "Metallic", kind: .float)
            metallic.defaultValue = .double(0)
            var roughness = EditorComponentField(key: "roughness", label: "Roughness", kind: .float)
            roughness.defaultValue = .double(0.5)
            var castShadows = EditorComponentField(key: "castShadows", label: "Cast Shadows", kind: .bool)
            castShadows.defaultValue = .bool(true)
            var receiveShadows = EditorComponentField(key: "receiveShadows", label: "Receive Shadows", kind: .bool)
            receiveShadows.defaultValue = .bool(true)
            fields += [metallic, roughness, castShadows, receiveShadows]
        }
        return EditorComponentDescriptor(
            typeName: is3D ? EditorBuiltInComponentType.mesh3D : EditorBuiltInComponentType.mesh2D,
            displayName: is3D ? "Mesh 3D" : "Mesh 2D",
            category: is3D ? "3D" : "2D",
            description: "Renders a built-in mesh with an editable material.",
            requiredComponentTypeNames: [EditorBuiltInComponentType.transform, EditorBuiltInComponentType.visibility],
            fields: fields,
            makeDefaultPayload: {
                [
                    "mesh": .string(defaultPrimitive.rawValue), "size": .double(defaultSize), "color": white,
                    "metallic": .double(0), "roughness": .double(0.5), "castShadows": .bool(true), "receiveShadows": .bool(true),
                ]
            },
            decode: { payload in
                try decodeMesh(payload, is3D: is3D, defaultPrimitive: defaultPrimitive, defaultSize: defaultSize, defaultColor: white)
            }
        )
    }

    private static func decodeMesh(
        _ payload: EditorComponentPayload,
        is3D: Bool,
        defaultPrimitive: EditorMeshPrimitive,
        defaultSize: Double,
        defaultColor: EditorSceneValue
    ) throws -> any Component {
        guard let engine = unsafe RenderEngine.shared else {
            throw MeshComponentError.rendererUnavailable
        }
        let primitive = EditorMeshPrimitive(rawValue: payload["mesh"]?.stringValue ?? "") ?? defaultPrimitive
        let size = Float(payload["size"]?.doubleValue ?? defaultSize)
        guard size.isFinite, size > 0 else {
            throw MeshComponentError.invalidSize
        }
        let mesh = primitive.makeMesh(size: size, renderDevice: engine.renderDevice)
        let colorValue = payload["color"] ?? defaultColor
        let color = try JSONDecoder().decode(Color.self, from: JSONEncoder().encode(colorValue))
        if is3D {
            let material = PBRMaterial()
            material.baseColorFactor = Vector4(color.red, color.green, color.blue, color.alpha)
            material.metallicFactor = Float(min(1, max(0, payload["metallic"]?.doubleValue ?? 0)))
            material.roughnessFactor = Float(min(1, max(0, payload["roughness"]?.doubleValue ?? 0.5)))
            return Mesh3DComponent(
                mesh: mesh,
                materials: [material],
                castShadows: payload["castShadows"]?.boolValue ?? true,
                receiveShadows: payload["receiveShadows"]?.boolValue ?? true
            )
        }
        return Mesh2D(mesh: mesh, materials: [CustomMaterial(ColorCanvasMaterial(color: color))])
    }
}

private enum MeshComponentError: LocalizedError {
    case rendererUnavailable
    case invalidSize

    var errorDescription: String? {
        switch self {
        case .rendererUnavailable: "The renderer must be ready before loading a mesh."
        case .invalidSize: "Mesh size must be a finite positive number."
        }
    }
}
