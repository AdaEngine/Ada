@_spi(AdaEngine) import AdaEngine
import AdaPackageManifestTool
import Foundation
import Observation

extension EditorWorkbenchViewModel {
    func sceneLines(for document: EditorSceneDocument) -> [String] {
        let lines = document.content.components(separatedBy: .newlines)
        return lines.isEmpty ? [""] : lines
    }

    func sceneLineBinding(documentID: String, lineIndex: Int) -> Binding<String> {
        Binding(
            get: {
                guard
                    let document = self.sceneDocument(id: documentID),
                    self.sceneLines(for: document).indices.contains(lineIndex)
                else {
                    return ""
                }

                return self.sceneLines(for: document)[lineIndex]
            },
            set: { newValue in
                self.updateSceneLine(documentID: documentID, lineIndex: lineIndex, value: newValue)
            }
        )
    }

    func textDocumentBinding(documentID: String) -> Binding<String> {
        Binding(
            get: {
                self.textDocument(id: documentID)?.content ?? ""
            },
            set: { newValue in
                guard self.textDocument(id: documentID)?.isReadOnly == false else {
                    return
                }
                self.updateTextDocument(id: documentID) { document in
                    document.content = newValue
                    document.errorMessage = nil
                    document.isDirty = true
                    document.statusMessage = "Edited"
                }
                self.refreshFileSearchSelection(documentID: documentID)
            }
        )
    }

    @discardableResult
    func saveActiveDocument() -> Bool {
        guard let activeDocument else {
            return false
        }

        return saveDocument(activeDocument)
    }

    @discardableResult
    func saveAllDocuments() -> Bool {
        var didSaveAll = true
        for document in openDocuments where document.isDirty {
            if !saveDocument(document) {
                didSaveAll = false
            }
        }
        return didSaveAll
    }

    @discardableResult
    func saveActiveDocumentIfNeeded() -> Bool {
        guard let activeDocument, activeDocument.isDirty else {
            return false
        }

        return saveDocument(activeDocument)
    }

    var activeDocumentSaveFailureDescription: String? {
        switch activeDocument {
        case let .scene(document):
            document.statusMessage ?? document.errorMessage
        case let .text(document),
            let .ui(document):
            document.statusMessage ?? document.errorMessage
        case .git:
            nil
        case .asset:
            "assets cannot be saved from the code editor"
        case nil:
            nil
        }
    }

    @discardableResult
    func saveDocument(_ document: EditorWorkbenchDocument) -> Bool {
        switch document {
        case let .scene(document):
            return saveSceneDocument(id: document.id)
        case let .ui(document):
            for sceneID in uiSceneModels[document.id]?.bindingSceneDocumentIDs ?? [] {
                if let scene = sceneDocument(id: sceneID), scene.isDirty, !saveSceneDocument(id: sceneID) {
                    updateTextDocument(id: document.id) { $0.statusMessage = "Unable to save the scene containing this UI's script bindings." }
                    return false
                }
            }
            return saveTextDocument(id: document.id)
        case let .text(document):
            return saveTextDocument(id: document.id)
        case .asset,
            .git:
            return false
        }
    }

    func appendSceneLine(documentID: String) {
        updateSceneDocument(id: documentID) { document in
            guard !document.isReadOnly else {
                document.statusMessage = "Edit blocked: file is read-only"
                return
            }
            document.content += document.content.hasSuffix("\n") ? "" : "\n"
            document.content += "  "
            document.isDirty = true
            document.statusMessage = "Edited"
            document.loadSummary = EditorSceneFileLoader.summary(from: document.content)
            document.sceneModel = EditorSceneFileLoader.model(from: document.content)
        }
    }

    @discardableResult
    func saveSceneDocument(id documentID: String) -> Bool {
        let previousContent = sceneDocument(id: documentID)?.lastSavedContent
        var didSave = false
        updateSceneDocument(id: documentID) { document in
            guard !document.isReadOnly else {
                document.statusMessage = "Save blocked: file is read-only"
                document.errorMessage = document.errorMessage ?? "Symbolic-link scene files are read-only in the editor."
                return
            }
            guard let absolutePath = document.absolutePath else {
                document.statusMessage = "Sample scene cannot be saved"
                return
            }

            do {
                let sceneModel = try EditorSceneModel.decode(from: document.content)
                if let lastSavedContent = document.lastSavedContent {
                    let currentDiskContent = try String(contentsOf: URL(fileURLWithPath: absolutePath), encoding: .utf8)
                    guard currentDiskContent == lastSavedContent else {
                        document.statusMessage = "Save blocked: file changed on disk"
                        document.errorMessage = "Reload the scene before overwriting external changes."
                        return
                    }
                }

                try document.content.write(to: URL(fileURLWithPath: absolutePath), atomically: true, encoding: .utf8)
                document.sceneModel = sceneModel
                document.loadSummary = EditorSceneFileLoader.summary(from: document.content)
                document.lastSavedContent = document.content
                document.isDirty = false
                document.errorMessage = nil
                document.statusMessage = "Saved"
                didSave = true
            } catch {
                document.statusMessage = "Save blocked"
                document.errorMessage = error.localizedDescription
            }
        }
        if didSave, let saved = sceneDocument(id: documentID) {
            recordAchievementSave(scene: saved, previousContent: previousContent)
        }
        return didSave
    }

    @discardableResult
    func saveTextDocument(id documentID: String) -> Bool {
        let previousContent = textDocument(id: documentID)?.lastSavedContent
        var didSave = false
        updateTextDocument(id: documentID) { document in
            guard !document.isReadOnly else {
                document.statusMessage = "Save blocked: file is read-only"
                document.errorMessage = document.errorMessage ?? "The file could not be decoded as UTF-8 and will not be overwritten."
                return
            }
            guard let absolutePath = document.absolutePath else {
                document.statusMessage = "Sample file cannot be saved"
                return
            }

            do {
                if let lastSavedContent = document.lastSavedContent {
                    let currentDiskContent = try String(contentsOf: URL(fileURLWithPath: absolutePath, isDirectory: false), encoding: .utf8)
                    guard currentDiskContent == lastSavedContent else {
                        document.statusMessage = "Save blocked: file changed on disk"
                        document.errorMessage = "Reload the file before overwriting external changes."
                        return
                    }
                }

                try document.content.write(to: URL(fileURLWithPath: absolutePath, isDirectory: false), atomically: true, encoding: .utf8)
                document.lastSavedContent = document.content
                document.isDirty = false
                document.errorMessage = nil
                document.statusMessage = "Saved"
                didSave = true
            } catch {
                document.statusMessage = "Save failed: \(error.localizedDescription)"
                document.errorMessage = error.localizedDescription
            }
        }
        if didSave, let saved = textDocument(id: documentID) {
            recordAchievementSave(text: saved, previousContent: previousContent)
        }
        return didSave
    }

    func replaceSceneDocument(_ document: EditorSceneDocument) {
        guard let index = openDocuments.firstIndex(where: { $0.id == document.id }) else {
            return
        }

        guard case var .scene(previousDocument) = openDocuments[index] else {
            return
        }
        guard !previousDocument.isReadOnly else {
            previousDocument.statusMessage = "Edit blocked: file is read-only"
            previousDocument.errorMessage = previousDocument.errorMessage ?? "Symbolic-link scene files are read-only in the editor."
            openDocuments[index] = .scene(previousDocument)
            notifyActiveDocumentChangedIfNeeded(documentID: document.id)
            return
        }

        recordSceneEdit(from: previousDocument, to: document)
        if document.statusMessage == "AdaScript field edited", document.content != previousDocument.content {
            achievementScriptEdits.insert(document.id)
        }
        openDocuments[index] = .scene(document)
        notifyActiveDocumentChangedIfNeeded(documentID: document.id)
        if document.isDirty,
            document.content != previousDocument.content || document.sceneModel != previousDocument.sceneModel || !previousDocument.isDirty {
            onDocumentEdited?(document.id)
        }
    }

    func addEntity(to documentID: String) {
        updateSceneModelDocument(id: documentID, status: "Entity added") { model in
            _ = model.addEntity()
        }
    }

    func selectSceneEntity(documentID: String, entityID: String?) {
        updateSceneModelDocument(id: documentID, status: "Selected") { model in
            model.selectEntity(entityID)
        }
    }

    func toggleSceneEntityExpanded(documentID: String, entityID: String) {
        updateSceneModelDocument(id: documentID, status: "Hierarchy updated") { model in
            model.toggleEntityExpanded(entityID)
        }
    }

    func addSceneEntity(documentID: String, parentID: String?) {
        updateSceneModelDocument(id: documentID, status: "Entity added") { model in
            _ = model.addEntity(name: "Entity", parentID: parentID)
        }
    }

    func presentEntityPicker(documentID: String, parentID: String?) {
        guard sceneDocument(id: documentID)?.isReadOnly == false else {
            return
        }
        entityPickerRequest = EditorEntityPickerRequest(documentID: documentID, parentID: parentID)
    }

    func addSceneEntity(
        documentID: String,
        parentID: String?,
        template: EditorSceneEntityTemplate
    ) {
        updateSceneModelDocument(id: documentID, status: "\(template.title) added") { model in
            _ = model.addEntity(template: template, parentID: parentID)
        }
        entityPickerRequest = nil
    }

    func renameSceneEntity(documentID: String, entityID: String, name: String) {
        updateSceneModelDocument(id: documentID, status: "Entity renamed") { model in
            _ = model.renameEntity(entityID, to: name)
        }
    }

    func setSceneEntityEnabled(documentID: String, entityID: String, isEnabled: Bool) {
        updateSceneModelDocument(id: documentID, status: isEnabled ? "Entity shown" : "Entity hidden") { model in
            _ = model.setEntityEnabled(entityID, isEnabled: isEnabled)
        }
    }

    func deleteSceneEntity(documentID: String, entityID: String) {
        updateSceneModelDocument(id: documentID, status: "Entity deleted") { model in
            _ = model.deleteEntity(entityID)
        }
    }

    func duplicateSceneEntity(documentID: String, entityID: String) {
        updateSceneModelDocument(id: documentID, status: "Entity duplicated") { model in
            _ = model.duplicateEntity(entityID)
        }
    }

    @discardableResult
    func copySceneEntity(documentID: String, entityID: String) -> Bool {
        guard
            let model = sceneDocument(id: documentID)?.sceneModel,
            let payload = model.clipboardPayload(for: entityID)
        else {
            return false
        }
        UIClipboard.setString(payload)
        return true
    }

    @discardableResult
    func pasteSceneEntity(documentID: String, parentID: String?) -> Bool {
        guard
            let payload = UIClipboard.getString(),
            EditorSceneModel.canPasteEntityPayload(payload)
        else {
            return false
        }
        var didPaste = false
        updateSceneModelDocument(id: documentID, status: "Entity pasted") { model in
            didPaste = model.pasteEntity(from: payload, parentID: parentID) != nil
        }
        return didPaste
    }

    func reparentSceneEntity(documentID: String, entityID: String, parentID: String) {
        updateSceneModelDocument(id: documentID, status: "Entity reparented") { model in
            _ = model.reparentEntity(entityID, to: parentID)
        }
    }

    func addComponent(typeName: String, toSelectedEntityIn documentID: String) {
        updateSceneModelDocument(id: documentID, status: "Component added") { model in
            guard let selectedEntityID = model.editor?.selectedEntity else {
                return
            }
            model.addComponent(typeName: typeName, to: selectedEntityID)
        }
    }

    func removeComponent(typeName: String, fromSelectedEntityIn documentID: String) {
        updateSceneModelDocument(id: documentID, status: "Component removed") { model in
            guard let selectedEntityID = model.editor?.selectedEntity else {
                return
            }
            model.removeComponent(typeName: typeName, from: selectedEntityID)
        }
    }

    func updateComponentField(
        typeName: String,
        field: EditorComponentField,
        value: String,
        inSelectedEntityOf documentID: String
    ) {
        updateSceneModelDocument(id: documentID, status: "Edited") { model in
            guard let selectedEntityID = model.editor?.selectedEntity else {
                return
            }
            model.updateField(typeName: typeName, field: field, value: value, in: selectedEntityID)
        }
    }

    func sceneDocument(id documentID: String) -> EditorSceneDocument? {
        guard case let .scene(document)? = openDocuments.first(where: { $0.id == documentID }) else {
            return nil
        }

        return document
    }

    func textDocument(id documentID: String) -> EditorTextDocument? {
        switch openDocuments.first(where: { $0.id == documentID }) {
        case let .text(document),
            let .ui(document):
            return document
        default: return nil
        }
    }

    func updateSceneLine(documentID: String, lineIndex: Int, value: String) {
        updateSceneDocument(id: documentID) { document in
            guard !document.isReadOnly else {
                document.statusMessage = "Edit blocked: file is read-only"
                return
            }
            var lines = document.content.components(separatedBy: .newlines)
            guard lines.indices.contains(lineIndex) else {
                return
            }

            lines[lineIndex] = value
            document.content = lines.joined(separator: "\n")
            document.isDirty = true
            document.statusMessage = "Edited"
            document.errorMessage = nil
            document.loadSummary = EditorSceneFileLoader.summary(from: document.content)
            document.sceneModel = EditorSceneFileLoader.model(from: document.content)
        }
    }

    func updateSceneModelDocument(id documentID: String, status: String, update: (inout EditorSceneModel) -> Void) {
        updateSceneDocument(id: documentID) { document in
            guard !document.isReadOnly else {
                document.statusMessage = "Edit blocked: file is read-only"
                return
            }
            guard var model = document.sceneModel ?? EditorSceneFileLoader.model(from: document.content) else {
                document.statusMessage = "Scene model unavailable"
                return
            }

            update(&model)

            do {
                document.sceneModel = model
                document.content = try model.encodedYAML()
                document.loadSummary = EditorSceneFileLoader.summary(from: document.content)
                document.isDirty = true
                document.statusMessage = status
                document.errorMessage = nil
            } catch {
                document.statusMessage = "Scene encode failed"
                document.errorMessage = error.localizedDescription
            }
        }
    }

    func updateSceneDocument(id documentID: String, update: (inout EditorSceneDocument) -> Void) {
        guard let index = openDocuments.firstIndex(where: { $0.id == documentID }) else {
            return
        }

        guard case var .scene(document) = openDocuments[index] else {
            return
        }

        let previousDocument = document
        let previousContent = document.content
        let wasDirty = document.isDirty
        update(&document)
        recordSceneEdit(from: previousDocument, to: document)
        openDocuments[index] = .scene(document)
        notifyActiveDocumentChangedIfNeeded(documentID: documentID)
        if document.isDirty, document.content != previousContent || !wasDirty {
            onDocumentEdited?(documentID)
        }
    }

    func updateTextDocument(id documentID: String, update: (inout EditorTextDocument) -> Void) {
        guard let index = openDocuments.firstIndex(where: { $0.id == documentID }) else {
            return
        }

        guard var document = textDocument(id: documentID) else {
            return
        }
        let isUI: Bool
        if case .ui = openDocuments[index] {
            isUI = true
        } else {
            isUI = false
        }

        let previousContent = document.content
        let wasDirty = document.isDirty
        update(&document)
        if document.content != previousContent {
            document.semanticTokens = []
        }
        openDocuments[index] = isUI ? .ui(document) : .text(document)
        notifyActiveDocumentChangedIfNeeded(documentID: documentID)
        if document.isDirty, document.content != previousContent || !wasDirty {
            onDocumentEdited?(documentID)
        }
    }

    /// Only accept token coordinates for the exact text used by the language service.
    func applySemanticTokens(_ tokens: [EditorSemanticToken], documentID: String, source: String) {
        guard textDocument(id: documentID)?.content == source else {
            return
        }
        updateTextDocument(id: documentID) { $0.semanticTokens = tokens }
    }

    func notifyActiveDocumentChangedIfNeeded(documentID: String) {
        guard activeDocumentID == documentID else {
            return
        }

        onActiveDocumentChanged?()
    }
}
