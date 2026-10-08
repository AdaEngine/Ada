@_spi(AdaEngine) import AdaEngine
import Foundation
import Observation

public struct EditorDisplayPreviewSettings: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable { case standard, foldable }
    public var mode: Mode = .standard
    public var expanded = false

    var layout: DisplayLayout? { mode == .standard ? nil : .foldable(expanded: expanded) }
}

@MainActor @Observable
final class EditorDisplayPreviewModel {
    var settings = EditorDisplayPreviewSettings()
    var fitsAvailableSpace = true
    var errorMessage: String?
    private var projectRoot: URL?

    func load(projectRoot: URL) {
        guard self.projectRoot != projectRoot else {
            return
        }
        self.projectRoot = projectRoot
        do {
            settings = try ProjectSystem.loadProject(at: projectRoot).editor.displayPreview ?? .init()
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func select(mode: EditorDisplayPreviewSettings.Mode) {
        settings.mode = mode
        save()
    }

    func toggleExpanded() {
        settings.expanded.toggle()
        save()
    }

    private func save() {
        guard let projectRoot else {
            return
        }
        do {
            var project = try ProjectSystem.loadProject(at: projectRoot)
            project.editor.displayPreview = settings
            try ProjectSystem.saveProject(project, at: projectRoot)
            errorMessage = nil
        } catch { errorMessage = "Display settings: \(error.localizedDescription)" }
    }
}

extension EditorSceneViewportView {
    var displayPreviewControls: some View {
        HStack(spacing: 8) {
            Text("Display").font(.system(size: 10))
            EditorEnumField(
                cases: ["Standard", "Foldable Preview"],
                selection: Binding(
                    get: { displayPreview.settings.mode == .standard ? "Standard" : "Foldable Preview" },
                    set: { displayPreview.select(mode: $0 == "Standard" ? .standard : .foldable) }
                )
            )
            .frame(width: 142)
            .accessibilityIdentifier("AdaEditor.Display.Mode")
            if displayPreview.settings.mode == .foldable {
                Button(displayPreview.settings.expanded ? "Expanded" : "Compact") {
                    displayPreview.toggleExpanded()
                }
                .accessibilityIdentifier("AdaEditor.Display.Posture")
                Button(displayPreview.fitsAvailableSpace ? "Fit" : "1:1") { displayPreview.fitsAvailableSpace.toggle() }
                    .accessibilityIdentifier("AdaEditor.Display.Fit")
            }
            if let error = displayPreview.errorMessage {
                Text(error).foregroundColor(.red).font(.system(size: 10))
            }
        }
    }
}
