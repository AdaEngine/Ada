import AdaEngine
import Foundation

extension EditorViewModel {
    var movieMakerPresentation: Binding<Bool> {
        Binding(get: { self.movieMaker.isPresented }, set: { self.movieMaker.isPresented = $0 })
    }

    var canStartMovie: Bool {
        projectURL != nil && !isProjectRunning && !playModeState.isPlaying && workspaceTask == nil && !movieMaker.isBusy
    }

    func startMovieRecording() {
        guard canStartMovie else { return }
        guard workbench.saveAllDocuments() else { movieMaker.report(EditorMovieMakerError.saveFailed); return }
        do {
            guard let projectURL else { throw EditorMovieMakerError.noProject }
            let project = try ProjectSystem.loadProject(at: projectURL, fileManager: fileManager)
            let source: EditorMovieMakerSource
            switch movieMaker.settings.target {
            case .project:
                guard project.build.system.isAdaScript else { throw EditorMovieMakerError.unsupportedProject }
                source = .project(projectURL, project)
            case .currentScene:
                guard let document = workbench.activeSceneDocument, !document.isLoading,
                      let path = document.absolutePath else { throw EditorMovieMakerError.noScene }
                if project.build.system.isAdaScript {
                    var sceneProject = project
                    sceneProject.runtime.entry.scene = document.relativePath
                    source = .project(projectURL, sceneProject)
                } else {
                    reloadScriptableObjectSupport()
                    source = .scene(url: URL(fileURLWithPath: path), assets: projectAssetsURL ?? projectURL, runtime: scenePlayRuntime)
                }
            }
            movieMaker.start(source: source)
        } catch { movieMaker.report(error) }
    }

    func browseMovieFolder() {
        ProjectOpenPicker.presentProjectLocationPicker(title: "Choose Movie Folder", message: "Choose where the movie frames and audio will be saved.") { result in
            switch result {
            case let .selected(folder):
                let name = URL(fileURLWithPath: self.movieMaker.settings.outputPath).lastPathComponent
                self.movieMaker.settings.outputPath = folder.appendingPathComponent(name.isEmpty ? "clip.png" : name).path
            case .cancelled: break
            case let .unavailable(detail): self.movieMaker.report(EditorMovieMakerError.runtime(detail))
            }
        }
    }
}
