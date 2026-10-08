import Foundation

@MainActor
final class EditorCloudPreferences {
    static let shared = EditorCloudPreferences()
    private final class Entry {
        weak var workbench: EditorWorkbenchViewModel?
        init(_ value: EditorWorkbenchViewModel) { workbench = value }
    }
    private var entries: [Entry] = []
    func register(_ workbench: EditorWorkbenchViewModel) {
        entries.removeAll { $0.workbench == nil }
        entries.append(Entry(workbench))
        if let value = UserDefaults.standard.object(forKey: "AdaEditor.editor.fontSize") as? Double, value.isFinite, (8...48).contains(value) {
            workbench.codeFontSize = value
        }
    }
    func apply(_ values: EditorCloudValue) {
        let size = values["editor.fontSize"] == .null ? 14 : values["editor.fontSize"].seconds
        guard size.isFinite, (8...48).contains(size) else {
            return
        }
        entries.removeAll { $0.workbench == nil }
        for entry in entries { entry.workbench?.codeFontSize = size }
    }
}
