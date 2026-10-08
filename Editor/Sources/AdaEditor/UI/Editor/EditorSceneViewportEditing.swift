@_spi(AdaEngine) import AdaEngine
import Foundation

extension EditorSceneViewportView {
    func configureViewportModel() {
        let viewportModel = viewportModel
        let inspectorViewModel = inspectorViewModel
        let document = document
        let onDocumentChanged = onDocumentChanged
        let viewProxy = viewProxy

        let loadResult = viewportModel.configure(
            sceneContent: document.content,
            sourceURL: document.absolutePath.map { URL(fileURLWithPath: $0) },
            resourceRootURL: resourceRootURL,
            scriptableObjectCatalog: inspectorViewModel.scriptableObjectCatalog,
            onSelectionChanged: { [weak inspectorViewModel] selection in
                inspectorViewModel?.selectEntity(selection)
                if selection != nil {
                    onEntitySelected?()
                }
            },
            onDocumentContentChanged: { content in
                var updatedDocument = document
                updatedDocument.content = content
                updatedDocument.sceneModel = EditorSceneFileLoader.model(from: content)
                updatedDocument.isDirty = true
                updatedDocument.statusMessage = "Edited"
                updatedDocument.errorMessage = nil
                updatedDocument.loadSummary = EditorSceneFileLoader.summary(from: content)
                onDocumentChanged(updatedDocument)
            },
            onTransformChanged: { [weak inspectorViewModel] editorID, payload in
                inspectorViewModel?.updateLiveTransform(editorID: editorID, payload: payload)
            }
        )
        if let loadResult, runtimeWarnings != loadResult.warnings {
            runtimeWarnings = loadResult.warnings
            viewProxy.redraw()
        }
        inspectorViewModel.setSceneViewportActions(
            owner: viewportModel,
            applyGizmoChange: { [weak viewportModel] gizmo in
                guard let viewportModel else {
                    return
                }
                viewportModel.updateSelectedGizmo(gizmo)
                viewProxy.redraw()
            },
            addEntity: { preset in
                Self.mutateSceneDocument(document: document, status: "Entity added", onDocumentChanged: onDocumentChanged) { model in
                    _ = model.addEntity(preset: preset)
                }
            },
            addComponent: { typeName in
                Self.mutateSceneDocument(document: document, status: "Component added", onDocumentChanged: onDocumentChanged) { model in
                    guard let selectedEntityID = model.editor?.selectedEntity else {
                        return
                    }
                    model.addComponent(typeName: typeName, to: selectedEntityID)
                }
            },
            removeComponent: { typeName in
                Self.mutateSceneDocument(document: document, status: "Component removed", onDocumentChanged: onDocumentChanged) { model in
                    guard let selectedEntityID = model.editor?.selectedEntity else {
                        return
                    }
                    model.removeComponent(typeName: typeName, from: selectedEntityID)
                }
            },
            updateComponentField: { typeName, field, value in
                Self.mutateSceneDocument(document: document, status: "Edited", onDocumentChanged: onDocumentChanged) { model in
                    guard let selectedEntityID = model.editor?.selectedEntity else {
                        return
                    }
                    model.updateField(typeName: typeName, field: field, value: value, in: selectedEntityID)
                }
            },
            addScriptableObject: { descriptor in
                Self.mutateSceneDocument(document: document, status: "Scriptable object added", onDocumentChanged: onDocumentChanged) { model in
                    guard let selectedEntityID = model.editor?.selectedEntity else {
                        return
                    }
                    model.addScriptableObject(descriptor, to: selectedEntityID)
                }
            },
            removeScriptableObject: { identifier in
                Self.mutateSceneDocument(document: document, status: "Scriptable object removed", onDocumentChanged: onDocumentChanged) { model in
                    guard let selectedEntityID = model.editor?.selectedEntity else {
                        return
                    }
                    model.removeScriptableObject(identifier: identifier, from: selectedEntityID)
                }
            },
            updateScriptableObjectField: { identifier, field, value in
                Self.mutateSceneDocument(document: document, status: "AdaScript field edited", onDocumentChanged: onDocumentChanged) { model in
                    guard let selectedEntityID = model.editor?.selectedEntity else {
                        return
                    }
                    model.updateScriptableObjectField(identifier: identifier, field: field, value: value, in: selectedEntityID)
                }
            }
        )
    }

    func preparePlayModeViewport() {
        viewportModel.disconnect()
        inspectorViewModel.clearSceneViewportActions(owner: viewportModel)
    }

    func redrawViewport() {
        // Drawing invalidation alone does not rebuild the ruler labels inside GeometryReader.
        viewportRevision &+= 1
        viewProxy.redraw()
    }

    func mutateSceneDocument(status: String, update: (inout EditorSceneModel) -> Void) {
        Self.mutateSceneDocument(document: document, status: status, onDocumentChanged: onDocumentChanged, update: update)
    }

    static func mutateSceneDocument(
        document: EditorSceneDocument,
        status: String,
        onDocumentChanged: (EditorSceneDocument) -> Void,
        update: (inout EditorSceneModel) -> Void
    ) {
        guard var model = document.sceneModel ?? EditorSceneFileLoader.model(from: document.content) else {
            return
        }

        update(&model)
        guard let content = try? model.encodedYAML() else {
            return
        }

        var updatedDocument = document
        updatedDocument.sceneModel = model
        updatedDocument.content = content
        updatedDocument.isDirty = true
        updatedDocument.statusMessage = status
        updatedDocument.errorMessage = nil
        updatedDocument.loadSummary = EditorSceneFileLoader.summary(from: content)
        onDocumentChanged(updatedDocument)
    }
}
