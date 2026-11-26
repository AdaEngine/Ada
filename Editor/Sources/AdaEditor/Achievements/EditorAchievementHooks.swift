@_spi(AdaEngine) import AdaEngine
import Foundation

extension EditorWorkbenchViewModel {
    func recordAchievementSave(scene: EditorSceneDocument, previousContent: String?) {
        guard let achievements, let path = scene.absolutePath, let model = scene.sceneModel else {
            return
        }
        let changed = previousContent != scene.content
        let redone = achievementRedos.remove(scene.id) != nil
        let scriptEdited = achievementScriptEdits.remove(scene.id) != nil && achievementAdaScriptProject
        guard changed else {
            achievements.record(redone ? [.redo: 1] : [:])
            return
        }
        let previous = previousContent.flatMap { content in
            let undo = sceneUndoHistory[scene.id]?.last { $0.content == content }?.sceneModel
            return undo ?? sceneRedoHistory[scene.id]?.last { $0.content == content }?.sceneModel
        }
        let root = achievementResourceRoot
        let date = Date()
        let profileID = achievements.profileID
        Task { [weak achievements] in
            let values = await Self.savedSceneAchievementValues(
                model,
                content: scene.content,
                previous: previous,
                previousContent: previousContent,
                scriptEdited: scriptEdited,
                source: URL(fileURLWithPath: path),
                root: root
            )
            guard let achievements, achievements.profileID == profileID else {
                return
            }
            achievements.record(values, date: date)
        }
        achievements.record(redone ? [.redo: 1] : [:], date: date, activeDay: true)
    }

    @concurrent
    nonisolated private static func savedSceneAchievementValues(
        _ model: EditorSceneModel,
        content: String,
        previous: EditorSceneModel?,
        previousContent: String?,
        scriptEdited: Bool,
        source: URL,
        root: URL?
    ) async -> [EditorAchievementID: Int] {
        guard previousContent.map({ EditorSceneModel.onlyEditorStateChanged(from: $0, to: content) }) != true else {
            return [:]
        }
        let previous = previous ?? previousContent.flatMap { try? EditorSceneModel.decode(from: $0) }
        var values = EditorAchievementRules.savedScene(model, previous: previous, source: source, resourceRoot: root)
        if scriptEdited, let previous {
            let key = EditorBuiltInComponentType.scriptableComponents
            let previousEntities = Dictionary(previous.entities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            if model.entities.contains(where: { entity in
                guard let old = previousEntities[entity.id], let scripts = entity.components[key] else {
                    return false
                }
                return scripts != old.components[key]
            }) {
                values[.scriptField] = 1
            }
        }
        return values
    }

    func recordAchievementSave(text: EditorTextDocument, previousContent: String?) {
        guard let achievements else {
            return
        }
        var values: [EditorAchievementID: Int] = [:]
        let changed = previousContent != text.content
        if changed, text.absolutePath?.hasSuffix(".ui") == true,
            let ui = try? UISceneDocument.decode(text.content) {
            values = EditorAchievementRules.savedUI(ui, previous: previousContent.flatMap { try? UISceneDocument.decode($0) })
        }
        if achievementRedos.remove(text.id) != nil {
            values[.redo] = 1
        }
        achievements.record(values, activeDay: changed)
    }
}
