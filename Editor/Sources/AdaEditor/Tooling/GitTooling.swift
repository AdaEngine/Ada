@preconcurrency import Foundation

enum GitFileStatus: String, Equatable, Sendable {
    case added = "A"
    case copied = "C"
    case deleted = "D"
    case modified = "M"
    case renamed = "R"
    case typeChanged = "T"
    case unmerged = "U"
    case untracked = "?"
    case ignored = "!"

    var title: String {
        switch self {
        case .added:
            "Added"
        case .copied:
            "Copied"
        case .deleted:
            "Deleted"
        case .modified:
            "Modified"
        case .renamed:
            "Renamed"
        case .typeChanged:
            "Type Changed"
        case .unmerged:
            "Conflict"
        case .untracked:
            "Untracked"
        case .ignored:
            "Ignored"
        }
    }
}

struct GitStatusEntry: Equatable, Sendable, Identifiable {
    var path: String
    var originalPath: String?
    var indexStatus: GitFileStatus?
    var workingTreeStatus: GitFileStatus?

    var id: String {
        "\(path):\(originalPath ?? ""):\(indexStatus?.rawValue ?? " "):\(workingTreeStatus?.rawValue ?? " ")"
    }

    var isConflicted: Bool {
        indexStatus == .unmerged || workingTreeStatus == .unmerged
            || (indexStatus == .added && workingTreeStatus == .added)
            || (indexStatus == .deleted && workingTreeStatus == .deleted)
    }

    var isStaged: Bool {
        !isConflicted && indexStatus != nil && indexStatus != .untracked && indexStatus != .ignored
    }

    var hasWorkingTreeChange: Bool {
        workingTreeStatus != nil && workingTreeStatus != .ignored
    }

    var isUntracked: Bool {
        indexStatus == .untracked && workingTreeStatus == .untracked
    }

    var displayStatus: String {
        if isUntracked {
            return GitFileStatus.untracked.title
        }

        return [indexStatus?.title, workingTreeStatus?.title]
            .compactMap { $0 }
            .removingDuplicates()
            .joined(separator: " / ")
    }
}

struct GitBranch: Equatable, Sendable, Identifiable {
    var name: String
    var isCurrent: Bool
    var upstream: String?

    var id: String { name }
}

struct GitRepositorySnapshot: Equatable, Sendable {
    var rootURL: URL?
    var diffFiles: [GitDiffFile] = []
    var branchName: String?
    var upstreamName: String?
    var isDetached: Bool
    var aheadCount: Int
    var behindCount: Int
    var files: [GitStatusEntry]
    var branches: [GitBranch]
    var statusMessage: String?

    static let empty = Self(
        branchName: nil,
        upstreamName: nil,
        isDetached: false,
        aheadCount: 0,
        behindCount: 0,
        files: [],
        branches: [],
        statusMessage: "Not loaded"
    )

    var stagedFiles: [GitStatusEntry] {
        files.filter(\.isStaged)
    }

    var changedFiles: [GitStatusEntry] {
        files.filter { $0.hasWorkingTreeChange && !$0.isUntracked }
    }

    var untrackedFiles: [GitStatusEntry] {
        files.filter(\.isUntracked)
    }

    var hasChanges: Bool {
        !files.isEmpty
    }

    var branchTitle: String {
        if isDetached {
            return branchName.map { "Detached \($0)" } ?? "Detached HEAD"
        }

        return branchName ?? "No branch"
    }

    var footerTitle: String? {
        guard branchName != nil || isDetached else {
            return nil
        }
        let title = isDetached ? "Detached HEAD" : branchTitle
        return "Git: \(title)\(hasChanges ? "*" : "")"
    }

    var trackingTitle: String {
        var components: [String] = []
        if let upstreamName, !upstreamName.isEmpty {
            components.append(upstreamName)
        }
        if aheadCount > 0 {
            components.append("ahead \(aheadCount)")
        }
        if behindCount > 0 {
            components.append("behind \(behindCount)")
        }
        return components.joined(separator: " · ")
    }
}

enum GitCommandKind: Equatable, Sendable {
    case status
    case branches
    case initializeRepository
    case stage(paths: [String])
    case unstage(paths: [String])
    case stash(message: String)
    case commit(message: String)
    case pull
    case push
    case checkout(branch: String)
    case createBranch(name: String)
}

struct GitRepositoryLoadResult: Equatable, Sendable {
    var snapshot: GitRepositorySnapshot
    var statusResult: EditorProcessResult
    var branchResult: EditorProcessResult?

    var succeeded: Bool {
        statusResult.succeeded && (branchResult?.succeeded ?? true)
    }
}

protocol GitRepositoryServicing: Sendable {
    func history(projectURL: URL, head: String?, offset: Int) async -> Result<GitHistoryPage, GitReadError>
    func review(projectURL: URL, commit: GitCommit) async -> Result<GitReview, GitReadError>
    func patch(rootURL: URL, file: GitDiffFile) async -> Result<GitFilePatch, GitReadError>
    func makeCommand(_ kind: GitCommandKind, projectURL: URL) -> EditorProcessCommand
    func snapshot(projectURL: URL) async -> GitRepositoryLoadResult
    func execute(_ kind: GitCommandKind, projectURL: URL) async -> EditorProcessResult
}

actor GitRepositoryService: GitRepositoryServicing {
    let processRunner: any EditorProcessRunning

    init(processRunner: any EditorProcessRunning = EditorProcessRunner()) {
        self.processRunner = processRunner
    }

    nonisolated func makeCommand(_ kind: GitCommandKind, projectURL: URL) -> EditorProcessCommand {
        let arguments: [String] =
            switch kind {
            case .status:
                ["git", "status", "--porcelain=v1", "-b", "-z", "--untracked-files=all"]
            case .branches:
                ["git", "branch", "--format=%(HEAD)%09%(refname:short)%09%(upstream:short)"]
            case .initializeRepository:
                ["git", "init"]
            case let .stage(paths):
                paths.isEmpty ? ["git", "add", "-A"] : ["git", "add", "--"] + paths
            case let .unstage(paths):
                paths.isEmpty ? ["git", "restore", "--staged", "--", "."] : ["git", "restore", "--staged", "--"] + paths
            case let .stash(message):
                ["git", "stash", "push", "-u", "-m", message]
            case let .commit(message):
                ["git", "commit", "-m", message]
            case .pull:
                ["git", "pull"]
            case .push:
                ["git", "push"]
            case let .checkout(branch):
                ["git", "checkout", branch]
            case let .createBranch(name):
                ["git", "checkout", "-b", name]
            }

        return EditorProcessCommand(
            executablePath: "/usr/bin/env",
            arguments: arguments,
            workingDirectory: projectURL,
            displayName: arguments.joined(separator: " ")
        )
    }

    func snapshot(projectURL: URL) async -> GitRepositoryLoadResult {
        let rootResult = await repositoryRoot(at: projectURL)
        guard case let .success(rootURL) = rootResult else {
            let message: String
            if case let .failure(error) = rootResult {
                message = error.message
            } else {
                message = "Repository unavailable."
            }
            var snapshot = GitRepositorySnapshot.empty
            snapshot.statusMessage = message
            return GitRepositoryLoadResult(
                snapshot: snapshot,
                statusResult: EditorProcessResult(
                    command: makeCommand(.status, projectURL: projectURL),
                    exitCode: 1,
                    standardOutput: "",
                    standardError: message
                ),
                branchResult: nil
            )
        }
        let statusResult = await processRunner.run(makeCommand(.status, projectURL: rootURL))
        guard statusResult.succeeded else {
            return GitRepositoryLoadResult(
                snapshot: GitRepositorySnapshot(
                    branchName: nil,
                    upstreamName: nil,
                    isDetached: false,
                    aheadCount: 0,
                    behindCount: 0,
                    files: [],
                    branches: [],
                    statusMessage: statusResult.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                ),
                statusResult: statusResult,
                branchResult: nil
            )
        }

        let branchResult = await processRunner.run(makeCommand(.branches, projectURL: rootURL))
        var snapshot = GitRepositorySnapshot.parseStatus(from: statusResult.standardOutput)
        snapshot.rootURL = rootURL
        if branchResult.succeeded {
            snapshot.branches = GitRepositorySnapshot.parseBranches(from: branchResult.standardOutput)
            snapshot.upstreamName = snapshot.upstreamName ?? snapshot.branches.first(where: \.isCurrent)?.upstream
        } else {
            snapshot.statusMessage = branchResult.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        switch await changeFiles(snapshot: snapshot, root: rootURL) {
        case let .success(files): snapshot.diffFiles = files
        case let .failure(error): snapshot.statusMessage = error.message
        }
        return GitRepositoryLoadResult(snapshot: snapshot, statusResult: statusResult, branchResult: branchResult)
    }

    func execute(_ kind: GitCommandKind, projectURL: URL) async -> EditorProcessResult {
        if case .initializeRepository = kind {
            return await processRunner.run(makeCommand(.initializeRepository, projectURL: projectURL))
        }
        guard case let .success(root) = await repositoryRoot(at: projectURL) else {
            return EditorProcessResult(command: makeCommand(kind, projectURL: projectURL), exitCode: 1, standardOutput: "", standardError: "Repository unavailable.")
        }
        if case let .unstage(paths) = kind {
            let head = await readGit(["rev-parse", "--verify", "HEAD"], at: root)
            if !head.succeeded {
                return await readGit(["rm", "--cached", "-r", "--"] + (paths.isEmpty ? ["."] : paths), at: root)
            }
        }
        var command = makeCommand(kind, projectURL: root)
        command.arguments.insert("--literal-pathspecs", at: 1)
        return await processRunner.run(command)
    }
}

extension GitRepositorySnapshot {
    static func parseStatus(from output: String) -> GitRepositorySnapshot {
        if output.contains("\0") {
            return parseNullStatus(output)
        }
        var branchName: String?
        var upstreamName: String?
        var isDetached = false
        var aheadCount = 0
        var behindCount = 0
        var files: [GitStatusEntry] = []

        for line in output.components(separatedBy: .newlines) where !line.isEmpty {
            if line.hasPrefix("## ") {
                let header = String(line.dropFirst(3))
                let branch = parseBranchHeader(header)
                branchName = branch.name
                upstreamName = branch.upstream
                isDetached = branch.isDetached
                aheadCount = branch.ahead
                behindCount = branch.behind
                continue
            }

            guard let entry = parseStatusEntry(line) else {
                continue
            }
            files.append(entry)
        }

        return GitRepositorySnapshot(
            branchName: branchName,
            upstreamName: upstreamName,
            isDetached: isDetached,
            aheadCount: aheadCount,
            behindCount: behindCount,
            files: files,
            branches: [],
            statusMessage: files.isEmpty ? "Working tree clean" : nil
        )
    }

    private static func parseNullStatus(_ output: String) -> GitRepositorySnapshot {
        let fields = output.components(separatedBy: "\0")
        var snapshot = parseStatus(from: fields.first?.hasPrefix("## ") == true ? fields[0] : "")
        var index = fields.first?.hasPrefix("## ") == true ? 1 : 0
        while index < fields.count {
            let record = fields[index]
            index += 1
            guard record.count >= 4 else {
                continue
            }
            let markers = Array(record.prefix(2))
            let indexStatus = status(from: markers[0])
            let workingStatus = status(from: markers[1])
            var original: String?
            if indexStatus == .renamed || indexStatus == .copied || workingStatus == .renamed || workingStatus == .copied {
                guard index < fields.count else {
                    break
                }
                original = fields[index]
                index += 1
            }
            snapshot.files.append(GitStatusEntry(path: String(record.dropFirst(3)), originalPath: original, indexStatus: indexStatus, workingTreeStatus: workingStatus))
        }
        snapshot.statusMessage = snapshot.files.isEmpty ? "Working tree clean" : nil
        return snapshot
    }

    static func parseBranches(from output: String) -> [GitBranch] {
        output.components(separatedBy: .newlines)
            .compactMap { line in
                guard !line.isEmpty else {
                    return nil
                }

                let parts = line.components(separatedBy: "\t")
                guard parts.count >= 2 else {
                    return nil
                }

                let marker = parts[0]
                let name = parts[1]
                let upstream = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
                return GitBranch(name: name, isCurrent: marker == "*", upstream: upstream)
            }
    }

    private static func parseBranchHeader(_ header: String) -> (name: String?, upstream: String?, isDetached: Bool, ahead: Int, behind: Int) {
        var trackingText: String?
        var branchText = header
        for prefix in ["No commits yet on ", "Initial commit on "] where branchText.hasPrefix(prefix) {
            branchText = String(branchText.dropFirst(prefix.count))
        }
        if let bracketRange = header.range(of: " [", options: .backwards), header.hasSuffix("]") {
            trackingText = String(header[bracketRange.upperBound..<header.index(before: header.endIndex)])
            branchText = String(header[..<bracketRange.lowerBound])
        }

        let branchParts = branchText.components(separatedBy: "...")
        let name = branchParts.first.flatMap { $0.isEmpty ? nil : $0 }
        let upstream = branchParts.count > 1 ? branchParts[1] : nil
        let isDetached = name?.hasPrefix("HEAD") == true
        let ahead = parseTrackingCount("ahead", in: trackingText)
        let behind = parseTrackingCount("behind", in: trackingText)

        return (name, upstream, isDetached, ahead, behind)
    }

    private static func parseTrackingCount(_ key: String, in trackingText: String?) -> Int {
        guard let trackingText else {
            return 0
        }

        let parts = trackingText.components(separatedBy: ",")
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(key) {
                let value = trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
                return Int(value) ?? 0
            }
        }

        return 0
    }

    private static func parseStatusEntry(_ line: String) -> GitStatusEntry? {
        guard line.count >= 4 else {
            return nil
        }

        let index = line[line.startIndex]
        let workingTree = line[line.index(after: line.startIndex)]
        let pathStart = line.index(line.startIndex, offsetBy: 3)
        let rawPath = String(line[pathStart...])
        let paths = parseStatusPath(rawPath)

        return GitStatusEntry(
            path: paths.path,
            originalPath: paths.originalPath,
            indexStatus: status(from: index),
            workingTreeStatus: status(from: workingTree)
        )
    }

    private static func status(from character: Character) -> GitFileStatus? {
        guard character != " " else {
            return nil
        }
        return GitFileStatus(rawValue: String(character))
    }

    private static func parseStatusPath(_ rawPath: String) -> (path: String, originalPath: String?) {
        let separator = " -> "
        guard let range = rawPath.range(of: separator) else {
            return (unquote(rawPath), nil)
        }

        let originalPath = String(rawPath[..<range.lowerBound])
        let path = String(rawPath[range.upperBound...])
        return (unquote(path), unquote(originalPath))
    }

    private static func unquote(_ path: String) -> String {
        guard path.hasPrefix("\""), path.hasSuffix("\"") else {
            return path
        }

        let unquoted = String(path.dropFirst().dropLast())
        return unquoted.replacingOccurrences(of: "\\\"", with: "\"")
    }
}

extension Array where Element: Hashable {
    func removingDuplicates() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
