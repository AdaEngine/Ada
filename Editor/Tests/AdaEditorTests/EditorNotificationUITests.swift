@_spi(AdaEngine) import AdaEngine
import AdaInput
@_spi(Internal) import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

@Suite("Editor notification UI", .serialized)
@MainActor
struct EditorNotificationUITests {
    private func prepareRenderer() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "NotificationsUI")))
        }
    }

    @Test("A real card routes its action and dismisses without deleting history")
    func cardActions() throws {
        prepareRenderer()
        let center = EditorNotificationCenter()
        let action = EditorNotificationAction(title: "Open chat", destination: .chat, projectID: "project", sessionID: "session")
        let item = EditorNotification(
            id: "card",
            source: .agent,
            importance: .attention,
            title: "Permission required",
            detail: "An agent needs your decision.",
            actions: [action]
        )
        center.post(item)
        var received: EditorNotificationAction?
        center.onAction = { received = $0 }
        let container = UIContainerView(rootView: EditorNotificationCard(item: item, center: center).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 400, height: 220)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Notification.Action.card.0"))
        #expect(received == action)
        #expect(center.notifications.count == 1)
        #expect(center.unreadCount == 0)
        #expect(center.toasts.isEmpty)
    }

    @Test("middle click dismisses a card without firing its action or deleting history")
    func middleClick() throws {
        prepareRenderer()
        let center = EditorNotificationCenter()
        let item = EditorNotification(
            id: "middle",
            source: .build,
            importance: .information,
            title: "Built",
            actions: [.init(title: "Open build", destination: .build)]
        )
        center.post(item)
        var actionCount = 0
        center.onAction = { _ in actionCount += 1 }
        let container = UIContainerView(rootView: EditorNotificationCard(item: item, center: center))
        container.frame = Rect(x: 0, y: 0, width: 400, height: 220)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let frame = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Notification.Action.middle.0")).absoluteFrame
        for phase in [MouseEvent.Phase.began, .ended] {
            container.onMouseEvent(
                MouseEvent(
                    window: .empty,
                    button: .middle,
                    mousePosition: Point(frame.midX, frame.midY),
                    phase: phase,
                    modifierKeys: [],
                    time: 0
                )
            )
        }
        #expect(center.toasts.isEmpty)
        #expect(center.notifications.first?.isRead == true)
        #expect(center.notifications.count == 1)
        #expect(actionCount == 0)
    }

    @Test("notifications begin a separate draw batch after underlying borders")
    func overlayDrawingOrder() throws {
        prepareRenderer()
        let model = EditorViewModel(project: nil)
        model.showsNotifications = true
        let container = UIContainerView(
            rootView:
                RectangleShape().stroke(Color.red, lineWidth: 1)
                .overlay {
                    EditorNotificationOverlay(model: model, size: Size(width: 480, height: 640), center: EditorNotificationCenter())
                }
        )
        container.frame = Rect(x: 0, y: 0, width: 480, height: 640)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let context = UIGraphicsContext()
        container.draw(with: context)
        let commands = context.getDrawCommands()
        let border = try #require(
            commands.firstIndex {
                if case .drawPath(_, _, .stroke) = $0 {
                    return true
                }
                return false
            }
        )
        #expect(
            commands.dropFirst(border + 1)
                .contains {
                    if case .beginLayer = $0 {
                        return true
                    }
                    return false
                }
        )
    }

    #if os(macOS)
        @Test("Cancel from Activity terminates the actual workspace process")
        func cancelWorkspaceProcess() async {
            let runner = EditorProcessRunner()
            let service = SwiftPMWorkspaceService(processRunner: runner)
            let model = EditorViewModel(project: nil, workspaceService: service)
            let (ready, continuation) = AsyncStream<Void>.makeStream()
            let command = EditorProcessCommand(
                executablePath: "/usr/bin/python3",
                arguments: ["-c", "import time; print('ready', flush=True); time.sleep(30)"],
                workingDirectory: FileManager.default.temporaryDirectory
            )
            let process = Task {
                let result = await runner.run(command) { event in
                    if event.text.contains("ready") {
                        continuation.yield(())
                        continuation.finish()
                    }
                }
                continuation.finish()
                return result
            }
            for await _ in ready { break }
            let id = model.beginWorkspaceActivity(title: "Cancellation check", source: .build)
            EditorNotificationCenter.shared.activities.cancel(id)
            let result = await process.value
            #expect(result.exitCode == 15)
            #expect(EditorNotificationCenter.shared.activities.all.first(where: { $0.id == id })?.state == .cancelled)
        }
    #endif

    @Test("The full editor window constructs with its notification overlay")
    func fullEditorWindow() throws {
        prepareRenderer()
        let container = UIContainerView(rootView: EditorView(project: nil).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 1280, height: 800)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Notifications.Bell"))
    }

    @Test("Bell opens the panel; compact presentation fits the available area")
    func compactPanel() async throws {
        prepareRenderer()
        let center = EditorNotificationCenter()
        center.post(EditorNotification(id: "badge", source: .agent, importance: .attention, title: "Unread", detail: ""))
        let model = EditorViewModel(project: nil)
        let bell = UIContainerView(rootView: EditorNotificationBell(model: model, center: center).theme(.adaEditor))
        bell.frame = Rect(x: 0, y: 0, width: 90, height: 32)
        bell.bounds.size = bell.frame.size
        bell.layoutIfNeeded()
        let badge = try bell.uiNode(matching: .accessibilityIdentifier("AdaEditor.Notifications.UnreadBadge"))
        #expect(badge.absoluteFrame.width == 7 && badge.absoluteFrame.height == 7)
        center.markAllRead()
        for _ in 0..<10 {
            await Task.yield()
            bell.update(1.0 / 60.0)
            bell.layoutIfNeeded()
        }
        #expect(bell.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.Notifications.UnreadBadge")).isEmpty)
        _ = try bell.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Notifications.Bell"))
        #expect(model.showsNotifications)
        let overlay = UIContainerView(rootView: EditorNotificationOverlay(model: model, size: Size(width: 360, height: 420), center: center).theme(.adaEditor))
        overlay.frame = Rect(x: 0, y: 0, width: 360, height: 420)
        overlay.bounds.size = overlay.frame.size
        overlay.layoutIfNeeded()
        let panel = try overlay.uiNode(matching: .accessibilityIdentifier("AdaEditor.Notifications.Panel"))
        #expect(panel.absoluteFrame.width <= 360)
        #expect(panel.absoluteFrame.height <= 420)
    }
}
