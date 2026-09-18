import Foundation
import Observation

struct EditorGitRow: Identifiable {
    enum Content {
        case file(GitDiffFile)
        case message(String)
        case hunk(String)
        case line(old: GitDiffLine?, new: GitDiffLine?)
    }
    var id: String
    var file: GitDiffFile
    var content: Content
}

@Observable
@MainActor
final class EditorGitDocument: Equatable {
    nonisolated let id: String
    let projectURL: URL
    nonisolated let title: String
    var rootURL: URL?
    var commit: GitCommit?
    var files: [GitDiffFile] = []
    var expandedFiles: Set<String> = []
    var patches: [String: GitFilePatch] = [:]
    var errors: [String: String] = [:]
    var rows: [EditorGitRow] = []
    var isSplit = true {
        didSet { rebuildRows() }
    }
    var message: String?
    var isLoading = false
    var scrollTarget: String?
    var navigationIndex = -1
    var scrollRevision = 0
    var isOpen = true
    var isRunningCommand = false
    var onStage: ((GitDiffFile) -> Void)?
    var onOpenFile: ((URL) -> Void)?
    @ObservationIgnored private let service: any GitRepositoryServicing
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var reviewTask: Task<Void, Never>?

    init(projectURL: URL, commit: GitCommit?, service: any GitRepositoryServicing) {
        self.projectURL = projectURL
        self.commit = commit
        self.title = commit.map { "Commit \($0.shortID)" } ?? "Working Changes"
        self.service = service
        self.id = "git:\(projectURL.path):\(commit?.id ?? "working")"
    }

    nonisolated static func == (lhs: EditorGitDocument, rhs: EditorGitDocument) -> Bool { lhs === rhs }

    var statistics: GitDiffStatistics {
        GitDiffStatistics(additions: files.reduce(0) { $0 + $1.statistics.additions }, deletions: files.reduce(0) { $0 + $1.statistics.deletions })
    }

    func loadCommit() {
        guard let commit else {
            return
        }
        invalidate()
        isOpen = true
        isLoading = true
        let revision = generation
        reviewTask = Task { [weak self, service, projectURL] in
            let result = await service.review(projectURL: projectURL, commit: commit)
            guard let self, self.isOpen, self.generation == revision, !Task.isCancelled else {
                return
            }
            self.isLoading = false
            switch result {
            case let .success(review): self.apply(review)
            case let .failure(error): self.message = error.message
            }
        }
    }

    func apply(_ review: GitReview) {
        invalidate()
        rootURL = review.rootURL
        files = review.files
        commit = review.commit
        message = files.isEmpty ? "No changes." : nil
        patches.removeAll()
        errors.removeAll()
        rebuildRows()
        for file in files where expandedFiles.contains(file.id) { load(file) }
    }

    func invalidate() {
        generation = UUID()
        reviewTask?.cancel()
        reviewTask = nil
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    func close() {
        isOpen = false
        invalidate()
    }

    func toggle(_ file: GitDiffFile) {
        if expandedFiles.contains(file.id) {
            expandedFiles.remove(file.id)
        } else {
            expandedFiles.insert(file.id)
            load(file)
        }
        rebuildRows()
    }

    func reveal(_ fileID: String) {
        guard let file = files.first(where: { $0.id == fileID }) else {
            return
        }
        expandedFiles.insert(file.id)
        load(file)
        rebuildRows()
        scrollTarget = fileID
        scrollRevision += 1
    }

    func navigateHunk(_ step: Int) {
        let targets = rows.compactMap { row -> String? in
            guard case .hunk = row.content else {
                return nil
            }
            return row.id
        }
        guard !targets.isEmpty else {
            return
        }
        navigationIndex = min(max(navigationIndex + step, 0), targets.count - 1)
        scrollTarget = targets[navigationIndex]
        scrollRevision += 1
    }

    func load(_ file: GitDiffFile) {
        guard let rootURL, isOpen, patches[file.id] == nil, tasks[file.id] == nil else {
            return
        }
        let revision = generation
        errors[file.id] = nil
        tasks[file.id] = Task { [weak self, service] in
            let result = await service.patch(rootURL: rootURL, file: file)
            guard let self, self.isOpen, self.generation == revision, !Task.isCancelled else {
                return
            }
            self.tasks[file.id] = nil
            switch result {
            case let .success(patch): self.patches[file.id] = patch
            case let .failure(error): self.errors[file.id] = error.message
            }
            self.rebuildRows()
        }
    }

    func workingFileURL(_ file: GitDiffFile) -> URL? {
        guard let rootURL else {
            return nil
        }
        let url = rootURL.appendingPathComponent(file.path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func rebuildRows() {
        var rows: [EditorGitRow] = []
        for file in files {
            rows.append(EditorGitRow(id: file.id, file: file, content: .file(file)))
            guard expandedFiles.contains(file.id) else {
                continue
            }
            guard let patch = patches[file.id] else {
                rows.append(EditorGitRow(id: "\(file.id):loading", file: file, content: .message(errors[file.id] ?? "Loading diff…")))
                continue
            }
            if let message = patch.message {
                rows.append(EditorGitRow(id: "\(file.id):message", file: file, content: .message(message)))
            }
            for hunk in patch.hunks {
                let prefix = "\(file.id):hunk:\(hunk.id)"
                rows.append(EditorGitRow(id: prefix, file: file, content: .hunk(hunk.header)))
                if isSplit {
                    for (index, pair) in hunk.alignedLines.enumerated() {
                        rows.append(EditorGitRow(id: "\(prefix):\(index)", file: file, content: .line(old: pair.old, new: pair.new)))
                    }
                } else {
                    for (index, line) in hunk.lines.enumerated() {
                        rows.append(EditorGitRow(id: "\(prefix):\(index)", file: file, content: .line(old: nil, new: line)))
                    }
                }
            }
        }
        self.rows = rows
    }
}
