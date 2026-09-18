import Foundation

extension EditorViewModel {
    /// Resolve once per drop so every file lands in the same selected directory.
    var fileDropDestinationURL: URL? {
        guard let projectURL else {
            return nil
        }
        guard let item = projectSidebar.selectedItem else {
            return projectURL
        }
        let url = projectURL.appendingPathComponent(item.relativePath, isDirectory: item.isFolder)
        return item.isFolder ? url : url.deletingLastPathComponent()
    }

    @discardableResult
    func importDroppedFiles(from sourceURLs: [URL]) -> Bool {
        guard !sourceURLs.isEmpty, let projectURL, let destination = fileDropDestinationURL else {
            return false
        }
        let root = projectURL.resolvingSymlinksInPath().standardizedFileURL.path
        let destinationPath = destination.resolvingSymlinksInPath().standardizedFileURL.path
        guard
            destinationPath == root || destinationPath.hasPrefix(root + "/"),
            (try? destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        else {
            appendOutput("File import failed: select a directory inside the project.")
            return false
        }

        var importedCount = 0
        for sourceURL in sourceURLs {
            guard sourceURL.isFileURL else {
                continue
            }
            #if os(macOS) || os(iOS) || os(tvOS) || os(visionOS)
                let hasAccess = sourceURL.startAccessingSecurityScopedResource()
                defer {
                    if hasAccess {
                        sourceURL.stopAccessingSecurityScopedResource()
                    }
                }
            #endif
            do {
                let source = sourceURL.resolvingSymlinksInPath().standardizedFileURL
                let values = try source.resourceValues(forKeys: [.isDirectoryKey])
                // Copying a directory into itself would recurse indefinitely.
                if values.isDirectory == true,
                    destinationPath == source.path || destinationPath.hasPrefix(source.path + "/") {
                    appendOutput("Skipped \(sourceURL.lastPathComponent): a folder cannot be copied into itself.")
                    continue
                }
                let target = uniqueAssetDestinationURL(for: sourceURL, in: destination)
                try fileManager.copyItem(at: source, to: target)
                importedCount += 1
                appendOutput("Imported file \(sourceURL.lastPathComponent) -> \(relativeProjectPath(for: target.path))")
            } catch {
                appendOutput("File import failed for \(sourceURL.lastPathComponent): \(error.localizedDescription)")
                workspaceStatus = .failed(error.localizedDescription)
            }
        }

        guard importedCount > 0 else {
            return false
        }
        updateResourcesAfterFileDrop(into: destination, projectURL: projectURL)
        for item in projectSidebar.items where item.isFolder {
            if fileURL(for: item)?.resolvingSymlinksInPath().standardizedFileURL.path == destinationPath {
                projectSidebar.collapsedFolderIDs.remove(item.id)
            }
        }
        refreshProjectFiles(logsRefresh: false)
        refreshSourceControl()
        workbench.achievements?.record([.firstImport: 1])
        return true
    }

    private func updateResourcesAfterFileDrop(into destination: URL, projectURL: URL) {
        let assets = Self.assetsDirectoryURL(for: projectURL, fileManager: fileManager).standardizedFileURL.path
        if destination.standardizedFileURL.path == assets || destination.standardizedFileURL.path.hasPrefix(assets + "/") {
            do {
                try ensureAssetResourcesInManifest(projectURL: projectURL)
            } catch {
                appendOutput("Files copied, but asset manifest update failed: \(error.localizedDescription)")
                workspaceStatus = .failed(error.localizedDescription)
            }
        }
    }
}
