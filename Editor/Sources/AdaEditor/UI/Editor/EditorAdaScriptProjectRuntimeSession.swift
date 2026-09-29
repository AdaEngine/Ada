/// Owns expensive runtime preparation independently of declarative view rebuilds.
/// Restart creates a fresh script runtime; ordinary redraws retain the current one.
@MainActor
final class EditorAdaScriptProjectRuntimeSession {
    private let artifact: EditorAdaScriptProjectBuildArtifact
    private let previewCapture: EditorProjectPreviewCapture?
    private(set) var view: EditorAdaScriptProjectRuntimeView

    init(artifact: EditorAdaScriptProjectBuildArtifact, previewCapture: EditorProjectPreviewCapture? = nil) throws {
        self.artifact = artifact
        self.previewCapture = previewCapture
        self.view = try EditorAdaScriptProjectRuntimeView(artifact: artifact, previewCapture: previewCapture)
    }

    func restart() throws {
        let freshView = try EditorAdaScriptProjectRuntimeView(artifact: artifact, previewCapture: previewCapture)
        view.performanceSession.stop()
        view = freshView
    }
}
