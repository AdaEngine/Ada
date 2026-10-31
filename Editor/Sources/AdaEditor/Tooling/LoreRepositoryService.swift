import Foundation
#if canImport(Lore)
import Lore
#endif

/// Adapts Lore to the workbench's existing status, history and unified-diff models.
/// Git-prefixed value types are retained to keep existing documents and tooling compatible.
actor LoreRepositoryService: GitRepositoryServicing {
    func currentBranchFooter(projectURL: URL) async -> String? {
        #if canImport(Lore)
        do {
            let repository = Repository(path: try Self.root(at: projectURL).path)
            let branch = try await repository.branches().first(where: \.isCurrent)
            return branch.map { "Lore: \($0.name)" }
        } catch { return nil }
        #else
        return nil
        #endif
    }

    nonisolated func makeCommand(_ kind: GitCommandKind, projectURL: URL) -> EditorProcessCommand {
        // These records describe native binding calls in Output; no CLI is launched.
        EditorProcessCommand(executablePath: "Lore", arguments: [], workingDirectory: projectURL, displayName: "Lore: \(kind)")
    }

    func snapshot(projectURL: URL) async -> GitRepositoryLoadResult {
        var snapshot = GitRepositorySnapshot.empty
        snapshot.provider = .lore
        do {
            #if canImport(Lore)
            let root = try Self.root(at: projectURL)
            let repository = Repository(path: root.path)
            let status = try await repository.status()
            snapshot.rootURL = root
            snapshot.branchName = status.branch
            snapshot.statusMessage = status.files.isEmpty ? "Working tree clean" : nil
            snapshot.branches = try await repository.branches().filter { $0.location == .local }.map {
                GitBranch(name: $0.name, isCurrent: $0.isCurrent)
            }
            for file in status.files where file.kind != .directory {
                let action = Self.status(file.action)
                let marker: GitFileStatus = file.isConflicted ? .unmerged : action
                let untracked = !file.isStaged && !file.isConflicted && action == .added
                let entry = GitStatusEntry(
                    path: file.path, originalPath: file.previousPath,
                    indexStatus: untracked ? .untracked : (file.isStaged ? marker : nil),
                    workingTreeStatus: untracked ? .untracked : (file.isStaged ? nil : marker)
                )
                snapshot.files.append(entry)
                // Lore staging records paths, not frozen file contents. Each path
                // therefore belongs to exactly one group even when marked dirty.
                snapshot.diffFiles.append(GitDiffFile(
                    path: file.path, originalPath: file.previousPath, status: marker,
                    comparison: untracked ? .untracked : (file.isStaged ? .staged : .workingTree)
                ))
            }
            for index in snapshot.diffFiles.indices {
                if case let .success(patch) = await patch(rootURL: root, file: snapshot.diffFiles[index]) {
                    snapshot.diffFiles[index].statistics = Self.statistics(patch)
                }
            }
            #else
            throw GitReadError(message: "Lore requires macOS with Apple silicon, Windows x64, or Linux x64/ARM64.")
            #endif
            return GitRepositoryLoadResult(snapshot: snapshot, statusResult: result(.status, at: projectURL), branchResult: nil)
        } catch {
            snapshot.statusMessage = Self.message(error)
            return GitRepositoryLoadResult(snapshot: snapshot, statusResult: result(.status, at: projectURL, error: Self.message(error)), branchResult: nil)
        }
    }

    func execute(_ kind: GitCommandKind, projectURL: URL) async -> EditorProcessResult {
        do {
            #if canImport(Lore)
            if case .initializeRepository = kind {
                try await Repository.create(at: projectURL.path, options: .init(identity: NSUserName(), isOffline: true))
                let ignore = projectURL.appendingPathComponent(".loreignore")
                if !FileManager.default.fileExists(atPath: ignore.path) {
                    let gitIgnore = (try? String(contentsOf: projectURL.appendingPathComponent(".gitignore"), encoding: .utf8)) ?? ""
                    try (gitIgnore + "\n.git/\n.ada/workspace/\n.build/\n.builds/\n.swiftpm/\n").write(to: ignore, atomically: true, encoding: .utf8)
                }
            } else {
                let repository = Repository(path: try Self.root(at: projectURL).path)
                switch kind {
                case .status: _ = try await repository.status()
                case .branches: _ = try await repository.branches()
                case let .stage(paths): _ = try await repository.stage(paths.isEmpty ? ["."] : paths)
                case let .unstage(paths): _ = try await repository.unstage(paths.isEmpty ? ["."] : paths)
                case let .commit(message): _ = try await repository.commit(message: message)
                case .pull: _ = try await repository.sync()
                case .push: _ = try await repository.push()
                case let .checkout(branch): _ = try await repository.switchBranch(to: branch)
                case let .createBranch(name):
                    _ = try await repository.createBranch(named: name)
                    _ = try await repository.switchBranch(to: name)
                case .stash: throw GitReadError(message: "Stash is available only with Git.")
                case .initializeRepository: break
                }
            }
            return result(kind, at: projectURL)
            #else
            throw GitReadError(message: "Lore requires macOS with Apple silicon, Windows x64, or Linux x64/ARM64.")
            #endif
        } catch {
            return result(kind, at: projectURL, error: Self.message(error))
        }
    }

    func history(projectURL: URL, head: String?, offset: Int) async -> Result<GitHistoryPage, GitReadError> {
        do {
            #if canImport(Lore)
            let repository = Repository(path: try Self.root(at: projectURL).path)
            // Freeze pagination at the first page's revision, as the Git reader does.
            let revisions = try await repository.history(from: head.map { RevisionSpecifier(rawValue: $0) }, limit: max(0, offset) + 51)
            let commits = revisions.dropFirst(max(0, offset)).prefix(50).map(Self.commit)
            return .success(GitHistoryPage(commits: Array(commits), hasMore: revisions.count > max(0, offset) + 50, head: head ?? revisions.first?.id.description))
            #else
            throw GitReadError(message: "Lore requires macOS with Apple silicon, Windows x64, or Linux x64/ARM64.")
            #endif
        } catch { return .failure(GitReadError(message: Self.message(error))) }
    }

    func review(projectURL: URL, commit: GitCommit) async -> Result<GitReview, GitReadError> {
        do {
            #if canImport(Lore)
            let root = try Self.root(at: projectURL)
            let repository = Repository(path: root.path)
            let changes = try await repository.changes(in: RevisionSpecifier(rawValue: commit.id))
            var files = changes.filter { $0.kind != .directory }.map {
                GitDiffFile(path: $0.path, originalPath: $0.previousPath, status: Self.status($0.action), comparison: .commit(base: commit.parents.first, head: commit.id))
            }
            for index in files.indices {
                if case let .success(patch) = await patch(rootURL: root, file: files[index]) {
                    files[index].statistics = Self.statistics(patch)
                }
            }
            return .success(GitReview(rootURL: root, files: files, commit: commit))
            #else
            throw GitReadError(message: "Lore requires macOS with Apple silicon, Windows x64, or Linux x64/ARM64.")
            #endif
        } catch { return .failure(GitReadError(message: Self.message(error))) }
    }

    func patch(rootURL: URL, file: GitDiffFile) async -> Result<GitFilePatch, GitReadError> {
        do {
            #if canImport(Lore)
            if file.status == .unmerged {
                return .success(GitFilePatch(hunks: [], message: "Unresolved conflict. Open the working file to inspect conflict markers."))
            }
            let repository = Repository(path: rootURL.path)
            let source: RevisionSpecifier
            let target: RevisionSpecifier?
            if case let .commit(base, head) = file.comparison {
                guard let base else {
                    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("lore-diff-\(UUID().uuidString)")
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try await repository.writeContents(of: file.path, revision: RevisionSpecifier(rawValue: head), to: temporary.path)
                    return .success(try Self.addition(at: temporary))
                }
                source = RevisionSpecifier(rawValue: base)
                target = RevisionSpecifier(rawValue: head)
            } else {
                if file.status == .added || file.comparison == .untracked {
                    return .success(try Self.addition(at: rootURL.appendingPathComponent(file.path)))
                }
                let status = try await repository.status(of: [], scanning: false)
                guard let revision = status.revision else {
                    throw GitReadError(message: "No commits yet.")
                }
                source = .id(revision)
                target = nil
            }
            let diffs = try await repository.diff(of: file.paths, from: source, to: target, contextLines: 3)
            let output = diffs.map(\.patch).joined(separator: "\n")
            if output.contains("\0") { return .success(GitFilePatch(hunks: [], message: "Binary file changed")) }
            return .success(GitFilePatch.parse(output))
            #else
            throw GitReadError(message: "Lore requires macOS with Apple silicon, Windows x64, or Linux x64/ARM64.")
            #endif
        } catch { return .failure(GitReadError(message: Self.message(error))) }
    }

    private func result(_ kind: GitCommandKind, at url: URL, error: String? = nil) -> EditorProcessResult {
        EditorProcessResult(command: makeCommand(kind, projectURL: url), exitCode: error == nil ? 0 : 1, standardOutput: "", standardError: error ?? "")
    }

    private static func addition(at url: URL) throws -> GitFilePatch {
        let data = try Data(contentsOf: url)
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            return GitFilePatch(hunks: [], message: "Binary file changed")
        }
        guard !text.isEmpty else { return GitFilePatch(hunks: [], message: "No textual changes (metadata only).") }
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { lines.removeLast() }
        return GitFilePatch(hunks: [GitDiffHunk(id: 0, header: "@@ -0,0 +1,\(lines.count) @@", lines: lines.enumerated().map {
            GitDiffLine(kind: .addition, text: $0.element, oldNumber: nil, newNumber: $0.offset + 1)
        })], message: nil)
    }

    private static func statistics(_ patch: GitFilePatch) -> GitDiffStatistics {
        let lines = patch.hunks.flatMap(\.lines)
        return GitDiffStatistics(additions: lines.filter { $0.kind == .addition }.count,
                                 deletions: lines.filter { $0.kind == .deletion }.count,
                                 isBinary: patch.message == "Binary file changed")
    }

    private static func message(_ error: any Error) -> String {
        #if canImport(Lore)
        if let error = error as? LoreError { return error.message }
        #endif
        return error.localizedDescription
    }

    static func root(at url: URL) throws -> URL {
        var directory = url.standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".lore").path) { return directory }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { throw GitReadError(message: "No Lore repository was found.") }
            directory = parent
        }
    }

    #if canImport(Lore)
    private static func status(_ action: FileAction) -> GitFileStatus {
        switch action {
        case .add: .added
        case .delete: .deleted
        case .move: .renamed
        case .copy: .copied
        default: .modified
        }
    }

    private static func commit(_ revision: Revision) -> GitCommit {
        GitCommit(id: revision.id.description, parents: revision.parents.map(\.description), author: revision.creator ?? "",
                  date: revision.date ?? Date(timeIntervalSince1970: 0), subject: revision.message?.components(separatedBy: .newlines).first ?? "", message: revision.message ?? "")
    }
    #endif
}
