import Foundation

enum EditorBuildFileSelection: String {
    case included = "IncludedFiles"
    case excluded = "ExcludedFiles"

    var title: String {
        self == .included ? "Included files and directories" : "Excluded files and directories"
    }
}

extension EditorViewModel {
    func buildFiles(for selection: EditorBuildFileSelection) -> [String] {
        selection == .included ? projectIncludedFiles : projectExcludedFiles
    }

    func removeBuildFile(_ path: String, from selection: EditorBuildFileSelection) {
        switch selection {
        case .included: projectIncludedFiles.removeAll { $0 == path }
        case .excluded: projectExcludedFiles.removeAll { $0 == path }
        }
        projectSettingsStatusMessage = "Unsaved changes."
    }

    func presentBuildFilePicker(for selection: EditorBuildFileSelection) {
        guard let projectURL else {
            return
        }
        ProjectOpenPicker.presentBuildFilePicker(directoryURL: projectURL) { [weak self] result in
            guard let self, self.projectURL == projectURL else {
                return
            }
            switch result {
            case let .selected(urls): addBuildFiles(urls, to: selection)
            case .cancelled: break
            case let .unavailable(message): projectSettingsStatusMessage = message
            }
        }
    }

    func addBuildFiles(_ urls: [URL], to selection: EditorBuildFileSelection) {
        guard let projectURL else {
            return
        }
        let root = projectURL.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        var paths = buildFiles(for: selection)
        // Validate the whole selection before changing the draft.
        for url in urls {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard url.isFileURL, path.hasPrefix(prefix), fileManager.fileExists(atPath: path) else {
                projectSettingsStatusMessage = "Choose existing files or folders inside the project."
                return
            }
            let relativePath = String(path.dropFirst(prefix.count))
            if !paths.contains(relativePath) {
                paths.append(relativePath)
            }
        }
        switch selection {
        case .included: projectIncludedFiles = paths
        case .excluded: projectExcludedFiles = paths
        }
        projectSettingsStatusMessage = "Unsaved changes."
    }
}
