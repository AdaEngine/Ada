@testable import AdaApp
import AdaECS
import AdaInput
@testable import AdaRender
import AdaScene
import AdaScripting
@testable import AdaUI
import Foundation
import Math
import Testing

@MainActor @Suite(.serialized)
struct ScriptUIBindingTests {
    init() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
    }

    @Test func scriptUpdatesMountedTextAndTextFieldWritesBack() async throws {
        let identifier = try registerScript()
        let script = try ScriptableObjectRegistry.make(named: identifier)
        let world = World(name: "UI bindings")
        let app = AppWorlds(main: world)
        InputPlugin().setup(in: app)
        ScriptableObjectPlugin().setup(in: app)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = UISceneDocument(root: .init(type: "VStack", children: [
            .init(type: "Text", arguments: ["text": .init(binding: "title")]),
            .init(type: "TextField", arguments: ["text": .init(binding: "title")])
        ]), inputs: [.init("title", type: .string, defaultValue: .string("Preview"))])
        try document.encodedYAML().write(to: root.appendingPathComponent("HUD.ui"), atomically: true, encoding: .utf8)
        let original = UIComponent(source: .init(path: "HUD.ui", scriptBindings: ["title": .init(script: identifier, field: "title")]))
        // Exercise the persisted component, not just an in-memory mapping.
        let ui = try JSONDecoder().decode(UIComponent.self, from: JSONEncoder().encode(original))
        let entity = world.spawn { ScriptableComponents(scripts: [script]); ui }
        await world.runScheduler(.update)
        let container = try #require(try ui.resolveView(runtime: UIComponentRuntime(resourceRoot: root)) as? UIContainerView<AnyView>)
        container.frame = Rect(x: 0, y: 0, width: 320, height: 180)
        container.layoutSubviews()
        #expect(texts(in: container.viewTree.rootNode).contains("Ready!"))
        await world.runScheduler(.update)
        try await settle(container)
        #expect(texts(in: container.viewTree.rootNode).contains("Ready!!"))

        let input = try #require(textField(in: container.viewTree.rootNode)?.content as? TextField)
        input.text.wrappedValue = "Typed"
        #expect(script.readExportedField("title") == .string("Ready!!"))
        await world.runScheduler(.update)
        #expect(script.readExportedField("title") == .string("Typed"))
        await world.runScheduler(.update)
        try await settle(container)
        #expect(texts(in: container.viewTree.rootNode).contains("Typed!"))

        let context = try #require(ui.scriptBindingContext)
        #expect(context.diagnostics.isEmpty)
        world.remove(ScriptableComponents.self, from: entity.id)
        await world.runScheduler(.update)
        #expect(context.value("title") == .null)
        #expect(context.diagnostics.contains { $0.message.contains("found 0") })
    }

    @Test func instancesAreIsolatedAndReplacementDropsQueuedEdits() async throws {
        let identifier = try registerScript()
        let world = World(name: "Isolated UI bindings")
        let app = AppWorlds(main: world)
        InputPlugin().setup(in: app)
        ScriptableObjectPlugin().setup(in: app)
        func component() -> UIComponent {
            UIComponent(source: .init(scriptBindings: ["title": .init(script: identifier, field: "title")]))
        }
        let first = component(), second = component()
        let firstScript = try ScriptableObjectRegistry.make(named: identifier)
        let secondScript = try ScriptableObjectRegistry.make(named: identifier)
        let entity = world.spawn { first; ScriptableComponents(scripts: [firstScript]) }
        world.spawn { second; ScriptableComponents(scripts: [secondScript]) }
        await world.runScheduler(.update)
        first.scriptBindingContext?.set("title", to: .string("Edit"))
        await world.runScheduler(.update)
        #expect(firstScript.readExportedField("title") == .string("Edit"))
        #expect(secondScript.readExportedField("title") == .string("Ready!!"))
        first.scriptBindingContext?.set("title", to: .string("Stale edit"))
        let replacement = try ScriptableObjectRegistry.make(named: identifier)
        world.insert(ScriptableComponents(scripts: [replacement]), for: entity.id)
        await world.runScheduler(.update)
        #expect(replacement.readExportedField("title") == .string("Ready!"))
        #expect(first.scriptBindingContext?.value("title") == .string("Ready!"))
    }

    @Test func rejectsUnexportedFieldsAndIncompatibleWrites() async throws {
        let identifier = try registerScript()
        let script = try ScriptableObjectRegistry.make(named: identifier)
        #expect(script.readExportedField("secret") == nil)
        #expect(!script.writeExportedField("secret", value: .string("Changed")))
        #expect(!script.writeExportedField("title", value: .bool(true)))
        let world = World(name: "Invalid UI mapping")
        let app = AppWorlds(main: world)
        InputPlugin().setup(in: app)
        ScriptableObjectPlugin().setup(in: app)
        let ui = UIComponent(source: .init(scriptBindings: ["title": .init(script: identifier, field: "secret")]))
        world.spawn { ui; ScriptableComponents(scripts: [script]) }
        await world.runScheduler(.update)
        await world.runScheduler(.update)
        #expect(ui.scriptBindingContext?.diagnostics.count == 1)
        #expect(ui.scriptBindingContext?.diagnostics.first?.message.contains("not exported") == true)
        let legacy = try JSONDecoder().decode(UIComponentSource.self, from: Data("{\"kind\":\"ui\",\"path\":\"HUD.ui\",\"identifier\":\"\",\"contextName\":\"\",\"inputs\":{}}".utf8))
        #expect(legacy.scriptBindings.isEmpty)
    }

    private func registerScript() throws -> String {
        let identifier = "test.hud." + UUID().uuidString
        try AdaScriptObjectRegistration.register(schemas: [
            .init(identifier: identifier, className: "HUD", version: 1, aliases: [], fields: ["title": .string("Initial")])
        ], sources: [.init(path: "HUD.ada", source: """
        @scriptable(id: "\(identifier)")
        class HUD {
            @export var title = "Initial";
            var secret = "Hidden";
            func ready(context) { title = "Ready"; }
            func update(context) { title = title + "!"; }
        }
        """)], moduleName: identifier)
        return identifier
    }

    private func texts(in node: ViewNode) -> [String] {
        let own = (node.content as? Text).map { [$0.plainText] } ?? []
        return own + node.transientEnvironmentChildren.flatMap { texts(in: $0) }
    }

    private func textField(in node: ViewNode) -> ViewNode? {
        if node.content is TextField { return node }
        return node.transientEnvironmentChildren.lazy.compactMap { textField(in: $0) }.first
    }

    private func settle(_ container: UIContainerView<AnyView>) async throws {
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(10))
            container.layoutSubviews()
        }
    }
}
