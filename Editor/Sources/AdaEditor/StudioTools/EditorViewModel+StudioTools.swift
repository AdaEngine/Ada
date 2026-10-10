import Foundation

extension EditorViewModel {
    func startStudioTools() {
        #if os(macOS)
            guard let projectURL else {
                return
            }
            if !toolStrip.rightTools.contains(where: { $0.identifier == "studioTools" }) {
                toolStrip.rightTools.append(.init(identifier: "studioTools", title: "Studio Tools", icon: "\u{E869}"))
            }
            studioTools.open(projectURL: projectURL, editor: self)
        #endif
    }

    func scheduleStudioToolReload(documentID: String) {
        guard let document = workbench.openDocuments.first(where: { $0.id == documentID }), document.relativePath.hasPrefix("Tools/") else {
            return
        }
        studioTools.scheduleReload()
    }

    func presentSceneInspectorForSelection() {
        // Tools remain available while selecting entities or refreshing a scene.
        // The Inspector button and explicit menu command still open Inspector.
        guard toolStrip.activeRightTool != "studioTools" else {
            return
        }
        presentSceneInspector()
    }
}
