@_spi(AdaEngine) import AdaEngine
import AdaScriptCompilerCore
import AdaStudioCore
import Foundation

/// Prepare every authored component before spawning anything: invalid scenes fail as a unit.
@MainActor enum PlayerSceneComponents {
    static func prepare(scene: PlayerSceneDocument, script: AdaScriptPlugin, project: AdaWebPlayerProject, directory: URL) throws -> [String: [any Component]] {
        var result: [String: [any Component]] = [:]
        let ids = Set(scene.entities.map(\.id))
        guard ids.count == scene.entities.count else { throw invalid("Duplicate scene entity ID") }
        let parents = Dictionary(uniqueKeysWithValues: scene.entities.compactMap { item in item.parent.map { (item.id, $0) } })
        for item in scene.entities {
            var visited = Set([item.id]), cursor = item.id
            while let parent = parents[cursor] {
                guard ids.contains(parent), visited.insert(parent).inserted else { throw invalid("Invalid scene hierarchy") }
                cursor = parent
            }
            var components: [any Component] = []
            for (name, payload) in item.components.raw.sorted(by: { $0.key < $1.key }) {
                let data = try payload.encoded()
                switch name {
                case "AdaTransform.Transform":
                    guard let value = item.components.transform, value.position.count == 3, value.rotation.count == 4, value.scale.count == 3,
                          (value.position + value.rotation + value.scale).allSatisfy(\.isFinite) else { throw invalid("Invalid Transform on \(item.name)") }
                case "AdaRender.Visibility":
                    guard ["visible", "hidden", "inherited"].contains(payload["value"].string ?? "") else { throw invalid("Invalid visibility") }
                case "AdaTilemap.TileMapComponent":
                    guard item.components.tileMap != nil else { throw invalid("Invalid tile map") }
                case "AdaRender.Camera":
                    var camera = Camera()
                    guard let projection = payload["projection"].string, ["orthographic", "perspective"].contains(projection) else { throw invalid("Unsupported camera projection") }
                    camera.projection = projection == "perspective" ? .perspective(PerspectiveProjection()) : .orthographic(OrthographicProjection())
                    camera.isActive = payload["isActive"] != .bool(false)
                    camera.renderOrder = Int(payload["renderOrder"].number ?? 0)
                    if payload["backgroundColor"] != .null { camera.backgroundColor = try decode(Color.self, payload["backgroundColor"]) }
                    components.append(camera)
                case "AdaSprite.Sprite":
                    let texture: AssetHandle<Texture2D>
                    if let source = payload["texture"].string, !source.isEmpty {
                        let url = try resource(source, project: project, directory: directory)
                        texture = AssetHandle(Texture2D(image: try Image(contentsOf: url)))
                    } else { texture = AssetHandle(Texture2D.whiteTexture) }
                    let dimensions = payload["size"]
                    let width = dimensions["width"].number ?? dimensions.array.first?.number
                    let height = dimensions["height"].number ?? dimensions.array.last?.number
                    let size = width.flatMap { width in height.map { Size(width: Float(width), height: Float($0)) } }
                    let tint = payload["tintColor"] == .null ? Color.white : try decode(Color.self, payload["tintColor"])
                    let anchor = payload["anchor"] == .null ? SpriteAnchor.center : try decode(SpriteAnchor.self, payload["anchor"])
                    let mode = payload["imageMode"] == .null ? SpriteImageMode.stretch : try decode(SpriteImageMode.self, payload["imageMode"])
                    components.append(Sprite(texture: texture, tintColor: tint, flipX: payload["flipX"] == .bool(true), flipY: payload["flipY"] == .bool(true), size: size, anchor: anchor, imageMode: mode))
                case "AdaScene.Mesh3DComponent": components.append(try mesh(payload))
                case "AdaScene.Model3DSource":
                    guard let source = payload["source"].string else { throw invalid("Model source is required") }
                    _ = try resource(source, project: project, directory: directory)
                    components.append(Model3DSource(source: source, animation: payload["animation"].string ?? "", autoplay: !PlayerBrowserSession.editMode && payload["autoplay"] == .bool(true), repeats: payload["repeats"] != .bool(false)))
                case "AdaScene.DirectionalLightComponent":
                    let color = payload["radiance"].array.compactMap(\.number)
                    guard color.isEmpty || (color.count == 3 && color.allSatisfy(\.isFinite)) else { throw invalid("Invalid light radiance") }
                    components.append(DirectionalLightComponent(radiance: color.isEmpty ? .one : Vector3(Float(color[0]), Float(color[1]), Float(color[2])),
                        intensity: Float(payload["intensity"].number ?? 1), castShadows: payload["castShadows"] != .bool(false)))
                case "AdaScene.PointLightComponent": components.append(try decode(PointLightComponent.self, payload))
                // The editor writes the native module name for built-in pipeline components.
                case "AdaRender.Environment3D", "AdaCorePipelines.Environment3D": components.append(try decode(Environment3D.self, payload))
                case "AdaScene.ScriptableComponents": components.append(try decode(ScriptableComponents.self, payload))
                case "AdaUI.CompanionPanel": components.append(try decode(CompanionPanel.self, payload))
                case "AdaPhysics.PhysicsBody2DComponent": components.append(try decode(PhysicsBody2DComponent.self, payload))
                case "AdaAudio.AudioSource":
                    guard let source = payload["source"].string else { throw invalid("Audio source is required") }
                    _ = try resource(source, project: project, directory: directory)
                    components.append(AudioSource(source: source, volume: Float(payload["volume"].number ?? 1), loops: payload["loops"] == .bool(true), autoplay: !PlayerBrowserSession.editMode && payload["autoplay"] == .bool(true)))
                default:
                    guard let component = try script.decodeSceneComponent(named: name, data: data) else { throw invalid("Unsupported Web Player component '\(name)' on '\(item.name)'") }
                    components.append(component)
                }
            }
            result[item.id] = components
        }
        return result
    }

    private static func resource(_ source: String, project: AdaWebPlayerProject, directory: URL) throws -> URL {
        let path = source.hasPrefix("@res://") ? "Assets/" + source.dropFirst(7) : source
        return try project.resourceURL(String(path), at: directory)
    }
    private static func decode<T: Decodable>(_ type: T.Type, _ value: StudioValue) throws -> T { try JSONDecoder().decode(type, from: value.encoded()) }
    private static func invalid(_ text: String) -> AdaWebPlayerProjectError { .invalid(text) }

    private static func mesh(_ payload: StudioValue) throws -> Mesh3DComponent {
        guard let engine = unsafe RenderEngine.shared else { throw invalid("Renderer unavailable") }
        let size = Float(payload["size"].number ?? 1)
        guard size.isFinite, size > 0, size <= 100_000 else { throw invalid("Mesh size must be finite and positive") }
        let device = engine.renderDevice, mesh: Mesh
        switch payload["mesh"].string ?? "Cube" {
        case "Cube": mesh = Mesh.generateCube(size: Vector3(size, size, size), renderDevice: device)
        case "Sphere": mesh = Mesh.generateSphere(radius: size / 2, renderDevice: device)
        case "Plane": mesh = Mesh.generatePlane(size: Vector2(size, size), renderDevice: device)
        case "Quad": mesh = Mesh.generate(from: Quad(size: Vector2(size, size)), renderDevice: device)
        case "Circle": mesh = Mesh.generateCircle(radius: size / 2, renderDevice: device)
        default: throw invalid("Unsupported mesh primitive")
        }
        let color = payload["color"] == .null ? Color.white : try decode(Color.self, payload["color"])
        let material = PBRMaterial()
        material.baseColorFactor = Vector4(color.red, color.green, color.blue, color.alpha)
        material.metallicFactor = Float(min(1, max(0, payload["metallic"].number ?? 0)))
        material.roughnessFactor = Float(min(1, max(0, payload["roughness"].number ?? 0.6)))
        return Mesh3DComponent(mesh: mesh, materials: [material], castShadows: payload["castShadows"] != .bool(false), receiveShadows: payload["receiveShadows"] != .bool(false))
    }
}
