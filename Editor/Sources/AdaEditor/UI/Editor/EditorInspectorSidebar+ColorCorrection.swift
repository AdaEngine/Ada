@_spi(AdaEngine) import AdaEngine

extension EditorInspectorSidebar {
    func colorCorrectionVisibleFields(_ component: EditorInspectorSidebarViewModel.ComponentSection) -> [EditorInspectorSidebarViewModel.ComponentField] {
        guard component.typeName == EditorBuiltInComponentType.environment3D else { return component.fields }
        let mode = component.fields.first { $0.field.key == "postProcess.colorGrading.correctionMode" }?.value ?? "lut"
        return component.fields.filter { EditorColorCorrectionFields.isVisible($0.field.key, mode: mode) }
    }
}

enum EditorColorCorrectionFields {
    static func isVisible(_ key: String, mode: String) -> Bool {
        switch key {
        case "postProcess.colorGrading.curves": mode == "curves"
        case "postProcess.colorGrading.lut": mode == "lut"
        case "postProcess.colorGrading.lutIntensity": mode != "disabled"
        default: true
        }
    }
}
