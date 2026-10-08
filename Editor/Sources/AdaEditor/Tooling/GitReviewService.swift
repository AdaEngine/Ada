import Foundation

extension GitRepositoryServicing {
    func history(projectURL _: URL, head _: String?, offset _: Int) async -> Result<GitHistoryPage, GitReadError> {
        .failure(GitReadError(message: "History is unavailable."))
    }

    func review(projectURL _: URL, commit _: GitCommit) async -> Result<GitReview, GitReadError> {
        .failure(GitReadError(message: "Commit details are unavailable."))
    }

    func patch(rootURL _: URL, file _: GitDiffFile) async -> Result<GitFilePatch, GitReadError> {
        .failure(GitReadError(message: "Diff is unavailable."))
    }
}

extension GitRepositoryService {
    func readGit(_ arguments: [String], at url: URL) async -> EditorProcessResult {
        await processRunner.run(
            EditorProcessCommand(
                executablePath: "/usr/bin/env",
                arguments: ["git", "--no-pager", "--literal-pathspecs"] + arguments,
                workingDirectory: url,
                environment: ["GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C"]
            )
        )
    }

    func repositoryRoot(at projectURL: URL) async -> Result<URL, GitReadError> {
        let result = await readGit(["rev-parse", "--show-toplevel"], at: projectURL)
        guard result.succeeded else {
            return .failure(readError(result))
        }
        // Git adds one record terminator; whitespace is otherwise legal in a repository path.
        let path = result.standardOutput.hasSuffix("\n") ? String(result.standardOutput.dropLast()) : result.standardOutput
        guard !path.isEmpty else {
            return .failure(GitReadError(message: "Repository root is unavailable."))
        }
        return .success(URL(fileURLWithPath: path, isDirectory: true))
    }

    func history(projectURL: URL, head: String?, offset: Int) async -> Result<GitHistoryPage, GitReadError> {
        do {
            let root = try await repositoryRoot(at: projectURL).get()
            let revision: String
            if let head {
                revision = head
            } else {
                let result = await readGit(["rev-parse", "--verify", "HEAD"], at: root)
                guard result.succeeded else {
                    let symbolic = await readGit(["symbolic-ref", "-q", "HEAD"], at: root)
                    guard symbolic.succeeded else {
                        return .failure(readError(result))
                    }
                    return .success(GitHistoryPage(commits: [], hasMore: false, head: nil))
                }
                revision = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let result = await readGit(
                [
                    "log", "--max-count=51", "--skip=\(max(0, offset))", "--format=%H%x00%P%x00%an%x00%at%x00%s%x00%B", "-z", revision, "--",
                ],
                at: root
            )
            guard result.succeeded else {
                return .failure(readError(result))
            }
            let commits = Self.parseHistory(result.standardOutput)
            return .success(GitHistoryPage(commits: Array(commits.prefix(50)), hasMore: commits.count > 50, head: revision))
        } catch {
            return .failure(GitReadError(message: error.localizedDescription))
        }
    }

    static func parseHistory(_ output: String) -> [GitCommit] {
        let fields = output.components(separatedBy: "\0")
        var commits: [GitCommit] = []
        var index = 0
        while index + 5 < fields.count {
            guard let timestamp = TimeInterval(fields[index + 3]) else {
                break
            }
            commits.append(
                GitCommit(
                    id: fields[index],
                    parents: fields[index + 1].split(separator: " ").map(String.init),
                    author: fields[index + 2],
                    date: Date(timeIntervalSince1970: timestamp),
                    subject: fields[index + 4],
                    message: fields[index + 5].trimmingCharacters(in: .newlines)
                )
            )
            index += 6
        }
        return commits
    }

    func review(projectURL: URL, commit: GitCommit) async -> Result<GitReview, GitReadError> {
        do {
            let root = try await repositoryRoot(at: projectURL).get()
            let comparison = GitComparison.commit(base: commit.parents.first, head: commit.id)
            let base = diffArguments(for: comparison)
            let names = await readGit(base + ["--name-status", "-z", "--"], at: root)
            guard names.succeeded else {
                return .failure(readError(names))
            }
            var files = Self.parseNames(names.standardOutput, comparison: comparison)
            let stats = await readGit(base + ["--numstat", "-z", "--"], at: root)
            guard stats.succeeded else {
                return .failure(readError(stats))
            }
            let statistics = Self.parseStatistics(stats.standardOutput)
            for index in files.indices { files[index].statistics = statistics[files[index].path] ?? GitDiffStatistics() }
            return .success(GitReview(rootURL: root, files: files, commit: commit))
        } catch {
            return .failure(GitReadError(message: error.localizedDescription))
        }
    }

    func changeFiles(snapshot: GitRepositorySnapshot, root: URL) async -> Result<[GitDiffFile], GitReadError> {
        var files: [GitDiffFile] = []
        for comparison in [GitComparison.staged, .workingTree, .untracked] {
            let entries: [GitStatusEntry] =
                switch comparison {
                case .staged: snapshot.stagedFiles
                case .workingTree: snapshot.changedFiles
                default: snapshot.untrackedFiles
                }
            guard !entries.isEmpty else {
                continue
            }
            var statistics: [String: GitDiffStatistics] = [:]
            if comparison != .untracked {
                let result = await readGit(diffArguments(for: comparison) + ["--numstat", "-z", "--"], at: root)
                guard result.succeeded else {
                    return .failure(readError(result))
                }
                statistics = Self.parseStatistics(result.standardOutput)
            }
            for entry in entries {
                var file = GitDiffFile(
                    path: entry.path,
                    originalPath: entry.originalPath,
                    status: entry.isConflicted ? .unmerged : (comparison == .staged ? entry.indexStatus : entry.workingTreeStatus) ?? .modified,
                    comparison: comparison,
                    statistics: statistics[entry.path] ?? GitDiffStatistics()
                )
                if comparison == .untracked {
                    let result = await readGit(["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--numstat", "-z", "--", Self.nullDevice, entry.path], at: root)
                    guard result.exitCode == 0 || result.exitCode == 1 else {
                        return .failure(readError(result))
                    }
                    file.statistics = Self.parseStatistics(result.standardOutput).values.first ?? GitDiffStatistics()
                }
                files.append(file)
            }
        }
        return .success(files)
    }

    func patch(rootURL: URL, file: GitDiffFile) async -> Result<GitFilePatch, GitReadError> {
        if file.statistics.isBinary {
            return .success(GitFilePatch(hunks: [], message: "Binary file changed"))
        }
        if file.status == .unmerged {
            return .success(GitFilePatch(hunks: [], message: "Unresolved conflict. Open the working file to inspect conflict markers."))
        }
        let arguments: [String]
        if file.comparison == .untracked {
            arguments = ["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color", "--unified=3", "--", Self.nullDevice, file.path]
        } else {
            arguments = diffArguments(for: file.comparison) + ["--patch", "--unified=3", "--"] + file.paths
        }
        let result = await readGit(arguments, at: rootURL)
        guard result.succeeded || (file.comparison == .untracked && result.exitCode == 1) else {
            return .failure(readError(result))
        }
        if result.standardOutput.isEmpty, file.statistics.additions + file.statistics.deletions > 0 {
            return .failure(GitReadError(message: "Unable to display this diff as UTF-8 text. Refresh to check for newer changes."))
        }
        return .success(GitFilePatch.parse(result.standardOutput))
    }

    private static var nullDevice: String {
        #if os(Windows)
            "NUL"
        #else
            "/dev/null"
        #endif
    }

    private func diffArguments(for comparison: GitComparison) -> [String] {
        let options = ["--no-ext-diff", "--no-textconv", "--no-color", "--find-renames"]
        switch comparison {
        case .staged: return ["diff", "--cached"] + options
        case .workingTree,
            .untracked:
            return ["diff"] + options
        case let .commit(base, head):
            if let base {
                return ["diff"] + options + [base, head]
            }
            return ["diff-tree", "--root", "--no-commit-id", "-r"] + options + [head]
        }
    }

    static func parseNames(_ output: String, comparison: GitComparison) -> [GitDiffFile] {
        let fields = output.components(separatedBy: "\0")
        var index = 0
        var files: [GitDiffFile] = []
        while index + 1 < fields.count, let marker = fields[index].first {
            let status = GitFileStatus(rawValue: String(marker)) ?? .modified
            let original = fields[index + 1]
            index += 2
            let isRename = status == .renamed || status == .copied
            guard !isRename || index < fields.count else {
                break
            }
            let path = isRename ? fields[index] : original
            if isRename {
                index += 1
            }
            files.append(GitDiffFile(path: path, originalPath: isRename ? original : nil, status: status, comparison: comparison))
        }
        return files
    }

    static func parseStatistics(_ output: String) -> [String: GitDiffStatistics] {
        let fields = output.components(separatedBy: "\0")
        var index = 0
        var result: [String: GitDiffStatistics] = [:]
        while index < fields.count {
            let parts = fields[index].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            index += 1
            guard parts.count == 3 else {
                continue
            }
            var path = String(parts[2])
            if path.isEmpty {
                guard index + 1 < fields.count else {
                    break
                }
                path = fields[index + 1]
                index += 2
            }
            result[path] = GitDiffStatistics(additions: Int(parts[0]) ?? 0, deletions: Int(parts[1]) ?? 0, isBinary: parts[0] == "-")
        }
        return result
    }

    private func readError(_ result: EditorProcessResult) -> GitReadError {
        let output = result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return GitReadError(message: output.isEmpty ? "Git exited with code \(result.exitCode)." : output)
    }
}
