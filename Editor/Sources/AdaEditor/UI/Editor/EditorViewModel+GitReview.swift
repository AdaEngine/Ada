import Foundation

extension EditorViewModel {
    func selectGitHistory() {
        sourceControl.showsHistory = true
        if sourceControl.historyHead == nil && !sourceControl.isLoadingHistory {
            loadGitHistory(reset: true)
        }
    }

    func loadGitHistory(reset: Bool = false) {
        guard let projectURL else {
            return
        }
        if sourceControl.isLoadingHistory && !reset {
            return
        }
        sourceControl.historyTask?.cancel()
        let generation = UUID()
        sourceControl.historyGeneration = generation
        if reset {
            sourceControl.commits = []
            sourceControl.historyHead = nil
            sourceControl.hasMoreHistory = false
        }
        sourceControl.isLoadingHistory = true
        sourceControl.historyError = nil
        let head = sourceControl.historyHead
        let offset = sourceControl.commits.count
        sourceControl.historyTask = Task { [weak self, sourceControlService] in
            let result = await sourceControlService.history(projectURL: projectURL, head: head, offset: offset)
            guard let self, self.projectURL == projectURL, self.sourceControl.historyGeneration == generation, !Task.isCancelled else {
                return
            }
            self.sourceControl.isLoadingHistory = false
            switch result {
            case let .success(page):
                self.sourceControl.commits.append(contentsOf: page.commits)
                self.sourceControl.historyHead = page.head
                self.sourceControl.hasMoreHistory = page.hasMore
            case let .failure(error): self.sourceControl.historyError = error.message
            }
        }
    }

    func openGitDiff(fileID: String? = nil, commit: GitCommit? = nil) {
        guard let projectURL else {
            return
        }
        let candidate = EditorGitDocument(projectURL: projectURL, commit: commit, service: sourceControlService)
        let document = sourceControl.documents[candidate.id] ?? candidate
        sourceControl.documents[document.id] = document
        document.isOpen = true
        document.isRunningCommand = sourceControl.isRunning
        document.onStage = { [weak self] file in
            guard let self, !self.sourceControl.isRunning else {
                return
            }
            if file.comparison == .staged {
                self.executeSourceControlCommand(.unstage(paths: file.paths), statusTitle: "Unstage \(file.path)")
            } else {
                self.executeSourceControlCommand(.stage(paths: file.paths), statusTitle: "Stage \(file.path)")
            }
        }
        document.onOpenFile = { [weak self] url in
            self?.openGitWorkingFile(url)
        }
        if commit != nil {
            if document.files.isEmpty {
                document.loadCommit()
            }
        } else if let root = sourceControl.snapshot.rootURL {
            document.apply(GitReview(rootURL: root, files: sourceControl.snapshot.diffFiles, commit: nil))
        } else {
            document.message = sourceControl.statusMessage
        }
        workbench.open(.git(document))
        if let fileID {
            document.reveal(fileID)
        }
    }

    func updateOpenGitReviews() {
        for document in sourceControl.documents.values where document.isOpen && document.commit == nil {
            if let root = sourceControl.snapshot.rootURL, document.projectURL == projectURL {
                document.apply(GitReview(rootURL: root, files: sourceControl.snapshot.diffFiles, commit: nil))
            } else {
                document.invalidate()
                document.message = sourceControl.statusMessage
            }
        }
        if sourceControl.showsHistory {
            loadGitHistory(reset: true)
        }
    }

    func openGitWorkingFile(_ url: URL) {
        if let existing = workbench.openDocuments.first(where: { $0.absolutePath == url.path }) {
            workbench.selectDocument(id: existing.id)
            return
        }
        if let item = projectSidebar.items.first(where: { $0.id == url.path }) {
            openProjectItem(item)
            return
        }
        // A repository can contain files outside the opened project's subtree.
        let range = EditorSourceRange(start: EditorSourceLocation(line: 0, character: 0), end: EditorSourceLocation(line: 0, character: 0))
        let target = EditorSourceSymbolTarget(uri: url.absoluteString, filePath: url.path, range: range, selectionRange: range)
        openSourceTarget(target)
    }
}
