@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

@Suite("Git review integration")
struct GitReviewTests {
    @Test("Real repository separates index and working changes and preserves unusual paths")
    func changesAndPaths() async throws {
        let repo = try GitReviewFixture()
        defer { repo.remove() }
        try await repo.initialize()
        try repo.write("base\n", to: "file.swift")
        try repo.write("old\n", to: "deleted.txt")
        try repo.write("rename\n", to: "old name.txt")
        try await repo.git(["add", "."])
        try await repo.commit("Initial")
        try repo.write("staged\n", to: "file.swift")
        try await repo.git(["add", "file.swift"])
        try repo.write("working\n", to: "file.swift")
        try FileManager.default.removeItem(at: repo.url.appendingPathComponent("deleted.txt"))
        try await repo.git(["mv", "old name.txt", "новое → имя.txt"])
        let unusual = "tab\tline\n\"юникод.txt"
        try repo.write("new\n", to: unusual)
        try Data([0, 255, 0, 12]).write(to: repo.url.appendingPathComponent("binary.bin"))
        try FileManager.default.createDirectory(at: repo.url.appendingPathComponent("nested"), withIntermediateDirectories: true)

        let service = GitRepositoryService()
        let result = await service.snapshot(projectURL: repo.url.appendingPathComponent("nested"))
        #expect(result.succeeded)
        #expect(result.snapshot.rootURL?.resolvingSymlinksInPath() == repo.url.resolvingSymlinksInPath())
        #expect(result.snapshot.files.contains { $0.path == unusual })
        let staged = try #require(result.snapshot.diffFiles.first { $0.path == "file.swift" && $0.comparison == .staged })
        let working = try #require(result.snapshot.diffFiles.first { $0.path == "file.swift" && $0.comparison == .workingTree })
        #expect(staged.statistics == GitDiffStatistics(additions: 1, deletions: 1))
        let stagedPatch = try await service.patch(rootURL: repo.url, file: staged).get()
        let workingPatch = try await service.patch(rootURL: repo.url, file: working).get()
        #expect(stagedPatch.hunks.flatMap(\.lines).contains { $0.text == "base" && $0.kind == .deletion })
        #expect(workingPatch.hunks.flatMap(\.lines).contains { $0.text == "working" && $0.kind == .addition })
        let rename = try #require(result.snapshot.diffFiles.first { $0.path == "новое → имя.txt" })
        #expect(rename.originalPath == "old name.txt")
        let binary = try #require(result.snapshot.diffFiles.first { $0.path == "binary.bin" })
        #expect(binary.statistics.isBinary)
        #expect(try await service.patch(rootURL: repo.url, file: binary).get().hunks.isEmpty)
        let untracked = try #require(result.snapshot.diffFiles.first { $0.path == unusual })
        #expect(try await service.patch(rootURL: repo.url, file: untracked).get().hunks.first?.lines.first?.text == "new")

        let indexBefore = try await repo.git(["diff", "--cached"])
        _ = try await service.history(projectURL: repo.url, head: nil, offset: 0).get()
        #expect(try await repo.git(["diff", "--cached"]) == indexBefore)
    }

    @Test("History reads full messages, initial commits and first-parent merge diffs")
    func historyAndMerge() async throws {
        let repo = try GitReviewFixture()
        defer { repo.remove() }
        try await repo.initialize()
        let service = GitRepositoryService()
        #expect(try await service.history(projectURL: repo.url, head: nil, offset: 0).get().commits.isEmpty)
        try repo.write("first\n", to: "initial.txt")
        try await repo.git(["add", "."])
        try await repo.commit("First subject\n\nFull body\twith tab")
        let first = try #require(try await service.history(projectURL: repo.url, head: nil, offset: 0).get().commits.first)
        #expect(first.parents.isEmpty)
        #expect(first.message.contains("Full body\twith tab"))
        let review = try await service.review(projectURL: repo.url, commit: first).get()
        #expect(review.files.map(\.path) == ["initial.txt"])
        #expect(try await service.patch(rootURL: repo.url, file: #require(review.files.first)).get().hunks.first?.lines.first?.kind == .addition)
        try await repo.git(["checkout", "-b", "feature"])
        try repo.write("feature\n", to: "feature.txt")
        try await repo.git(["add", "."])
        try await repo.commit("Feature")
        try await repo.git(["checkout", "main"])
        try repo.write("main\n", to: "main.txt")
        try await repo.git(["add", "."])
        try await repo.commit("Main")
        try await repo.git(["merge", "--no-ff", "feature", "-m", "Merge feature"])
        let merged = try #require(try await service.history(projectURL: repo.url, head: nil, offset: 0).get().commits.first)
        #expect(merged.parents.count == 2)
        #expect(try await service.review(projectURL: repo.url, commit: merged).get().files.map(\.path) == ["feature.txt"])
    }

    @Test("Pagination stays pinned to its HEAD and supports worktrees")
    func historyPagesAndWorktree() async throws {
        let repo = try GitReviewFixture()
        defer { repo.remove() }
        try await repo.initialize()
        for index in 0..<52 { try await repo.commit("Commit \(index)") }
        let service = GitRepositoryService()
        let first = try await service.history(projectURL: repo.url, head: nil, offset: 0).get()
        #expect(first.commits.count == 50)
        #expect(first.hasMore)
        try await repo.commit("New head")
        let second = try await service.history(projectURL: repo.url, head: first.head, offset: 50).get()
        #expect(second.commits.count == 2)
        #expect(!second.hasMore)
        #expect(Set((first.commits + second.commits).map(\.id)).count == 52)
        let worktree = repo.url.appendingPathComponent("worktree")
        try await repo.git(["worktree", "add", "--detach", worktree.path])
        let result = await service.snapshot(projectURL: worktree)
        #expect(result.succeeded)
        #expect(result.snapshot.isDetached)
        #expect(result.snapshot.rootURL?.resolvingSymlinksInPath() == worktree.resolvingSymlinksInPath())
    }

    @Test("Stage and unstage operate from repository root, including unborn HEAD")
    func unbornIndexOperations() async throws {
        let repo = try GitReviewFixture()
        defer { repo.remove() }
        try await repo.initialize()
        try repo.write("initial\n", to: "initial.txt")
        try FileManager.default.createDirectory(at: repo.url.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let service = GitRepositoryService()
        let nested = repo.url.appendingPathComponent("nested")
        #expect(await service.execute(.stage(paths: ["initial.txt"]), projectURL: nested).succeeded)
        #expect(await service.snapshot(projectURL: nested).snapshot.stagedFiles.count == 1)
        #expect(await service.execute(.unstage(paths: ["initial.txt"]), projectURL: nested).succeeded)
        #expect(await service.snapshot(projectURL: nested).snapshot.untrackedFiles.count == 1)
        #expect(try String(contentsOf: repo.url.appendingPathComponent("initial.txt"), encoding: .utf8) == "initial\n")
    }

    @Test("Conflicts and unavailable repositories surface explicit states")
    func conflictsAndUnavailable() async throws {
        let repo = try GitReviewFixture()
        defer { repo.remove() }
        let service = GitRepositoryService()
        #expect(!(await service.snapshot(projectURL: repo.url)).succeeded)
        try await repo.initialize()
        try repo.write("base\n", to: "conflict.txt")
        try await repo.git(["add", "."])
        try await repo.commit("Base")
        try await repo.git(["checkout", "-b", "side"])
        try repo.write("side\n", to: "conflict.txt")
        try await repo.git(["add", "."])
        try await repo.commit("Side")
        try await repo.git(["checkout", "main"])
        try repo.write("main\n", to: "conflict.txt")
        try await repo.git(["add", "."])
        try await repo.commit("Main")
        do {
            try await repo.git(["merge", "side"])
            Issue.record("Expected conflicting merge")
        } catch {}
        let snapshot = await service.snapshot(projectURL: repo.url).snapshot
        #expect(snapshot.stagedFiles.isEmpty)
        let conflict = try #require(snapshot.diffFiles.first)
        #expect(conflict.status == .unmerged)
        #expect(try await service.patch(rootURL: repo.url, file: conflict).get().message?.contains("Unresolved conflict") == true)
    }

    @Test("Split alignment preserves numbers, gaps, and missing-newline notes")
    func alignment() {
        let patch = GitFilePatch.parse("@@ -4,2 +4,3 @@\n-old\n+new\n+extra\n context\n\\ No newline at end of file\n")
        #expect(patch.hunks.count == 1)
        let lines = patch.hunks[0].alignedLines
        #expect(lines.count == 4)
        #expect(lines[0].old?.oldNumber == 4)
        #expect(lines[0].new?.newNumber == 4)
        #expect(lines[1].old == nil)
        #expect(lines[1].new?.text == "extra")
        #expect(lines[2].old?.oldNumber == 5)
        #expect(lines[2].new?.newNumber == 6)
        #expect(lines[3].new?.kind == .note)
    }

    @Test("Diff UI switches modes, expands files and keeps its toolbar inside a narrow viewport")
    @MainActor
    func diffUIInteraction() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "GitDiffUITest")))
        }
        let url = URL(fileURLWithPath: "/tmp/GitDiffUI")
        let document = EditorGitDocument(projectURL: url, commit: nil, service: DelayedGitReviewService())
        let file = GitDiffFile(path: "LongFile.swift", status: .modified, comparison: .workingTree)
        document.apply(GitReview(rootURL: url, files: [file]))
        let workbench = EditorWorkbenchViewModel(openDocuments: [], activeDocumentID: "")
        let container = UIContainerView(rootView: EditorGitDiffView(document: document, workbench: workbench))
        container.frame = Rect(x: 0, y: 0, width: 640, height: 400)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Git.Diff.Unified"))
        #expect(!document.isSplit)
        container.layoutIfNeeded()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Git.Diff.File.\(file.id)"))
        #expect(document.expandedFiles.contains(file.id))
        for _ in 0..<100 {
            if document.patches[file.id] != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(document.patches[file.id] != nil)
        container.layoutIfNeeded()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Git.Diff.Split"))
        #expect(document.isSplit)
        let split = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Git.Diff.Split"))
        #expect(split.absoluteFrame.maxX <= 640)
        document.navigateHunk(1)
        #expect(document.scrollTarget == "\(file.id):hunk:0")
        let largePatch = "@@ -0,0 +1,2000 @@\n" + (1...2000).map { "+let value\($0) = \($0)" }.joined(separator: "\n")
        document.patches[file.id] = GitFilePatch.parse(largePatch)
        document.isSplit = true
        container.layoutIfNeeded()
        #expect(document.rows.count == 2002)
        func nodeCount(_ node: UINodeSnapshot) -> Int { 1 + node.children.reduce(0) { $0 + nodeCount($1) } }
        let renderedNodes = container.uiTreeRoots().reduce(0) { $0 + nodeCount($1) }
        #expect(renderedNodes < 5000)
    }

    @Test("Sidebar clicks open diffs, stage files and navigate history using a real repository")
    @MainActor
    func sidebarWorkflow() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "GitSidebarUITest")))
        }
        let repo = try GitReviewFixture()
        defer { repo.remove() }
        try await repo.initialize()
        try repo.write(".ada/workspace/\n", to: ".git/info/exclude")
        try await repo.commit("Initial")
        try repo.write("new text\n", to: "new.txt")
        let model = EditorViewModel(project: EditorProjectReference(name: "Git UI", path: repo.url.path, lastOpenedAt: Date()))
        model.refreshSourceControl()
        await model.sourceControl.refreshTask?.value
        let container = UIContainerView(rootView: EditorSourceControlSidebar(viewModel: model))
        container.frame = Rect(x: 0, y: 0, width: 300, height: 800)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        await model.sourceControl.refreshTask?.value
        container.layoutIfNeeded()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Git.File.Untracked:new.txt"))
        guard case let .git(review) = model.workbench.activeDocument else {
            Issue.record("Click should open a Git document")
            return
        }
        #expect(review.scrollTarget == "Untracked:new.txt")
        #expect(review.expandedFiles.contains("Untracked:new.txt"))
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Git.Stage All"))
        await model.sourceControlTask?.value
        await model.sourceControl.refreshTask?.value
        #expect(model.sourceControl.snapshot.stagedFiles.map(\.path) == ["new.txt"])
        #expect(review.files.map(\.comparison) == [.staged])
        container.layoutIfNeeded()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Git.History"))
        await model.sourceControl.historyTask?.value
        #expect(model.sourceControl.showsHistory)
        let commit = try #require(model.sourceControl.commits.first)
        container.layoutIfNeeded()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Git.Commit.\(commit.id)"))
        guard case let .git(history) = model.workbench.activeDocument else {
            Issue.record("Click should open a commit review")
            return
        }
        #expect(history.commit?.id == commit.id)
        history.close()
        review.close()
    }

    @Test("Git tabs reuse documents, preserve expansion and discard late responses after close")
    @MainActor
    func documentLifecycle() async throws {
        let service = DelayedGitReviewService(holdResponse: true)
        let url = URL(fileURLWithPath: "/tmp/GitReviewLifecycle")
        let document = EditorGitDocument(projectURL: url, commit: nil, service: service)
        let file = GitDiffFile(path: "test.swift", status: .modified, comparison: .workingTree)
        document.apply(GitReview(rootURL: url, files: [file]))
        let workbench = EditorWorkbenchViewModel(openDocuments: [], activeDocumentID: "")
        workbench.open(.git(document))
        workbench.open(.git(document))
        #expect(workbench.openDocuments.count == 1)
        #expect(!EditorWorkbenchDocument.git(document).isDirty)
        document.reveal(file.id)
        #expect(document.scrollTarget == file.id)
        #expect(document.expandedFiles.contains(file.id))
        document.isSplit = false
        await service.waitForRequest()
        workbench.closeDocument(id: document.id)
        await service.completeRequest()
        await Task.yield()
        #expect(document.patches.isEmpty)
        #expect(document.expandedFiles.contains(file.id))
        #expect(!document.isSplit)
        #expect(workbench.openDocuments.isEmpty)
    }
}

private struct GitReviewFixture {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("adaeditor-git-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: url) }
    func initialize() async throws { try await git(["init", "-b", "main"]) }
    func write(_ text: String, to path: String) throws { try text.write(to: url.appendingPathComponent(path), atomically: true, encoding: .utf8) }
    func commit(_ message: String) async throws { try await git(["commit", "--allow-empty", "-m", message]) }
    @discardableResult
    func git(_ arguments: [String]) async throws -> String {
        let result = await EditorProcessRunner()
            .run(
                EditorProcessCommand(
                    executablePath: "/usr/bin/env",
                    arguments: ["git", "-c", "user.name=Git Test", "-c", "user.email=git-test@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + arguments,
                    workingDirectory: url,
                    environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
                )
            )
        guard result.succeeded else {
            throw GitReadError(message: result.combinedOutput)
        }
        return result.standardOutput
    }
}

private actor DelayedGitReviewService: GitRepositoryServicing {
    var hasStarted = false
    private let holdResponse: Bool
    private var started: CheckedContinuation<Void, Never>?
    private var response: CheckedContinuation<Void, Never>?
    init(holdResponse: Bool = false) { self.holdResponse = holdResponse }
    func waitForRequest() async {
        if hasStarted {
            return
        }
        await withCheckedContinuation { started = $0 }
    }
    func completeRequest() {
        response?.resume()
        response = nil
    }
    nonisolated func makeCommand(_ kind: GitCommandKind, projectURL: URL) -> EditorProcessCommand {
        GitRepositoryService().makeCommand(kind, projectURL: projectURL)
    }
    func snapshot(projectURL: URL) async -> GitRepositoryLoadResult {
        GitRepositoryLoadResult(snapshot: .empty, statusResult: await execute(.status, projectURL: projectURL))
    }
    func execute(_ kind: GitCommandKind, projectURL: URL) async -> EditorProcessResult {
        EditorProcessResult(command: makeCommand(kind, projectURL: projectURL), exitCode: 0, standardOutput: "", standardError: "")
    }
    func patch(rootURL _: URL, file _: GitDiffFile) async -> Result<GitFilePatch, GitReadError> {
        hasStarted = true
        started?.resume()
        started = nil
        if holdResponse {
            await withCheckedContinuation { response = $0 }
        }
        return .success(GitFilePatch.parse("@@ -1 +1 @@\n-old\n+new\n"))
    }
}
