@_spi(AdaEngine) import AdaEngine

@MainActor
enum EditorHistoryShortcuts {
    static func actions(_ perform: @escaping (EditorMenuCommand) -> Void) -> [KeyboardShortcutAction] {
        // The shortcut matcher accepts additional modifiers: match redo before undo.
        [
            KeyboardShortcutAction(.z, modifiers: [.command, .alt]) { perform(.redo) },
            KeyboardShortcutAction(.z, modifiers: [.command, .shift]) { perform(.redo) },
            KeyboardShortcutAction(.z, modifiers: .command) { perform(.undo) },
        ]
    }
}

extension EditorWorkbenchViewModel {
    func recordSceneEdit(from previous: EditorSceneDocument, to updated: EditorSceneDocument) {
        guard !previous.isReadOnly, previous.content != updated.content else {
            return
        }
        if updated.statusMessage == "Reloaded" {
            sceneUndoHistory[previous.id] = nil
            sceneRedoHistory[previous.id] = nil
            return
        }
        // Selection, foldouts and viewport state are persisted but are not undo steps.
        if var before = previous.sceneModel, var after = updated.sceneModel {
            before.editor = nil
            after.editor = nil
            guard before != after else {
                return
            }
        }
        sceneUndoHistory[previous.id, default: []].append(previous)
        if sceneUndoHistory[previous.id, default: []].count > 100 {
            sceneUndoHistory[previous.id]?.removeFirst()
        }
        sceneRedoHistory[previous.id] = nil
    }

    @discardableResult
    func performDocumentHistory(redo: Bool) -> Bool {
        switch activeDocument {
        case let .ui(document):
            guard !document.isReadOnly, let model = uiSceneModels[document.id] else {
                return false
            }
            guard redo ? model.canRedo : model.canUndo else {
                return false
            }
            if redo {
                model.redo()
            } else {
                model.undo()
            }
            if redo {
                achievementRedos.insert(document.id)
            } else {
                achievementRedos.remove(document.id)
            }
            return true
        case let .scene(current):
            guard
                !current.isReadOnly,
                let index = openDocuments.firstIndex(where: { $0.id == current.id })
            else {
                return false
            }
            let snapshot = redo ? sceneRedoHistory[current.id]?.popLast() : sceneUndoHistory[current.id]?.popLast()
            guard var restored = snapshot else {
                return false
            }
            if redo {
                sceneUndoHistory[current.id, default: []].append(current)
            } else {
                sceneRedoHistory[current.id, default: []].append(current)
            }
            // Saving after an edit must not roll the saved baseline back with the content.
            restored.lastSavedContent = current.lastSavedContent
            restored.isDirty = restored.content != current.lastSavedContent
            restored.statusMessage = redo ? "Redo" : "Undo"
            if redo {
                achievementRedos.insert(current.id)
            } else {
                achievementRedos.remove(current.id)
            }
            openDocuments[index] = .scene(restored)
            notifyActiveDocumentChangedIfNeeded(documentID: current.id)
            onDocumentEdited?(current.id)
            return true
        default:
            return false
        }
    }
}
