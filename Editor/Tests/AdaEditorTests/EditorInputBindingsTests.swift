@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaInput
@_spi(Internal) import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

@MainActor @Suite(.serialized)
struct EditorInputBindingsTests {
    @Test func projectSettingsSaveReloadAndValidateActions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InputSettings-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = ProjectSystem.defaultProject(projectName: "Game", buildSystem: .adaScript)
        try ProjectSystem.saveProject(project, at: root)
        let editor = EditorViewModel(project: EditorProjectReference(name: "Game", path: root.path))
        let settings = EditorSettingsWindowViewModel(editorViewModel: editor, selectedSection: .project)
        settings.inputBindingsDraft.addAction()
        let id = try #require(settings.inputBindingsDraft.actions.first?.id)
        settings.inputBindingsDraft.edit(id) { $0.name = "Jump" }
        for binding in [InputBinding.key(.space), .mouseButton(.left), .gamepadButton(.a), .touch] {
            settings.inputBindingsDraft.addBinding(binding, to: id)
        }
        settings.saveProjectSettings()
        let saved = try ProjectSystem.loadProject(at: root)
        #expect(saved.inputActions == [InputAction(name: "Jump", bindings: [.key(.space), .mouseButton(.left), .gamepadButton(.a), .touch])])
        let reopened = EditorSettingsWindowViewModel(editorViewModel: editor, selectedSection: .project)
        #expect(try reopened.inputBindingsDraft.validatedActions() == saved.inputActions)
        reopened.inputBindingsDraft.addAction()
        let second = try #require(reopened.inputBindingsDraft.actions.last?.id)
        reopened.inputBindingsDraft.edit(second) { $0.name = "Jump" }
        reopened.saveProjectSettings()
        #expect(reopened.runtimeSettingsStatusMessage.contains("already exists"))
        #expect(try ProjectSystem.loadProject(at: root).inputActions == saved.inputActions)
        let legacy = try ProjectSystem.loadProject(from: Data(#"{"schemaVersion":1}"#.utf8))
        #expect(legacy.inputActions.isEmpty)
    }

    @Test func settingsButtonsAndBindingPickerUseRealViewEvents() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "InputSettingsUI")))
        }
        let draft = EditorInputBindingsDraft()
        let container = UIContainerView(rootView: EditorInputBindingsSettings(draft: draft))
        container.frame = Rect(x: 0, y: 0, width: 680, height: 560)
        func refresh() async {
            try? await Task.sleep(for: .milliseconds(20))
            container.layoutSubviews()
        }
        await refresh()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Settings.InputBindings.AddAction"))
        await refresh()
        #expect(draft.actions.count == 1)
        for device in ["Keyboard", "Mouse", "Gamepad", "Touch"] {
            _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Settings.InputBindings.Add\(device).NewAction"))
            await refresh()
        }
        #expect(draft.actions.first?.bindings.count == 4)
        var menu: ContextMenuPresentation?
        let previous = ContextMenuPresentationCenter.present
        ContextMenuPresentationCenter.present = { menu = $0 }
        defer { ContextMenuPresentationCenter.present = previous }
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Settings.InputBindings.Binding.NewAction.0"))
        let selectSpace = try #require(menu?.items.first { $0.title == "Space" }?.action)
        selectSpace()
        await refresh()
        #expect(draft.actions.first?.bindings.first == .key(.space))
        let rect = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Settings.InputBindings.Binding.NewAction.0")).absoluteFrame
        #expect(rect.minX >= 0 && rect.maxX <= 680 && rect.height >= 28)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Settings.InputBindings.RemoveBinding.NewAction.1"))
        await refresh()
        #expect(draft.actions.first?.bindings.count == 3)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Settings.InputBindings.RemoveAction.NewAction"))
        #expect(draft.actions.isEmpty)
    }

    @Test func systemCallbacksReceiveCurrentWorldInput() async throws {
        InputActionProbe.registerComponent()
        let plugin = try AdaScriptPlugin(
            source: """
                @system(scheduler: "update", id: "input.probe")
                class ProbeSystem {
                    @res var input: Input;
                    @query(InputActionProbe) var probes;
                    func update(context) {
                        for (var row in probes) {
                            row.inputActionProbe.value += input.getActionStrength("Move");
                        }
                    }
                }
                """,
            name: "InputProbe"
        )
        let world = World(name: "InputSystem")
        let app = AppWorlds(main: world)
        InputPlugin(actions: [InputAction(name: "Move", bindings: [.key(.d)])]).setup(in: app)
        plugin.setup(in: app)
        let entity = world.spawn { InputActionProbe(value: 0) }
        world.getRefResource(Input.self).wrappedValue
            .receiveEvent(
                KeyEvent(
                    window: .empty,
                    keyCode: .d,
                    modifiers: [],
                    status: .down,
                    time: 0,
                    isRepeated: false
                )
            )
        await world.runScheduler(.preUpdate)
        await world.runScheduler(.update)
        #expect(plugin.diagnostics.isEmpty)
        #expect(world.get(InputActionProbe.self, from: entity.id)?.value == 1)
    }

    @Test func savedProjectActionsReachAdaScriptDuringPlay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InputRuntime-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        let scriptID = "test.input.\(UUID().uuidString)"
        let source = """
            @scriptable(id: "\(scriptID)")
            class InputProbe {
                @res var input: Input;
                @export var count = 0;
                func update(context) {
                    if (input.isActionPressed("Jump")) { count += 1; }
                    if (input.isActionJustPressed("Jump")) { count += 10; }
                    if (input.isActionJustReleased("Jump")) { count += 100; }
                }
            }
            """
        try source.write(to: root.appendingPathComponent("Sources/Probe.ada"), atomically: true, encoding: .utf8)
        var project = ProjectSystem.defaultProject(projectName: "Game", buildSystem: .adaScript)
        project.inputActions = [InputAction(name: "Jump", bindings: [.key(.space)])]
        try ProjectSystem.saveProject(project, at: root)
        let loaded = try ProjectSystem.loadProject(at: root)
        let runtime = try EditorScriptableObjectCatalogLoader.load(project: loaded, at: root).playRuntime
        let world = World(name: "InputPlay")
        var app = AppWorlds(main: world)
        InputPlugin(actions: []).setup(in: app)
        ScriptableObjectPlugin().setup(in: app)
        try runtime.install(in: &app)
        let script = try ScriptableObjectRegistry.make(named: scriptID)
        world.spawn { ScriptableComponents(scripts: [script]) }
        func frame(_ status: KeyEvent.Status?) async {
            if let status {
                world.getRefResource(Input.self).wrappedValue
                    .receiveEvent(
                        KeyEvent(
                            window: .empty,
                            keyCode: .space,
                            modifiers: [],
                            status: status,
                            time: 0,
                            isRepeated: false
                        )
                    )
            }
            await world.runScheduler(.preUpdate)
            await world.runScheduler(.update)
            await world.runScheduler(.postUpdate)
        }
        await frame(.down)
        await frame(nil)
        await frame(.up)
        let data = try JSONEncoder().encode(ScriptableComponents(scripts: [script]))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let scripts = try #require(object["scripts"] as? [[String: Any]])
        let payload = try #require(scripts.first?["payload"] as? [String: Any])
        #expect(payload["count"] as? Int == 112)
    }
}

@Component
private struct InputActionProbe {
    var value: Double
}
