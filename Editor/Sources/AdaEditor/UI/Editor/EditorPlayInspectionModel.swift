@_spi(AdaEngine) import AdaEngine
import Foundation
import Observation

@MainActor
@Observable
final class EditorPlayInspectionModel {
    struct Item: Equatable, Identifiable {
        let id: Entity.ID
        let name: String
    }

    struct ComponentValue: Equatable {
        let name: String
        let value: String
    }

    struct Snapshot: Equatable {
        let id: Entity.ID
        let name: String
        let components: [ComponentValue]
    }

    private(set) var items: [Item] = []
    private(set) var selectedID: Entity.ID?
    private(set) var selection: Snapshot?

    @ObservationIgnored private weak var world: World?
    @ObservationIgnored private var lastRefresh = 0.0

    func select(_ id: Entity.ID?) {
        selectedID = id
        refresh(force: true)
    }

    func attach(_ world: World) {
        self.world = world
        refresh(force: true)
    }

    func reset() {
        world = nil
        items = []
        selectedID = nil
        selection = nil
        lastRefresh = 0
    }

    func refresh(force: Bool = false) {
        guard let world else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastRefresh >= 0.2 else { return }
        lastRefresh = now

        var currentItems: [Item] = []
        for entity in world.getEntities() where entity.name != "SceneView_Camera" {
            currentItems.append(Item(id: entity.id, name: entity.name))
        }
        currentItems.sort { lhs, rhs in
            if lhs.name == rhs.name { return lhs.id < rhs.id }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        if items != currentItems { items = currentItems }

        guard let selectedID, let item = currentItems.first(where: { $0.id == selectedID }) else {
            if selectedID != nil { self.selectedID = nil }
            if selection != nil { selection = nil }
            return
        }
        var components: [ComponentValue] = []
        for entry in world.getComponents(for: selectedID) {
            let name = entry.typeName.split(separator: ".").last.map(String.init) ?? entry.typeName
            components.append(ComponentValue(name: name, value: Self.summary(of: entry.component, typeName: entry.typeName)))
        }
        components.sort { $0.name < $1.name }
        let snapshot = Snapshot(id: item.id, name: item.name, components: components)
        if selection != snapshot { selection = snapshot }
    }

    private static func summary(of component: any Component, typeName: String) -> String {
        if let transform = component as? Transform {
            let position = transform.position
            let rotation = transform.rotation
            let scale = transform.scale
            return "Position: \(position.x), \(position.y), \(position.z)"
                + " · Rotation: \(rotation.x), \(rotation.y), \(rotation.z), \(rotation.w)"
                + " · Scale: \(scale.x), \(scale.y), \(scale.z)"
        }
        if let tileMap = component as? TileMapComponent {
            return "Layers: \(tileMap.tileMap.layers.count) · Tile size: \(tileMap.tileDisplaySize.width) × \(tileMap.tileDisplaySize.height)"
        }
        if let descriptor = ComponentReflectionRegistry.descriptor(named: typeName) {
            let payload = descriptor.readPayload(from: component)
            let fields = descriptor.fields.prefix(6).map { field in
                "\(field.label): \(Self.reflectedValue(payload[field.key] ?? .null))"
            }
            if !fields.isEmpty { return fields.joined(separator: " · ") }
        }
        let value = String(describing: component)
        return value.count > 160 ? String(value.prefix(159)) + "…" : value
    }

    private static func reflectedValue(_ value: ReflectedFieldValue) -> String {
        switch value {
        case .null: "—"
        case let .bool(value): value ? "true" : "false"
        case let .int(value): String(value)
        case let .double(value): String(value)
        case let .string(value): value
        case let .array(values): values.prefix(4).map(reflectedValue).joined(separator: ", ")
        case let .object(values): values.sorted { $0.key < $1.key }.prefix(4).map { "\($0.key): \(reflectedValue($0.value))" }.joined(separator: ", ")
        }
    }
}
