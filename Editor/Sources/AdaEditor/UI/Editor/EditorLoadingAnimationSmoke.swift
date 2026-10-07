#if DEBUG && os(macOS)
@_spi(AdaEngine) import AdaEngine
import Foundation
import Math

/// Native idle-frame QA; no agent, project, or input activity drives these indicators.
struct EditorLoadingAnimationSmoke: View {
    @State private var model: EditorViewModel
    init() {
        let agent = EditorAgentViewModel(project: nil, settings: EditorAgentSettingsStore())
        agent.isSending = true
        let editor = EditorViewModel(project: nil, agent: agent)
        editor.showRightPanel = true
        editor.toolStrip.activeRightTool = "agentChat"
        _model = State(initialValue: editor)
        editor.workspaceStatus = .running("Animation QA")
    }
    var body: some View {
        EditorView(project: nil, viewModel: model)
            .theme(.adaEditor)
            .task { await verify() }
    }
    @MainActor private func verify() async {
        do {
            try await Task.sleep(for: .milliseconds(500))
            guard let window = UIWindowManager.shared?.activeWindow ?? UIWindowManager.shared?.windows.values.first?.value,
                  let view = window.uiInspectableContainers().first as? UIView else { throw UIDiagnostic("Window missing") }
            model.workspaceStatus = .running("Animation QA")
            model.footer.leftItems.append("Animation reconciliation QA")
            try await Task.sleep(for: .milliseconds(150))
            let first = paths(view)
            try await Task.sleep(for: .milliseconds(230))
            let second = paths(view)
            guard first != second else { throw UIDiagnostic("Native idle animation geometry is frozen") }
            FileHandle.standardOutput.write(Data("Loading animation PASS: native idle frames changed spinner/progress geometry\n".utf8))
        } catch {
            FileHandle.standardOutput.write(Data("Loading animation FAIL: \(error.localizedDescription)\n".utf8))
        }
    }
    @MainActor private func paths(_ view: UIView) -> [PaintPath] {
        let context = UIGraphicsContext()
        view.draw(with: context)
        return context.getDrawCommands().compactMap { command in
            guard case let .drawPath(path, transform, _) = command else {
                return nil
            }
            var elements: [Path.Element] = []
            path.forEach { elements.append($0) }
            return PaintPath(elements: elements, transform: transform)
        }
    }
    private struct PaintPath: Equatable {
        let elements: [Path.Element]
        let transform: Transform3D
    }
}
#endif
