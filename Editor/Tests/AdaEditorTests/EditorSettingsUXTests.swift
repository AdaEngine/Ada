@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

@MainActor
@Suite(.serialized)
struct EditorSettingsUXTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "SettingsUX")))
        }
    }

    @Test("Skill folder controls add, edit, and remove independent paths")
    func skillFolders() async throws {
        let agent = EditorAgentViewModel(project: nil, settings: EditorAgentSettingsStore())
        agent.agentSkillsDirectories = [".skills", "Skills, Shared"]
        let container = UIContainerView(rootView: EditorAgentSkillDirectoriesView(agent: agent).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 650, height: 250)
        container.layoutIfNeeded()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Settings.SkillFolders.Add"))
        #expect(agent.agentSkillsDirectories == [".skills", "Skills, Shared", ""])
        agent.skillDirectoryBinding(at: 2).wrappedValue = "More Skills"
        for _ in 0..<10 {
            await Task.yield()
            container.update(1.0 / 60.0)
            container.layoutIfNeeded()
        }
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Settings.SkillFolders.Path.2"))
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Settings.SkillFolders.Remove.0"))
        #expect(agent.agentSkillsDirectories == ["Skills, Shared", "More Skills"])
    }

    @Test("Agent search is grouped in a toolbar and filters work as a segment")
    func agentToolbarAndFilter() async throws {
        let agent = EditorAgentViewModel(project: nil, settings: EditorAgentSettingsStore())
        let container = UIContainerView(rootView: EditorAgentCatalogView(agent: agent, loadsCatalog: false).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 700, height: 500)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let toolbar = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agents.Toolbar"))
        let search = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agents.Search"))
        let filter = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Agents.Filter"))
        #expect(search.absoluteFrame.minY >= toolbar.absoluteFrame.minY)
        #expect(search.absoluteFrame.maxY <= toolbar.absoluteFrame.maxY)
        #expect(filter.absoluteFrame.minY > toolbar.absoluteFrame.maxY)
        for value in EditorAgentCatalogViewModel.Filter.allCases {
            _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Agents.Filter.\(value.rawValue)"))
            #expect(agent.catalog.filter == value)
        }
    }

    @Test("Notification switches change preferences and persist after reload")
    func notificationSwitches() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notification-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = EditorNotificationStore(url: url)
        let center = EditorNotificationCenter(store: store)
        await center.start()
        center.requestAuthorization = { true }
        let container = UIContainerView(rootView: EditorNotificationSettings(center: center).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 650, height: 900)
        container.layoutIfNeeded()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Notifications.System"))
        for _ in 0..<100 where !center.preferences.systemEnabled { await Task.yield() }
        #expect(center.preferences.systemEnabled)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Notifications.Sound"))
        #expect(!center.preferences.soundEnabled)
        for source in EditorNotificationSource.allCases {
            _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Notifications.Source.\(source.rawValue)"))
            #expect(!center.preferences.enabledSources.contains(source))
        }
        for _ in 0..<100 {
            if try await store.load().preferences == center.preferences {
                break
            }
            await Task.yield()
        }
        let reloaded = EditorNotificationCenter(store: store)
        await reloaded.start()
        #expect(reloaded.preferences == center.preferences)
    }

    @Test("Task groups collapse and task rows dispatch exactly one action")
    func taskRunner() async throws {
        var calls: [String] = []
        let groups = EditorTaskRunnerGroup.swiftPackage(products: ["Game"])
        let container = UIContainerView(rootView: EditorTaskRunner(groups: groups, isEnabled: true, onRun: { calls.append($0) }).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 300, height: 800)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        #expect(container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.Tasks.Run.clean")).isEmpty)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Tasks.Run.build"))
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Tasks.Run.product:Game"))
        #expect(calls == ["build", "product:Game"])
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Tasks.Group.build"))
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Tasks.Group.maintenance"))
        for _ in 0..<10 {
            await Task.yield()
            container.update(1.0 / 60.0)
            container.layoutIfNeeded()
        }
        #expect(container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.Tasks.Run.build")).isEmpty)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Tasks.Run.clean"))
        #expect(calls.last == "clean")
        let disabled = UIContainerView(rootView: EditorTaskRunner(groups: groups, isEnabled: false, onRun: { calls.append($0) }))
        disabled.frame = container.frame
        disabled.layoutIfNeeded()
        _ = try disabled.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Tasks.Run.build"))
        #expect(calls.count == 3)
    }
}
