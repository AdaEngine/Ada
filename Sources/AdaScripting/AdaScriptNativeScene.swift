#if canImport(GravityAOT)
import AdaAnimation
import AdaAssets
@_spi(Scripting) import AdaECS
import AdaRender
import AdaScene
import AdaTilemap
import AdaTransform
import AdaUtils
import Foundation

/// Editor-exported scenes contain ordinary Codable component payloads. Native
/// component fields are decoded against the module's world-local descriptors.
public struct AdaScriptNativeSceneDocument: Codable, Sendable {
    public struct Item: Codable, Sendable {
        public let id: String
        public let name: String
        public let enabled: Bool
        public let parent: String?
        public let components: [String: Data]
        public let animationClips: [Data]?
        public init(id: String, name: String, enabled: Bool, parent: String?, components: [String: Data], animationClips: [Data] = []) {
            self.id = id
            self.name = name
            self.enabled = enabled
            self.parent = parent
            self.components = components
            self.animationClips = animationClips.isEmpty ? nil : animationClips
        }
    }
    public let name: String
    public let entities: [Item]
    public init(name: String, entities: [Item]) {
        self.name = name
        self.entities = entities
    }

    @MainActor
    public func makeScene(components native: [RuntimeComponentDescriptor], resourceRoot: URL? = nil, sourceURL: URL? = nil, tileMaps: [String: TileMap] = [:]) throws -> Scene {
        let items = try expandedEntities(resourceRoot: resourceRoot, sourceURL: sourceURL, ancestors: sourceURL.map { Set([$0.standardizedFileURL]) } ?? [])
        let scene = Scene(name: name)
        for descriptor in native { scene.world.registerRuntimeComponent(descriptor) }
        var entities: [String: Entity] = [:]
        for item in items {
            guard entities[item.id] == nil else { throw AdaScriptError.invalidManifest("Duplicate exported scene entity '\(item.id)'") }
            let entity = scene.world.spawn(item.name)
            entity.isActive = item.enabled
            entities[item.id] = entity
            for (name, data) in item.components {
                if name == String(reflecting: Camera.self) {
                    entity.components += try JSONDecoder().decode(SceneCameraSettings.self, from: data).makeCamera()
                } else if name == String(reflecting: TileMapComponent.self) {
                    let reference = try JSONDecoder().decode(AdaScriptNativeTileMapReference.self, from: data)
                    let path: String
                    if reference.path.hasPrefix("@res://") {
                        path = reference.path
                    } else if let resourceRoot {
                        let url = URL(fileURLWithPath: reference.path, relativeTo: sourceURL?.deletingLastPathComponent() ?? resourceRoot).standardizedFileURL
                        guard url.path.hasPrefix(resourceRoot.path + "/") else { throw AdaScriptError.invalidManifest("Invalid exported tile map path") }
                        path = "@res://" + String(url.path.dropFirst(resourceRoot.path.count + 1))
                    } else {
                        path = reference.path
                    }
                    guard let map = tileMaps[path] else { throw AdaScriptError.invalidManifest("Tile map '\(path)' was not preloaded") }
                    entity.components += TileMapComponent(tileMap: map, tileDisplaySize: Size(width: reference.width, height: reference.height))
                } else if let descriptor = native.first(where: { $0.name == name || $0.stableID == name }) {
                    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        throw AdaScriptError.invalidManifest("Invalid native scene component '\(name)'")
                    }
                    let values = try descriptor.fields.enumerated().map { index, field in
                        guard let value = object[field.key] else {
                            return descriptor.defaultValues[index]
                        }
                        switch descriptor.defaultValues[index] {
                        case .bool:
                            guard let v = value as? Bool else { throw AdaScriptError.invalidManifest("Invalid Bool '\(field.key)'") }
                            return ReflectedFieldValue.bool(v)
                        case .int:
                            guard let v = value as? Int else { throw AdaScriptError.invalidManifest("Invalid Int '\(field.key)'") }
                            return ReflectedFieldValue.int(v)
                        case .double:
                            guard let v = value as? Double else { throw AdaScriptError.invalidManifest("Invalid Float '\(field.key)'") }
                            return ReflectedFieldValue.double(v)
                        case .string:
                            guard let v = value as? String else { throw AdaScriptError.invalidManifest("Invalid String '\(field.key)'") }
                            return ReflectedFieldValue.string(v)
                        default: throw AdaScriptError.invalidManifest("Unsupported native scene field '\(field.key)'")
                        }
                    }
                    entity.components += RuntimeComponentPayload(componentID: descriptor.componentID, stableID: descriptor.stableID, values: values)
                } else {
                    guard let type = RuntimeTypeRegistry.componentType(named: name) as? any Decodable.Type else {
                        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object.isEmpty,
                            let marker = RuntimeTypeRegistry.makeDefaultComponent(named: name) {
                            entity.components += marker
                            continue
                        }
                        throw AdaScriptError.invalidManifest("Unregistered scene component '\(name)'")
                    }
                    let decoder = JSONDecoder()
                    decoder.userInfo[DecodedComponent.typeKey] = ImmutableComponentType(type: type)
                    let value = try decoder.decode(DecodedComponent.self, from: data)
                    guard let component = value.value as? any Component else { throw AdaScriptError.invalidManifest("Invalid scene component '\(name)'") }
                    entity.components += component
                }
            }
        }
        for item in items where item.animationClips?.isEmpty == false {
            guard let entity = entities[item.id], scene.world.get(Transform.self, from: entity.id) != nil else {
                throw AdaScriptError.invalidManifest("Animated entity '\(item.id)' requires Transform")
            }
            let clips = try (item.animationClips ?? []).map {
                AnyAnimatorClip(try KeyframeClip<SceneTransformAnimationValues>(jsonData: $0, schema: SceneTransformAnimationValues.clipSchema))
            }
            guard Set(clips.map(\.name)).count == clips.count else {
                throw AdaScriptError.invalidManifest("Duplicate native animation clip name on '\(item.id)'")
            }
            scene.world.insert(KeyframeAnimator(clips: clips, isPlaying: true), for: entity.id)
        }
        for entity in entities.values { SceneRuntimeBootstrap.prepareCamera(on: entity, in: scene.world) }
        for item in items {
            if let parentID = item.parent {
                guard let parent = entities[parentID], let child = entities[item.id] else {
                    throw AdaScriptError.invalidManifest("Missing exported scene parent '\(parentID)'")
                }
                parent.addChild(child)
            }
        }
        return scene
    }
    @MainActor
    private func expandedEntities(resourceRoot: URL?, sourceURL: URL?, ancestors: Set<URL>) throws -> [Item] {
        var result = entities
        for item in entities {
            guard let data = item.components[String(reflecting: SceneInstance.self)] else { continue }
            let instance = try JSONDecoder().decode(SceneInstance.self, from: data)
            guard !instance.scene.isEmpty else { continue }
            guard let resourceRoot else { throw AdaScriptError.invalidManifest("Nested native scenes require an asset root") }
            let base = sourceURL?.deletingLastPathComponent() ?? resourceRoot
            let reference = instance.scene
            let url =
                (reference.hasPrefix("@res://")
                ? resourceRoot.appendingPathComponent(String(reference.dropFirst(7)))
                : URL(fileURLWithPath: reference, relativeTo: base)).resolvingSymlinksInPath().standardizedFileURL
            guard url.path.hasPrefix(resourceRoot.resolvingSymlinksInPath().path + "/"), !ancestors.contains(url), ancestors.count < 64 else {
                throw AdaScriptError.invalidManifest("Invalid or cyclic native scene reference '\(reference)'")
            }
            let document = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            let nested = try document.expandedEntities(resourceRoot: resourceRoot, sourceURL: url, ancestors: ancestors.union([url]))
            result += nested.map { child in
                Item(
                    id: item.id + "/" + child.id,
                    name: child.name,
                    enabled: child.enabled,
                    parent: child.parent.map { item.id + "/" + $0 } ?? item.id,
                    components: child.components,
                    animationClips: child.animationClips ?? []
                )
            }
        }
        return result
    }
}

/// A tile map is an asset with asynchronous dependencies; scenes retain its
/// resource reference and bind the handle preloaded by the native plugin.
public struct AdaScriptNativeTileMapReference: Codable, Sendable {
    public let path: String
    public let width: Float
    public let height: Float
    public init(path: String, width: Float, height: Float) {
        self.path = path
        self.width = width
        self.height = height
    }
}

/// Metatype identity is immutable runtime metadata; no mutable instance crosses an actor.
private struct ImmutableComponentType: @unchecked Sendable {
    let type: any Decodable.Type
}

private struct DecodedComponent: Decodable {
    static let typeKey = CodingUserInfoKey(rawValue: "AdaScript.NativeScene.Component").unwrap()
    let value: Any
    init(from decoder: any Decoder) throws {
        guard let type = decoder.userInfo[Self.typeKey] as? ImmutableComponentType else {
            throw AdaScriptError.invalidManifest("Missing native scene component type")
        }
        value = try type.type.init(from: decoder)
    }
}
#endif
