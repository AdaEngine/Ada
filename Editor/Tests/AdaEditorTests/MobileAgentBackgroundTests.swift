@testable import AdaEditor
import Foundation
import Testing

@MainActor
struct MobileAgentBackgroundTests {
    @Test("A real operation reports work, retains tool errors, and completes its background once")
    func completedOperation() async throws {
        let center = EditorNotificationCenter()
        let project = UUID()
        let operation = MobileEditorAgentOperation(projectID: project, center: center)
        let background = MobileOperationBackgroundProbe()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("result.txt")
        let result = await withCheckedContinuation { continuation in
            operation.start(
            projectName: "Prototype",
            requestBackground: { id, coordinator in
                #expect(coordinator.canCancel(id))
                coordinator.attachBackground(background, to: id)
            },
            work: {
                try "asset written".write(to: output, atomically: true, encoding: .utf8)
                operation.completedStep()
                operation.reportError("Game.ada:12: unknown symbol", tool: "editor.build")
                operation.failedTool("editor.build")
                operation.update("Repairing Game.ada…")
                #expect(background.updates.last?.detail.contains("Game.ada:12") == true)
                #expect(background.updates.last?.completedUnits == 1)
                #expect(background.updates.last?.totalUnits == 2)
                operation.completedStep()
                return .init(succeeded: true, detail: "Validated")
            },
            finished: { state, detail in continuation.resume(returning: (state, detail)) }
        )
        }
        #expect(result.0 == .completed)
        #expect(result.1 == "Validated")
        #expect(try String(contentsOf: output, encoding: .utf8) == "asset written")
        #expect(background.completions == [true])
        #expect(background.updates.last?.state == .completed)
        #expect(background.updates.last?.fractionCompleted == 1)
        #expect(center.notifications.contains { $0.importance == .error && $0.detail.contains("Game.ada:12") })
        #expect(center.notifications.first?.actions.first?.projectID == project.uuidString)
    }

    @Test("System expiration cancels the worker, preserves saved files, and cannot become success")
    func expirationCancelsWork() async throws {
        let center = EditorNotificationCenter()
        let operation = MobileEditorAgentOperation(projectID: UUID(), center: center)
        let background = MobileOperationBackgroundProbe()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("background-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let (started, signal) = AsyncStream<Void>.makeStream()
        let (finished, finishSignal) = AsyncStream<EditorOperationActivity.State>.makeStream()
        operation.start(
            projectName: "Prototype",
            requestBackground: { id, coordinator in
                coordinator.attachBackground(background, to: id)
            },
            work: {
                try "saved".write(to: url, atomically: true, encoding: .utf8)
                signal.yield(())
                try await Task.sleep(for: .seconds(60))
                try "late mutation".write(to: url, atomically: true, encoding: .utf8)
                return .init(succeeded: true, detail: "Late success")
            },
            finished: { state, _ in finishSignal.yield(state); finishSignal.finish() }
        )
        var startedIterator = started.makeAsyncIterator()
        _ = await startedIterator.next()
        center.activities.cancel(operation.id, interrupted: true, detail: "iOS stopped background execution.")
        var resultIterator = finished.makeAsyncIterator()
        #expect(await resultIterator.next() == .interrupted)
        #expect(try String(contentsOf: url, encoding: .utf8) == "saved")
        #expect(background.completions == [false])
        #expect(background.updates.last?.state == .interrupted)
        #expect(center.notifications.first?.importance == .error)
        #expect(center.notifications.first?.detail.contains("iOS stopped") == true)
        center.activities.finish(operation.id, state: .completed)
        operation.cancel()
        #expect(center.activities.all.first?.state == .interrupted)
        #expect(background.completions == [false])
    }

    @Test("Thrown errors finish the Activity and persist a result with its original project")
    func failedOperation() async {
        let center = EditorNotificationCenter()
        let operation = MobileEditorAgentOperation(projectID: UUID(), center: center)
        let result = await withCheckedContinuation { continuation in
            operation.start(
            projectName: "Prototype",
            requestBackground: { _, _ in },
            work: {
                throw CocoaError(.fileReadCorruptFile)
            },
            finished: { state, detail in continuation.resume(returning: (state, detail)) }
        )
        }
        #expect(result.0 == .failed)
        #expect(!result.1.isEmpty)
        #expect(center.notifications.first?.importance == .error)
        #expect(center.notifications.first?.operationID == operation.id)
        #expect(center.activities.active.isEmpty)
    }

    @Test("A delayed system grant receives the terminal result rather than reopening work")
    func delayedGrant() {
        let center = EditorNotificationCenter()
        let id = center.activities.begin(.init(source: .agent, title: "Agent"))
        center.activities.finish(id, state: .completed, detail: "Done")
        let background = MobileOperationBackgroundProbe()
        center.activities.attachBackground(background, to: id)
        #expect(background.updates.last?.state == .completed)
        #expect(background.completions == [true])
        #expect(center.activities.active.isEmpty)
    }

    @Test("System subtitle uses actual elapsed time and freezes after completion")
    func elapsedSubtitle() throws {
        let start = Date(timeIntervalSince1970: 1000)
        var activity = EditorOperationActivity(source: .agent, title: "Agent", detail: "Using editor.build", startedAt: start)
        #expect(activity.systemSubtitle(at: start.addingTimeInterval(65)) == "1:05 · Using editor.build")
        #expect(activity.elapsedText(at: start.addingTimeInterval(3661)) == "1:01:01")
        activity.state = .failed
        activity.detail = "Network disconnected"
        activity.finishedAt = start.addingTimeInterval(70)
        #expect(activity.systemSubtitle(at: start.addingTimeInterval(900)) == "1:10 · Failed · Network disconnected")
        let restored = try JSONDecoder().decode(EditorOperationActivity.self, from: JSONEncoder().encode(activity))
        #expect(restored.finishedAt == activity.finishedAt)
    }

    @Test("Restoring interrupted work excludes the time while the app was absent")
    func interruptedElapsedTime() {
        let center = EditorNotificationCenter()
        let start = Date(timeIntervalSince1970: 1000)
        center.activities.restore([
            .init(
                source: .agent,
                title: "Agent",
                startedAt: start,
                updatedAt: start.addingTimeInterval(70)
            )
        ])
        #expect(center.activities.all.first?.state == .interrupted)
        #expect(center.activities.all.first?.elapsedText(at: start.addingTimeInterval(900)) == "1:10")
    }
}

@MainActor
private final class MobileOperationBackgroundProbe: EditorBackgroundExecution {
    var updates: [EditorOperationActivity] = []
    var completions: [Bool] = []
    func update(_ activity: EditorOperationActivity) { updates.append(activity) }
    func finish(success: Bool) { completions.append(success) }
}
