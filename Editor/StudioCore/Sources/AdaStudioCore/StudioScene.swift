import Foundation
import Yams

/// Lossless scene editing: retain component and editor fields the web inspector does not expose.
public struct StudioScene: Sendable {
    public var value: StudioValue
    public init(data: Data) throws {
        value = try YAMLDecoder().decode(StudioValue.self, from: String(decoding: data, as: UTF8.self))
        guard value["format"].string == "ada.scene", value["schemaVersion"].number == 1 else { throw StudioError.invalid("Неподдерживаемый формат сцены.") }
        try validateHierarchy()
    }
    public init(value: StudioValue) { self.value = value }
    public var entities: [StudioValue] { value["entities"].array }
    public func encoded() throws -> Data { try value.encoded() } // JSON is also valid YAML.

    public func validateHierarchy() throws {
        let ids = entities.compactMap { $0["id"].string }
        guard ids.count == entities.count, Set(ids).count == ids.count else { throw StudioError.invalid("Повторяющийся ID объекта сцены.") }
        let parents = Dictionary(uniqueKeysWithValues: entities.compactMap { entity -> (String, String)? in
            guard let id = entity["id"].string, let parent = entity["parent"].string else { return nil }
            return (id, parent)
        })
        for id in ids {
            var visited = Set([id]), node = id
            while let parent = parents[node] {
                guard ids.contains(parent), visited.insert(parent).inserted else { throw StudioError.invalid("Некорректная иерархия сцены.") }
                node = parent
            }
        }
    }

    public mutating func set(entity id: String, component: String, field: String, value newValue: StudioValue) throws {
        var items = entities
        guard let index = items.firstIndex(where: { $0["id"].string == id }) else { throw StudioError.invalid("Объект не найден.") }
        items[index]["components"][component][field] = newValue
        value["entities"] = .array(items)
    }
    public mutating func add(name: String, components: [String: StudioValue], parent: String? = nil) throws -> String {
        let id = UUID().uuidString.lowercased()
        var items = entities
        items.append(.object(["id": .string(id), "name": .string(name), "enabled": .bool(true), "parent": parent.map(StudioValue.string) ?? .null,
                              "components": .object(components)]))
        value["entities"] = .array(items)
        try validateHierarchy()
        return id
    }
    public mutating func remove(_ id: String) {
        var removed = Set([id])
        while true {
            let children = entities.filter { removed.contains($0["parent"].string ?? "") }.compactMap { $0["id"].string }
            let before = removed.count; removed.formUnion(children)
            if removed.count == before { break }
        }
        value["entities"] = .array(entities.filter { !removed.contains($0["id"].string ?? "") })
    }
}

public enum StudioRuntimeCapabilities {
    /// These describe different protocols, not interchangeable version numbers.
    public static let webPlayerAPI = 4
    public static let communityPackageAPI = 2
    public static let components: Set<String> = [
        "AdaTransform.Transform", "AdaRender.Visibility", "AdaRender.Camera", "AdaSprite.Sprite",
        "AdaTilemap.TileMapComponent", "AdaSprite.Mesh2D", "AdaScene.Mesh3DComponent", "AdaScene.Model3DSource",
        "AdaScene.DirectionalLightComponent", "AdaScene.PointLightComponent", "AdaRender.Environment3D",
        "AdaPhysics.PhysicsBody2DComponent", "AdaAudio.AudioSource"
    ]
}
