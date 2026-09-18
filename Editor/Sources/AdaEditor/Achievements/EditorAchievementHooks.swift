@_spi(AdaEngine) import AdaEngine
import Foundation

extension EditorWorkbenchViewModel {
    func recordAchievementSave(scene: EditorSceneDocument, previousContent: String?) {
        guard let achievements, let path = scene.absolutePath, let model = scene.sceneModel else {
            return
        }
        var values: [EditorAchievementID: Int] = [:]
        let changed = previousContent != scene.content
        if changed {
            let previous = previousContent.flatMap { try? EditorSceneModel.decode(from: $0) }
            values = EditorAchievementRules.savedScene(
                model,
                previous: previous,
                source: URL(fileURLWithPath: path),
                resourceRoot: achievementResourceRoot
            )
            if achievementAdaScriptProject, achievementScriptEdits.contains(scene.id),
                model.entities.contains(where: { entity in
                    guard
                        let old = previous?.entities.first(where: { $0.id == entity.id }),
                        let scripts = entity.components[EditorBuiltInComponentType.scriptableComponents]
                    else {
                        return false
                    }
                    return scripts != old.components[EditorBuiltInComponentType.scriptableComponents]
                }) {
                values[.scriptField] = 1
            }
        }
        if achievementRedos.remove(scene.id) != nil {
            values[.redo] = 1
        }
        achievementScriptEdits.remove(scene.id)
        achievements.record(values, activeDay: changed)
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
