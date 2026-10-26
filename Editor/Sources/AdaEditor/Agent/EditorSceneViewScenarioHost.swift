@_spi(AdaEngine) import AdaEngine
import Foundation

/// Drives a game rendered by a `SceneView` (an isolated offscreen runtime or the visible Play game).
@MainActor
final class EditorSceneViewScenarioHost: EditorPlayScenarioHost {
    private let source: SceneViewFrameSource
    private let runtime: OffscreenSceneRuntime?
    private let logSource: String?
    private let stopHook: (@MainActor () -> Void)?
    private let diagnosticsProvider: @MainActor () -> [String]
    private var logCursor: Int
    private var startedAt = Date()
    private var pointer = Point.zero
    private let window = RID()

    private init(
        source: SceneViewFrameSource,
        runtime: OffscreenSceneRuntime?,
        logSource: String?,
        stopHook: (@MainActor () -> Void)?,
        diagnostics: @escaping @MainActor () -> [String]
    ) {
        self.source = source
        self.runtime = runtime
        self.logSource = logSource
        self.stopHook = stopHook
        self.diagnosticsProvider = diagnostics
        self.pointer = source.world?.getResource(Input.self)?.getMousePosition() ?? .zero
        RuntimeLogStore.shared.setEnabled(true)
        self.logCursor = RuntimeLogStore.shared.read(after: Int.max, limit: 1).nextCursor
    }

    /// Attaches to the game that is already running in Play.
    static func attachToPlay() throws -> EditorSceneViewScenarioHost {
        guard let source = SceneViewFrameRegistry.latest(label: EditorGameFrameCapture.gameLabel) else {
            throw SceneViewFrameCaptureError.noGameView(label: EditorGameFrameCapture.gameLabel)
        }
        let host = EditorSceneViewScenarioHost(source: source, runtime: nil, logSource: nil, stopHook: nil) { [] }
        host.startedAt = Date()
        return host
    }

    /// Starts an isolated runtime for `artifact`, separate from any Play window.
    static func startOffscreen(artifact: EditorAdaScriptProjectBuildArtifact, size: SizeInt, warmUp: Bool = true) async throws -> EditorSceneViewScenarioHost {
        let view = try EditorAdaScriptProjectRuntimeView(artifact: artifact)
        let logSource = "AgentScenario-\(UUID().uuidString)"
        let runtime = OffscreenSceneRuntime(label: "scenario", size: size, useSceneCameras: view.usesSceneCameras) { app in
            app.runtimeLogSource = logSource
            view.configureRuntime(&app)
        }
        return try await start(
            runtime: runtime,
            logSource: logSource,
            stopHook: { view.performanceSession.stop() },
            diagnostics: { view.diagnostics },
            warmUp: warmUp ? .seconds(5) : .zero
        )
    }

    /// Starts `runtime` and waits for its first frames. The host stops the runtime when it is stopped.
    static func start(
        runtime: OffscreenSceneRuntime,
        logSource: String?,
        stopHook: (@MainActor () -> Void)? = nil,
        diagnostics: @escaping @MainActor () -> [String] = { [] },
        warmUp: Duration = .seconds(5)
    ) async throws -> EditorSceneViewScenarioHost {
        try await runtime.start()
        let host = EditorSceneViewScenarioHost(
            source: runtime.frameSource,
            runtime: runtime,
            logSource: logSource,
            stopHook: stopHook,
            diagnostics: diagnostics
        )
        await host.warmUp(timeout: warmUp)
        return host
    }

    /// Lets the game build its first frames so the scenario clock starts on a running game.
    private func warmUp(timeout: Duration) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while source.frameSequence < 3, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        startedAt = Date()
    }

    func stop() {
        runtime?.stop()
        stopHook?()
    }

    // MARK: - EditorPlayScenarioHost

    var diagnostics: [String] { diagnosticsProvider() }

    func wait(until time: Double) async throws {
        let remaining = time - Date().timeIntervalSince(startedAt)
        if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
        try Task.checkCancellation()
    }

    func perform(_ input: EditorPlayScenario.Input) {
        let now = Float(Date().timeIntervalSince(startedAt))
        switch input {
        case let .key(code, down):
            source.send(KeyEvent(window: window, keyCode: code, modifiers: [], status: down ? .down : .up, time: now, isRepeated: false))
        case let .mouse(button, down, x, y):
            pointer = Point(x, y)
            source.movePointer(to: pointer)
            source.send(MouseEvent(window: window, button: button, mousePosition: pointer, phase: down ? .began : .ended, modifierKeys: [], time: now))
        case let .pointer(x, y):
            let next = Point(x, y)
            let delta = next - pointer
            pointer = next
            source.movePointer(to: pointer)
            source.send(MouseEvent(window: window, button: .none, motionDelta: delta,
                mousePosition: pointer, phase: .changed, modifierKeys: [], time: now))
        }
    }

    func captureFrame(camera: String?, maxDimension: Int) async throws -> EditorScenarioFrame {
        let frame = try await source.captureFrame(after: source.frameSequence, cameraName: camera, maxDimension: maxDimension)
        return EditorScenarioFrame(
            image: frame.image,
            sequence: frame.sequence,
            sourceWidth: frame.sourceWidth,
            sourceHeight: frame.sourceHeight,
            activeCameras: frame.activeCameras
        )
    }

    func snapshot(watch: EditorPlayScenario.Watch) -> [String: Any] {
        source.withWorldExecutionContext { world in snapshot(watch: watch, in: world) } ?? ["error": "The game world is gone; the game stopped."]
    }

    private func snapshot(watch: EditorPlayScenario.Watch, in world: World) -> [String: Any] {
        let all = world.getEntities().filter { $0.name != "SceneView_Camera" }
        var chosen: [Entity] = []
        var missing: [String] = []
        if watch.entities.isEmpty {
            chosen = Array(all.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }.prefix(EditorPlayScenario.Limits.maxEntitiesPerSnapshot))
        } else {
            for name in watch.entities {
                let matches = all.filter { $0.name == name }.sorted { $0.id < $1.id }
                if matches.isEmpty { missing.append(name) }
                chosen.append(contentsOf: matches)
            }
            chosen = Array(chosen.prefix(EditorPlayScenario.Limits.maxEntitiesPerSnapshot))
        }
        let wanted = Set(watch.components.map { $0.lowercased() })
        let entities = chosen.map { entity -> [String: Any] in
            let captured = EditorScenarioComponentSnapshot.read(in: world, entity: entity.id, matching: wanted)
            var value: [String: Any] = ["id": entity.id, "name": entity.name, "active": entity.isActive,
                "components": captured.summaries, "componentFields": captured.fields]
            // AdaScript `@export` fields are the readable script state (score, phase, ...).
            let scripts = (world.get(ScriptableComponents.self, from: entity.id)?.scripts ?? []).map { script -> [String: Any] in
                let descriptor = ScriptableObjectRegistry.descriptor(for: script)
                let fields = (descriptor?.exportedFields.keys.sorted() ?? []).reduce(into: [String: String]()) { result, key in
                    result[key] = script.readExportedField(key).map { EditorPlayInspectionModel.reflectedValue($0) } ?? "—"
                }
                return ["type": descriptor?.identifier ?? "unknown", "fields": fields]
            }
            if !scripts.isEmpty { value["scripts"] = scripts }
            return value
        }
        var value: [String: Any] = [
            "entityCount": all.count,
            "entities": entities,
            "frameSequence": source.frameSequence,
            "activeCameras": source.activeCameraNames,
            // Proves the game world is advancing: a flat value means systems are not running.
            "worldElapsedSeconds": world.getResource(ElapsedTime.self).map { Double($0.elapsedTime) } ?? -1,
        ]
        if !missing.isEmpty { value["missingEntities"] = missing }
        return value
    }

    func drainLogs() -> [[String: Any]] {
        let batch = RuntimeLogStore.shared.read(after: logCursor, limit: 1000)
        logCursor = batch.nextCursor
        return batch.entries
            .filter { logSource == nil || $0.source == logSource }
            .map { ["level": $0.level, "label": $0.label, "message": String($0.message.prefix(300))] }
    }
}
