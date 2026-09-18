@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

@MainActor @Suite(.serialized)
struct EditorAchievementTests {
    @Test func catalogIsCompleteAndFitsGameCenter() {
        let catalog = EditorAchievement.catalog
        #expect(catalog.count == 26)
        #expect(Set(catalog.map(\.id)) == Set(EditorAchievementID.allCases))
        #expect(Set(catalog.map(\.gameCenterID)).count == 26)
        #expect(catalog.filter(\.secret).count == 6)
        #expect(catalog.reduce(0) { $0 + $1.points } <= 1000)
        #expect(catalog.allSatisfy { $0.points > 0 && $0.points <= 100 && $0.goal > 0 })
    }

    @Test func progressPersistsAndNeverRepeatsNotification() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("progress.json")
        let center = EditorAchievementCenter(url: url)
        var rewards: [EditorAchievementID] = []
        center.onEarned = { rewards.append($0.id) }
        center.record([.population: 25])
        center.record([.population: 50])
        center.record([.population: 100])
        center.record([.population: 1])
        #expect(rewards == [.population])
        let restored = EditorAchievementCenter(url: url)
        #expect(restored.progress(.population) == center.progress(.population))
        #expect(restored.progress(.population).value == 50)
        #expect(restored.storageError == nil)
    }

    @Test func activeDaysAreUniqueAndNeedNoStreak() throws {
        let center = EditorAchievementCenter()
        let start = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 12)))
        for day in 0..<7 {
            let date = try #require(Calendar.current.date(byAdding: .day, value: day * 3, to: start))
            center.record([:], date: date, activeDay: true)
            center.record([:], date: date, activeDay: true)
        }
        #expect(center.progress(.activeDays).value == 7)
        #expect(center.progress(.activeDays).earnedAt != nil)
    }

    @Test func accountsDoNotShareProgressAndGuestIsClaimedOnce() {
        let center = EditorAchievementCenter()
        center.record([.firstProject: 1])
        center.selectPlayer("A")
        #expect(center.progress(.firstProject).earnedAt != nil)
        center.record([.firstRun: 1])
        center.selectPlayer("B")
        #expect(center.earnedCount == 0)
        center.selectPlayer(nil)
        center.record([.firstUI: 1])
        center.selectPlayer("B")
        #expect(center.earnedCount == 0)
        center.selectPlayer("A")
        #expect(center.earnedCount == 2)
    }

    @Test func corruptedStorageIsPreserved() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("progress.json")
        let invalid = Data("not JSON".utf8)
        try invalid.write(to: url)
        let center = EditorAchievementCenter(url: url)
        center.record([.firstProject: 1])
        #expect(center.storageError != nil)
        #expect(try Data(contentsOf: url) == invalid)
    }

    @Test func offlineRelaunchKeepsLastPlayerAndNotificationPreference() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("progress.json")
        let center = EditorAchievementCenter(url: url)
        center.selectPlayer("A")
        center.record([.firstRun: 1])
        center.setNotificationsEnabled(false)
        let restored = EditorAchievementCenter(url: url)
        #expect(restored.profileID == "gamecenter:A")
        #expect(restored.progress(.firstRun).earnedAt != nil)
        #expect(!restored.notificationsEnabled)
        restored.record([.firstScene: 1])
        restored.selectPlayer("B")
        #expect(restored.earnedCount == 0)
        restored.selectPlayer("A")
        #expect(restored.earnedCount == 2)
    }

    @Test func invalidScriptBindingDoesNotEarnConnected() throws {
        var scene = EditorSceneModel.default(projectName: "Bindings")
        let entity = scene.addEntity()
        let index = try #require(scene.entities.firstIndex { $0.id == entity.id })
        let binding = try #require(
            String(bytes: JSONEncoder().encode(["value": UIScriptFieldBinding(script: "Counter", field: "count")]), encoding: .utf8)
        )
        scene.entities[index].components[EditorBuiltInComponentType.uiComponent] = ["scriptBindings": .string(binding)]
        #expect(EditorAchievementRules.playedScene(scene, adaScript: true)[.binding] == nil)
        scene.entities[index].components[EditorBuiltInComponentType.scriptableComponents] = [
            "scripts": .array([
                .object(["type": .string("Counter"), "payload": .object(["count": .int(0)])])
            ])
        ]
        #expect(EditorAchievementRules.playedScene(scene, adaScript: true)[.binding] == 1)
        #expect(EditorAchievementRules.playedScene(scene, adaScript: false)[.binding] == nil)
    }

    @Test func syncMergesRemoteWithoutBannersAndRetriesFailures() async throws {
        let center = EditorAchievementCenter()
        let provider = AchievementTestProvider()
        center.install(provider)
        center.connect()
        var banners = 0
        center.onEarned = { _ in banners += 1 }
        provider.remote = [.population: 100]
        provider.failReports = true
        center.record([.firstProject: 1, .answer42: 1])
        try await waitUntil { provider.reports.count == 1 && !center.isSyncing }
        #expect(center.progress(.population).earnedAt != nil)
        #expect(banners == 2)
        #expect(center.status.contains("Saved locally"))
        provider.failReports = false
        center.synchronize()
        try await waitUntil { provider.reports.count == 2 && !center.isSyncing }
        #expect(provider.reports.last?[.answer42] == 100)
        #expect(provider.reports.last?[.population] == nil)
        #expect(center.status.contains("Synced"))
        #expect(banners == 2)
    }

    @Test func accountSwitchDuringLoadDiscardsOldResponse() async throws {
        let center = EditorAchievementCenter()
        let provider = AchievementTestProvider()
        provider.pauseLoad = true
        center.install(provider)
        center.connect()
        try await waitUntil { provider.continuation != nil }
        provider.playerID = "B"
        provider.onPlayerChanged?("B")
        provider.continuation?.resume(returning: [.firstProject: 100])
        provider.continuation = nil
        provider.pauseLoad = false
        try await waitUntil { provider.loads == 2 && !center.isSyncing }
        #expect(center.earnedCount == 0)
        #expect(provider.reports.isEmpty)
    }

    @Test func successfulSaveAwardsButConflictReadOnlyAndNoOpDoNot() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var model = EditorSceneModel.default(projectName: "Achievements")
        let url = root.appendingPathComponent("Main.ascn")
        let original = try model.encodedYAML()
        try original.write(to: url, atomically: true, encoding: .utf8)
        let center = EditorAchievementCenter()
        let workbench = makeWorkbench(model, url: url, content: original, center: center)
        #expect(workbench.saveActiveDocument())
        #expect(center.earnedCount == 0)
        workbench.addEntity(to: "scene")
        try "external edit".write(to: url, atomically: true, encoding: .utf8)
        #expect(!workbench.saveActiveDocument())
        #expect(center.earnedCount == 0)
        try original.write(to: url, atomically: true, encoding: .utf8)
        #expect(workbench.saveActiveDocument())
        #expect(center.progress(.firstScene).earnedAt != nil)
        #expect(center.progress(.activeDays).value == 1)
        let separate = EditorAchievementCenter()
        model.addEntity()
        let readOnly = makeWorkbench(model, url: url, content: try model.encodedYAML(), center: separate)
        readOnly.updateSceneDocument(id: "scene") { $0.isReadOnly = true }
        #expect(!readOnly.saveActiveDocument())
        #expect(separate.earnedCount == 0)
    }

    @Test func undoRedoSaveUsesRealHistory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = EditorSceneModel.default(projectName: "History")
        let content = try model.encodedYAML()
        let url = root.appendingPathComponent("Main.ascn")
        try content.write(to: url, atomically: true, encoding: .utf8)
        let center = EditorAchievementCenter()
        let workbench = makeWorkbench(model, url: url, content: content, center: center)
        #expect(!workbench.performDocumentHistory(redo: true))
        workbench.addEntity(to: "scene")
        #expect(workbench.performDocumentHistory(redo: false))
        #expect(workbench.performDocumentHistory(redo: true))
        #expect(center.progress(.redo).earnedAt == nil)
        #expect(workbench.saveActiveDocument())
        #expect(center.progress(.redo).earnedAt != nil)
    }

    @Test func populationAndPhysicsUseActualSceneValues() throws {
        var scene = EditorSceneModel.default(projectName: "Rules")
        scene.entities = Array(scene.entities.prefix(1))
        for _ in 0..<42 { scene.addEntity() }
        let values = EditorAchievementRules.savedScene(scene, previous: nil, source: URL(fileURLWithPath: "/tmp/Main.ascn"), resourceRoot: nil)
        #expect(values[.answer42] == 1)
        #expect(values[.population] == 42)
        let apple = scene.addEntity(name: "Apple")
        scene.addComponent(typeName: EditorBuiltInComponentType.physicsBody2D, to: apple.id)
        #expect(EditorAchievementRules.playedScene(scene, adaScript: false)[.newton] == 1)
        scene.entities[scene.entities.count - 1].components[EditorBuiltInComponentType.physicsBody2D]?["shapes"] = .array([])
        #expect(EditorAchievementRules.playedScene(scene, adaScript: false)[.newton] == nil)
    }

    @Test func nestedScenesResolveFilesAndRejectCycles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        func nested(_ name: String, reference: String?) -> EditorSceneModel {
            var model = EditorSceneModel.default(projectName: name)
            if let reference {
                let child = model.addSceneInstance(parentID: model.rootEntityID)
                let index = model.entities.firstIndex { $0.id == child.id } ?? 0
                model.entities[index].components[EditorBuiltInComponentType.sceneInstance] = ["scene": .string(reference)]
            }
            return model
        }
        let a = nested("A", reference: "B.ascn")
        let b = nested("B", reference: "C.ascn")
        let c = nested("C", reference: nil)
        for (name, model) in [("A", a), ("B", b), ("C", c)] {
            try model.encodedYAML().write(to: root.appendingPathComponent("\(name).ascn"), atomically: true, encoding: .utf8)
        }
        let source = root.appendingPathComponent("A.ascn")
        #expect(EditorAchievementRules.savedScene(a, previous: nil, source: source, resourceRoot: root)[.inception] == 1)
        try nested("B", reference: "A.ascn").encodedYAML().write(to: root.appendingPathComponent("B.ascn"), atomically: true, encoding: .utf8)
        #expect(EditorAchievementRules.savedScene(a, previous: nil, source: source, resourceRoot: root)[.inception] == nil)
    }

    @Test func uiFileSaveEvaluatesNestedLayoutAndGreeting() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try UISceneDocument().encodedYAML()
        let ui = UISceneDocument(
            root: .init(
                type: "VStack",
                children: [
                    .init(
                        type: "HStack",
                        children: (0..<5).map { _ in .init(type: "Text", arguments: ["text": .init(value: .string("Hello, Ada!"))]) }
                    )
                ]
            )
        )
        let url = root.appendingPathComponent("Screen.ui")
        try original.write(to: url, atomically: true, encoding: .utf8)
        let text = EditorTextDocument(
            id: "ui",
            title: "Screen.ui",
            relativePath: "Screen.ui",
            absolutePath: url.path,
            language: .plainText,
            content: try ui.encodedYAML(),
            lastSavedContent: original,
            isDirty: true
        )
        let center = EditorAchievementCenter()
        let workbench = EditorWorkbenchViewModel(openDocuments: [.ui(text)], activeDocumentID: "ui")
        workbench.achievements = center
        #expect(workbench.saveActiveDocument())
        #expect(center.progress(.firstUI).earnedAt != nil)
        #expect(center.progress(.layout).earnedAt != nil)
        #expect(center.progress(.helloAda).earnedAt != nil)
    }

    @Test func settingsRenderAndConnectButtonUsesProvider() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "AchievementsUI")))
        }
        let center = EditorAchievementCenter()
        let provider = AchievementTestProvider()
        center.install(provider)
        let container = UIContainerView(rootView: EditorAchievementSettings(center: center).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 720, height: 3000)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Achievements.Row.20"))
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Achievements.Connect"))
        #expect(provider.authenticationCount == 1)
        #expect(center.isConnected)
        #expect(EditorSettingsWindowViewModel(editorViewModel: nil, selectedSection: .achievements).filteredSections.contains(.achievements))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("achievements-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeWorkbench(_ scene: EditorSceneModel, url: URL, content: String, center: EditorAchievementCenter) -> EditorWorkbenchViewModel {
        let document = EditorSceneDocument(
            id: "scene",
            title: "Main.ascn",
            relativePath: "Main.ascn",
            absolutePath: url.path,
            content: content,
            lastSavedContent: content,
            sceneModel: scene,
            isDirty: false,
            loadSummary: .empty
        )
        let workbench = EditorWorkbenchViewModel(openDocuments: [.scene(document)], activeDocumentID: "scene")
        workbench.achievements = center
        return workbench
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
}

@MainActor
private final class AchievementTestProvider: EditorAchievementProvider {
    var playerID: String?
    var onPlayerChanged: ((String?) -> Void)?
    var authenticationCount = 0
    var remote: [EditorAchievementID: Double] = [:]
    var reports: [[EditorAchievementID: Double]] = []
    var failReports = false
    var pauseLoad = false
    var loads = 0
    var continuation: CheckedContinuation<[EditorAchievementID: Double], Never>?

    func authenticate() {
        authenticationCount += 1
        playerID = "A"
        onPlayerChanged?(playerID)
    }
    func load() async throws -> [EditorAchievementID: Double] {
        loads += 1
        if pauseLoad {
            return await withCheckedContinuation { continuation = $0 }
        }
        return remote
    }
    func report(_ progress: [EditorAchievementID: Double]) async throws {
        reports.append(progress)
        if failReports {
            throw CocoaError(.fileReadUnknown)
        }
        remote.merge(progress) { max($0, $1) }
    }
    func showAchievements() {}
}
