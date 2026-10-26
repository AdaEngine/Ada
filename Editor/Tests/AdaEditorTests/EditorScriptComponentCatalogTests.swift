import AdaEngine
import AdaScriptCompilerCore
import Foundation
import Testing
@testable import AdaEditor

@Suite("Editor script component catalog", .serialized)
struct EditorScriptComponentCatalogTests {
    private static let source = """
        enum Mode { idle, moving }

        @component(id: "game.body", aliases: ["OldBody"])
        struct Body {
            @export var count: Int = 2;
            @export var position: Vector3 = Vector3(1, 2, 3);
            @export var mode: Mode = Mode.idle;
            @export var tint: Color = Color.white;
            @export var icon: Asset = null;
        }

        @resource(id: "game.settings")
        struct Settings { @export var volume: Float = 1.0; }
        """

    private func components() throws -> [EditorScriptDataComponent] {
        EditorScriptComponentCatalog.makeComponents(from: try AdaScriptSchemaParser.parse(sources: [
            AdaScriptCompilerSource(path: "Body.ada", source: Self.source)
        ]))
    }

    @Test("A schema becomes an inspector descriptor with typed fields and defaults, resources are excluded")
    func descriptorFromSchema() throws {
        let components = try components()
        #expect(components.map(\.schema.name) == ["Body"])
        let descriptor = try #require(components.first?.descriptor)
        #expect(descriptor.typeName == "game.body")
        #expect(descriptor.category == "Script")
        #expect(descriptor.fields.map(\.kind) == [.int, .vector3, .enumeration(["idle", "moving"]), .color, .assetReference])
        let defaults = descriptor.makeDefaultPayload()
        #expect(defaults["count"] == .int(2))
        #expect(defaults["position"] == .array([.double(1), .double(2), .double(3)]))
        #expect(defaults["mode"] == .string("idle"))
        #expect(defaults["icon"] == .null)
    }

    @Test("The registry resolves a script component by stable ID, name, and alias, and decodes validated payloads")
    func registryIntegration() throws {
        let store = EditorScriptComponentStore.shared
        store.replace(with: try components())
        defer { store.replace(with: []) }

        for key in ["game.body", "Body", "OldBody"] {
            #expect(EditorComponentRegistry.descriptor(named: key)?.typeName == "game.body")
        }
        #expect(EditorComponentRegistry.descriptors.contains { $0.typeName == "game.body" })
        #expect(EditorComponentRegistry.defaultPayload(for: "OldBody")["count"] == .int(2))

        let component = try #require(
            EditorComponentRegistry.decode(
                typeName: "OldBody",
                payload: ["count": .int(9), "mode": .string("moving"), "position": .array([.int(4), .int(5), .int(6)])]
            ) as? RuntimeComponentPayload
        )
        #expect(component.values[0] == .int(9))
        #expect(component.values[1] == .array([.double(4), .double(5), .double(6)]))
        #expect(component.values[2] == .string("moving"))

        #expect(throws: DecodingError.self) { try EditorComponentRegistry.decode(typeName: "game.body", payload: ["mode": .string("flying")]) }
        #expect(throws: DecodingError.self) { try EditorComponentRegistry.decode(typeName: "game.body", payload: ["position": .array([.double(1)])]) }
    }

    @Test("A saved scene loads script components into the runtime world, including through a former name")
    @MainActor
    func sceneLoadsScriptComponents() throws {
        let store = EditorScriptComponentStore.shared
        let components = try components()
        store.replace(with: components)
        defer { store.replace(with: []) }

        var model = EditorSceneModel.default(projectName: "ScriptData")
        let first = EditorSceneEntity(id: "a", name: "A", enabled: true, parent: nil, components: ["game.body": ["count": .int(7)]])
        let second = EditorSceneEntity(id: "b", name: "B", enabled: true, parent: nil, components: ["OldBody": ["mode": .string("moving")]])
        model.entities = [first, second]

        let world = World(name: "ScriptDataScene")
        let result = EditorSceneFileLoader.load(model: model, into: world)
        let runtimeID = try #require(components.first?.runtime.componentID)
        let a = try #require(result.entitiesByEditorID["a"])
        let b = try #require(result.entitiesByEditorID["b"])

        // Only the scene that still uses the former name is flagged; fields added since are not noise.
        #expect(result.warnings.count == 1)
        #expect(result.warnings.first?.contains("store the stable ID 'game.body'") == true)
        #expect(world.getRuntimeComponent(runtimeID, from: a)?.values.first == .int(7))
        #expect(world.getRuntimeComponent(runtimeID, from: b)?.values[2] == .string("moving"))
    }

    @Test("Integer JSON numbers instantiate floating-point scene fields")
    @MainActor
    func integralNumbersLoadFloatingPointFields() throws {
        try withNumericComponents { components in
            try assertNumericScene(Self.numericScene, components: components)
            let inventory = try #require(components.first { $0.schema.id == "test.inventory" })
            for invalid: EditorSceneValue in [.bool(true), .string("5"), .double(.nan), .double(.infinity)] {
                #expect(throws: DecodingError.self) {
                    try EditorScriptComponentCatalog.decode(["mass": invalid], as: inventory.runtime)
                }
            }
        }
    }

    @Test("Save and reopen preserve runtime fields through YAML and canonical JSON")
    @MainActor
    func numericSceneSaveReopen() throws {
        try withNumericComponents { components in
            var model = try EditorSceneModel.decode(from: Self.numericScene)
            model.entities[0].components["test.health"]?["current"] = .double(100)
            model.entities[0].components["test.inventory"]?["mass"] = .double(5)
            model.entities[0].components["test.extraction"]?["closeAt"] = .double(1080)
            model.entities[0].components["test.extraction"]?["holdSeconds"] = .double(8)
            let yaml = try model.encodedYAML()
            let json = String(decoding: try JSONEncoder().encode(model), as: UTF8.self)
            let canonical = try EditorSceneModel.decode(from: json)
            #expect(canonical.entities[0].components["test.extraction"]?["closeAt"] == .int(1080))
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("EditorNumericScene-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            for (index, content) in [yaml, json].enumerated() {
                let file = root.appendingPathComponent("Reopened-\(index).ascn")
                try content.write(to: file, atomically: true, encoding: .utf8)
                try assertNumericScene(String(contentsOf: file, encoding: .utf8), components: components)
            }
        }
    }

    private static let numericScene = """
        {"format":"ada.scene","schemaVersion":1,"scene":{"id":"numbers","name":"Numbers"},"entities":[
            {"id":"survivor","name":"Survivor","enabled":true,"components":{
                "test.health":{"current":100},"test.inventory":{"mass":5},
                "test.extraction":{"closeAt":1080,"holdSeconds":8}
            }}
        ]}
        """

    @MainActor
    private func withNumericComponents(_ operation: ([EditorScriptDataComponent]) throws -> Void) throws {
        let sources = [AdaScriptCompilerSource(path: "NumericComponents.ada", source: """
            @component(id: "test.health")
            struct Health { @export var current = 100.0; }
            @component(id: "test.inventory")
            struct Inventory { @export var mass = 0.0; }
            @component(id: "test.extraction")
            struct Extraction { @export var closeAt = 1080.0; @export var holdSeconds = 8.0; }
            """)]
        let components = EditorScriptComponentCatalog.makeComponents(from: try AdaScriptSchemaParser.parse(sources: sources))
        let store = EditorScriptComponentStore.shared
        let previous = store.components
        store.replace(with: components)
        defer { store.replace(with: previous) }
        try operation(components)
    }

    @MainActor
    private func assertNumericScene(_ content: String, components: [EditorScriptDataComponent]) throws {
        let world = World(name: "Numeric scene roundtrip")
        let result = EditorSceneFileLoader.load(content: content, into: world, loadsScriptableObjects: false)
        #expect(result.warnings.isEmpty, "\(result.warnings)")
        let entity = try #require(result.entitiesByEditorID["survivor"])
        for (id, key, expected) in [("test.health", "current", 100.0), ("test.inventory", "mass", 5.0),
                                    ("test.extraction", "closeAt", 1080.0), ("test.extraction", "holdSeconds", 8.0)] {
            let descriptor = try #require(components.first { $0.schema.id == id }?.runtime)
            let payload = try #require(world.getRuntimeComponent(descriptor.componentID, from: entity))
            let field = try #require(descriptor.fields.first { $0.key == key })
            #expect(field.read(payload) == .double(expected))
        }
    }
}
