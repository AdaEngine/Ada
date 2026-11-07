import AdaEditor
@_spi(Internal) import AdaEngine
import AdaMCPCore
import Foundation

@MainActor
final class StudioInteractionRunner {
    struct Report: Encodable {
        var status = "passed"
        var completedSteps = 0
        var failedStep: Int?
        var command: String?
        var message: String?
        var screenshot: String?
        var trace: [String] = []
    }

    let workbench: EditorWorkbenchInspection
    weak var worlds: AppWorlds?
    var workbenchMounted = false
    private var running = false
    private var usedFixture = false
    private var trace: [String] = []
    private let clock = ContinuousClock()
    private var runDeadline: ContinuousClock.Instant?

    init(workbench: EditorWorkbenchInspection) {
        self.workbench = workbench
    }

    func run(source: String) async -> Report {
        guard !running else {
            return Report(status: "failed", message: "A flow is already running in this host.")
        }
        guard !usedFixture else {
            return Report(status: "failed", message: "Start a fresh host to run a new flow against the original fixture.")
        }
        running = true
        trace = []
        runDeadline = clock.now.advanced(by: .seconds(35))
        defer {
            runDeadline = nil
            running = false
        }
        var report = Report()
        do {
            let flow = try StudioInteractionFlow(source: source)
            usedFixture = true
            let window = try await wait("loaded Studio workbench", timeout: .seconds(22)) {
                guard self.workbenchMounted, self.workbench.hasLoadedScene else {
                    return nil as UIWindow?
                }
                return self.worlds?.getResource(PrimaryWindow.self)?.window
            }
            for step in flow.steps {
                report.command = step.command
                try await perform(step, window: window)
                report.completedSteps += 1
            }
            report.command = nil
        } catch {
            report.status = "failed"
            report.failedStep = report.command == nil ? nil : report.completedSteps + 1
            report.message = error.localizedDescription
            if let worlds, report.command != nil, !Task.isCancelled {
                let capture = try? await RenderCaptureService(appWorlds: worlds)
                    .capture(pauseBeforeCapture: false, refreshFrame: false)
                report.screenshot = capture?.path
            }
        }
        report.trace = trace
        return report
    }

    private func perform(_ step: StudioInteractionFlow.Step, window: UIWindow) async throws {
        switch step {
        case let .tapOn(target):
            let point = try await resolve(target, window: window)
            do {
                try await mouse(.began, at: point, window: window)
                try await mouse(.ended, at: point, window: window)
            } catch {
                await cancelMouse(at: point, window: window)
                throw error
            }
        case let .drag(drag):
            try await performDrag(drag, window: window)
        case let .pressKey(key):
            let modifiers: KeyModifier = key.modifiers?.contains("shift") == true ? [.main, .shift] : .main
            try await pressUndoKey(modifiers: modifiers, window: window)
        case let .assertScene(expectation):
            try await assertScene(expectation)
        }
    }

    private func performDrag(_ drag: StudioInteractionFlow.Drag, window: UIWindow) async throws {
        let viewport = drag.from.anchor != nil
        let endTarget: Point? = if let destination = drag.to {
            try await resolve(destination, window: window)
        } else {
            nil
        }
        let start = try await resolve(drag.from, window: window)
        let end = endTarget ?? Point(start.x + (drag.by?.x ?? 0), start.y + (drag.by?.y ?? 0))
        guard window.bounds.contains(point: end) else { throw FlowError("Drag destination \(end) is outside the window.") }
        let entity = viewport ? workbench.selectedEntity : nil
        let original = entity.flatMap { workbench.sceneState(entity: $0) }
        guard !viewport || original?.position != nil else { throw FlowError("Selected gizmo entity has no document transform.") }
        var last = start
        do {
            try await mouse(.began, at: start, window: window, awaitViewport: viewport)
            let samples = max(2, drag.durationMs / 40)
            let moves = drag.end == .cancel ? max(1, samples / 2) : samples
            let started = clock.now
            for index in 1...moves {
                try await clock.sleep(until: started.advanced(by: .milliseconds(drag.durationMs * index / samples)))
                let point = start + (end - start) * (Float(index) / Float(samples))
                let delta = point - last
                last = point
                try await mouse(.changed, at: point, delta: delta, window: window, awaitViewport: viewport)
            }
            if let entity, let original {
                guard let previewPosition = workbench.sceneState(entity: entity, preview: true)?.position,
                      workbench.sceneState(entity: entity) == original, previewPosition != original.position else {
                    throw FlowError("Gizmo drag must change preview position before changing the document.")
                }
            }
            try await mouse(drag.end == .cancel ? .cancelled : .ended, at: last, window: window, awaitViewport: viewport)
            if drag.end == .cancel, let entity, let original {
                guard workbench.sceneState(entity: entity) == original,
                      workbench.sceneState(entity: entity, preview: true)?.position == original.position else {
                    throw FlowError("Cancelled gizmo drag did not restore the preview and document.")
                }
            }
        } catch {
            await cancelMouse(at: last, window: window)
            throw error
        }
    }

    private func resolve(_ target: StudioInteractionFlow.Target, window: UIWindow) async throws -> Point {
        var observation = "not mounted"
        do {
            return try await wait("target \(target.id) \(target.anchor ?? "")") {
                let matches = window.uiInspectableContainers().flatMap { container in
                    container.uiFindNodes(matching: .accessibilityIdentifier(target.id)).map { (container, $0) }
                }
                guard matches.count < 2 else { throw FlowError("Ambiguous target '\(target.id)' (\(matches.count) matches).") }
                guard let (container, node) = matches.first, let view = container as? UIView else {
                    observation = "not mounted"
                    return nil
                }
                var fraction = Point(0.5, 0.5)
                if target.anchor != nil {
                    guard let anchor = self.workbench.translateXAnchor() else {
                        observation = "X gizmo has no actionable point in the presented frame"
                        return nil
                    }
                    fraction = anchor
                }
                let frame = node.absoluteFrame
                let local = Point(frame.minX + frame.width * fraction.x, frame.minY + frame.height * fraction.y)
                let point = view.convert(local, to: window)
                guard window.bounds.contains(point: point) else {
                    observation = "clipped at \(point)"
                    return nil
                }
                let hit = window.uiInspectionHitTest(at: point)
                guard hit?.path.contains(where: { $0.runtimeId == node.runtimeId }) == true else {
                    observation = "blocked at \(point). Hit \(hit?.node.accessibilityIdentifier ?? hit?.node.viewType ?? "nothing")"
                    return nil
                }
                self.record("target \(target.id) \(target.anchor ?? "") at \(point)")
                return point
            }
        } catch {
            throw FlowError("\(error.localizedDescription) Last target observation: \(observation).")
        }
    }

    private func assertScene(_ expectation: StudioInteractionFlow.Assertion) async throws {
        var actual: EditorWorkbenchInspection.SceneState?
        do {
            let _: Bool = try await wait("scene assertion for \(expectation.entity)", timeout: .seconds(2)) {
                actual = self.workbench.sceneState(entity: expectation.entity)
                guard let actual,
                      expectation.parent.map({ actual.parent == $0 }) != false,
                      expectation.undoCount.map({ actual.undoCount == $0 }) != false else {
                    return nil
                }
                if let expected = expectation.position {
                    guard let position = actual.position,
                          zip(position, expected).allSatisfy({ abs($0 - $1) <= (expectation.tolerance ?? 0.001) }) else { return nil }
                }
                return true
            }
        } catch {
            throw FlowError("Assertion for \(expectation.entity): expected \(expectation), actual \(String(describing: actual)). \(error.localizedDescription)")
        }
    }

    private func mouse(
        _ phase: MouseEvent.Phase, at point: Point, delta: Vector2? = nil, window: UIWindow, awaitViewport: Bool = false
    ) async throws {
        let observed = workbench.viewportInputCount
        record("\(phase) \(point)")
        let event = MouseEvent(
            window: window.id,
            button: .left,
            motionDelta: delta,
            mousePosition: point,
            phase: phase,
            modifierKeys: [],
            time: timestamp()
        )
        try await send(event)
        if awaitViewport {
            let _: Bool = try await wait("viewport acknowledgement of \(phase)", timeout: .seconds(2)) {
                guard self.workbench.viewportInputCount > observed,
                      let received = self.workbench.lastViewportInput,
                      received.phase == phase, received.time == event.time, received.button == .left else { return nil }
                return true
            }
        }
    }

    private func cancelMouse(at point: Point, window: UIWindow) async {
        await Task { try? await self.mouse(.cancelled, at: point, window: window) }.value
    }

    private func send<T: InputEvent>(_ event: T) async throws {
        guard let worlds else { throw FlowError("Studio runtime detached.") }
        if let runDeadline, clock.now >= runDeadline, !isRelease(event) {
            throw FlowError("Studio flow exceeded 35 seconds.")
        }
        try await worlds.withWorldAccess {
            guard worlds.main.getResource(Input.self) != nil,
                  worlds.getResource(PrimaryWindow.self)?.window.id == event.window else {
                throw FlowError("The bound Studio window is no longer available.")
            }
            worlds.main.getRefResource(Input.self).wrappedValue.receiveEvent(event)
        }
        let _: Bool = try await wait("window input dispatch", timeout: .seconds(2)) {
            try await worlds.withWorldAccess {
                let input = worlds.main.getResource(Input.self)
                return input?.pendingEventsPool.contains(where: { $0.id == event.id }) == false ? true : nil
            }
        }
    }

    private func wait<T>(
        _ description: String, timeout: Duration = .seconds(8), until predicate: @MainActor () async throws -> T?
    ) async throws -> T {
        let localDeadline = clock.now.advanced(by: timeout)
        let deadline = min(localDeadline, runDeadline ?? localDeadline)
        repeat {
            try Task.checkCancellation()
            if let result = try await predicate() {
                return result
            }
            try await Task.sleep(for: .milliseconds(16))
        } while clock.now < deadline
        throw FlowError("Timed out waiting for \(description).")
    }

    private func record(_ entry: String) {
        if trace.count == 128 { trace.removeFirst() }
        trace.append(entry)
    }

    private func pressUndoKey(modifiers: KeyModifier, window: UIWindow) async throws {
        let down = KeyEvent(window: window.id, keyCode: .z, modifiers: modifiers, status: .down, time: timestamp(), isRepeated: false)
        do {
            try await send(down)
            try await send(KeyEvent(window: window.id, keyCode: .z, modifiers: modifiers, status: .up, time: timestamp(), isRepeated: false))
        } catch {
            let release = KeyEvent(window: window.id, keyCode: .z, modifiers: modifiers, status: .up, time: timestamp(), isRepeated: false)
            await Task { try? await self.send(release) }.value
            throw error
        }
    }

    private func isRelease(_ event: any InputEvent) -> Bool {
        switch event {
        case let mouse as MouseEvent: mouse.phase == .cancelled || mouse.phase == .ended
        case let key as KeyEvent: key.status == .up
        default: false
        }
    }

    private func timestamp() -> Float { Float(Time.absolute) }
}
