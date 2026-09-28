import AdaEngine
import Foundation

extension EditorViewModel {
    func scheduleAdaScriptHotReload() {
        guard adaScriptRuntimeWindow != nil, adaScriptRuntimeControls != nil else {
            return
        }
        adaScriptHotReloadRevision += 1
        let revision = adaScriptHotReloadRevision
        adaScriptHotReloadTask?.cancel()
        adaScriptHotReloadTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                guard let self, revision == self.adaScriptHotReloadRevision,
                    let projectURL = self.projectURL,
                    let controls = self.adaScriptRuntimeControls
                else {
                    return
                }
                let project = try ProjectSystem.loadProject(at: projectURL, fileManager: self.fileManager)
                guard project.build.system.isAdaScript else {
                    return
                }
                let overrides = Dictionary(
                    uniqueKeysWithValues: self.workbench.openDocuments.compactMap { document -> (String, String)? in
                        guard case let .text(text) = document,
                            text.relativePath.lowercased().hasSuffix(".ada"),
                            text.isDirty
                        else {
                            return nil
                        }
                        return (text.relativePath, text.content)
                    }
                )
                let artifact = try EditorAdaScriptProjectBuilder().prepare(
                    project: project,
                    at: projectURL,
                    sourceOverrides: overrides,
                    validatesRuntime: false
                )
                guard revision == self.adaScriptHotReloadRevision, !Task.isCancelled else {
                    return
                }
                if try await controls.reloadAdaScript(artifact) {
                    self.appendOutput("AdaScript hot reload applied: \(artifact.report.sourceCount) source(s).")
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, revision == self.adaScriptHotReloadRevision else {
                    return
                }
                self.appendOutput("AdaScript hot reload rejected; the running game kept its previous code: \(error.localizedDescription)")
            }
        }
    }
}
