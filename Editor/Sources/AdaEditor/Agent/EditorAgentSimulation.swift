@_spi(Internal) import AdaEngine
import AdaScriptCompilerCore
import Foundation

/// Executes real game systems without a window. Rendering and touch hit testing remain Play checks.
@MainActor
final class EditorAgentSimulation {
    private let artifact: EditorAdaScriptProjectBuildArtifact
    private let app: AppWorlds
    private let script: AdaScriptPlugin?
    private let inputPlugin: InputPlugin
    private var heldKeys: Set<KeyCode> = []
    private var frame = 0
    private var stopped = false
    private var logCursor = 0
    private var logs: [RuntimeLogStore.Entry] = []
    private let source = "AgentSimulation-\(UUID().uuidString)"

    init(artifact: EditorAdaScriptProjectBuildArtifact) throws {
        self.artifact = artifact
        self.app = AppWorlds(main: World(name: "Mobile agent simulation"))
        self.inputPlugin = InputPlugin(actions: artifact.scenePlayRuntime.inputActions)
        try artifact.scenePlayRuntime.registerScriptableObjects()
        self.script = try artifact.scenePlayRuntime.makeScriptPlugin()
    }

    var diagnostics: [String] {
        var values = script?.diagnostics ?? []
        if let error = app.main.getResource(SceneNavigator.self)?.lastError { values.append(error) }
        values.append(contentsOf: logs.filter { $0.level == "error" || $0.level == "critical" }.map(\.message))
        return Array(Set(values)).sorted()
    }

    func start() async throws {
        RuntimeLogStore.shared.setEnabled(true)
        logCursor = RuntimeLogStore.shared.read(after: Int.max, limit: 1).nextCursor
        app.runtimeLogSource = source
        app.addPlugin(TransformPlugin())
        app.addPlugin(inputPlugin)
        app.addPlugin(EventsPlugin())
        app.addPlugin(AssetsPlugin(assetDirectory: artifact.assetsDirectory))
        app.addPlugin(ScenePlugin(includesModel3D: false))
        app.addPlugin(ScriptableObjectPlugin())
        if artifact.plugins.contains(.physics2D) {
            let gravity = artifact.plugins.physics2DGravity
            app.addPlugin(Physics2DPlugin(gravity: [Float(gravity[0]), Float(gravity[1])]))
        }
        if artifact.plugins.contains(.physics3D) { app.addPlugin(Physics3DPlugin()) }
        if let script { app.addPlugin(script) }
        if let model = artifact.sceneModel {
            app.addPlugin(EditorAdaScriptRuntimeEntryPlugin(sceneModel: model, assetsDirectory: artifact.assetsDirectory))
        }
        try await app.build()
        await app.withExecutionContext { await app.main.runScheduler(.startup, deltaTime: 0) }
        collectLogs()
    }

    func step(frames: Int, deltaTime: Double, keys: [String]?) async throws {
        guard !stopped else { throw SimulationError("The simulation is stopped.") }
        if let keys {
            let decoded = try keys.map { name -> KeyCode in
                guard let code = KeyCode.allCases.first(where: { $0 != .none && (String(describing: $0) == name || $0.rawValue == name) }) else {
                    throw SimulationError("Unknown key: \(name)")
                }
                return code
            }
            let next = Set(decoded)
            for key in heldKeys.subtracting(next) { send(key, status: .up) }
            for key in next.subtracting(heldKeys) { send(key, status: .down) }
            heldKeys = next
        }
        for _ in 0..<frames {
            try Task.checkCancellation()
            await app.withExecutionContext {
                await app.main.runScheduler(.preUpdate, deltaTime: Float(deltaTime))
                await app.main.runScheduler(.update, deltaTime: Float(deltaTime))
                await app.main.runScheduler(.postUpdate, deltaTime: Float(deltaTime))
            }
            frame += 1
            collectLogs()
            if !diagnostics.isEmpty { break }
        }
    }

    func snapshot() -> [String: Any] {
        let entities = app.main.getEntities().sorted { $0.id < $1.id }
        return [
            "verification": "isolated_simulation", "rendered": false, "touchUIVerified": false,
            "frame": frame, "diagnostics": diagnostics, "entityCount": entities.count,
            "heldKeys": heldKeys.map { String(describing: $0) }.sorted(),
            "entities": entities.prefix(200).map { entity -> [String: Any] in
                var value: [String: Any] = ["id": entity.id, "name": entity.name, "active": entity.isActive]
                if let transform = app.main.get(Transform.self, from: entity.id) {
                    value["position"] = [transform.position.x, transform.position.y, transform.position.z]
                }
                let schemas = (try? AdaScriptSchemaParser.parse(sources: artifact.sources)) ?? []
                value["runtimeComponents"] = schemas.compactMap { schema -> [String: Any]? in
                    guard let descriptor = app.main.runtimeComponentDescriptor(named: schema.name),
                        let component = app.main.getRuntimeComponent(descriptor.componentID, from: entity.id)
                    else {
                        return nil
                    }
                    return ["name": schema.name, "fields": Dictionary(uniqueKeysWithValues: zip(schema.fields.map(\.name), component.values.map { String(describing: $0) }))]
                }
                return value
            },
            "truncated": entities.count > 200,
            "logs": logs.map { ["level": $0.level, "label": $0.label, "message": $0.message] },
            "excludedCapabilities": ["rendering", "audio playback", "multiplayer transport", "touch UI hit testing"],
        ]
    }

    func stop() {
        guard !stopped else {
            return
        }
        stopped = true
        script?.destroy(for: app)
        inputPlugin.destroy(for: app)
        heldKeys = []
    }

    private func send(_ code: KeyCode, status: KeyEvent.Status) {
        app.main.getRefResource(Input.self).wrappedValue.receiveEvent(
            KeyEvent(
                window: .empty,
                keyCode: code,
                modifiers: [],
                status: status,
                time: 0,
                isRepeated: false
            )
        )
    }

    private func collectLogs() {
        let batch = RuntimeLogStore.shared.read(after: logCursor, limit: 1000)
        logCursor = batch.nextCursor
        logs.append(contentsOf: batch.entries.filter { $0.source == source })
        if logs.count > 100 { logs.removeFirst(logs.count - 100) }
    }

    private struct SimulationError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
