import Foundation

struct GitReadError: Error, Equatable, Sendable, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

struct GitCommit: Equatable, Sendable, Identifiable {
    var id: String
    var parents: [String]
    var author: String
    var date: Date
    var subject: String
    var message: String
    var shortID: String { String(id.prefix(7)) }
    var comparisonTitle: String {
        parents.count > 1 ? "Compared with first parent \(String(parents[0].prefix(7)))" : "Changes in this commit"
    }
}

struct GitHistoryPage: Equatable, Sendable {
    var commits: [GitCommit]
    var hasMore: Bool
    var head: String?
}

enum GitComparison: Hashable, Sendable {
    case staged
    case workingTree
    case untracked
    case commit(base: String?, head: String)

    var title: String {
        switch self {
        case .staged: "Staged"
        case .workingTree: "Changes"
        case .untracked: "Untracked"
        case .commit: "Commit"
        }
    }

    var isHistorical: Bool {
        if case .commit = self {
            return true
        }
        return false
    }
}

struct GitDiffStatistics: Equatable, Sendable {
    var additions = 0
    var deletions = 0
    var isBinary = false
    var title: String { isBinary ? "Binary" : "+\(additions) −\(deletions)" }
}

struct GitDiffFile: Equatable, Sendable, Identifiable {
    var path: String
    var originalPath: String?
    var status: GitFileStatus
    var comparison: GitComparison
    var statistics = GitDiffStatistics()
    var id: String { "\(comparison.title):\(path)" }
    var paths: [String] { Array(Set([originalPath, path].compactMap { $0 })).sorted() }
    var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    var directory: String { path.split(separator: "/").dropLast().joined(separator: "/") }
}

struct GitReview: Equatable, Sendable {
    var rootURL: URL
    var files: [GitDiffFile]
    var commit: GitCommit?
}

struct GitDiffLine: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case context, addition, deletion, note }
    var kind: Kind
    var text: String
    var oldNumber: Int?
    var newNumber: Int?
}

struct GitDiffHunk: Equatable, Sendable, Identifiable {
    var id: Int
    var header: String
    var lines: [GitDiffLine]

    /// Consecutive deletions and insertions share rows in split mode.
    var alignedLines: [(old: GitDiffLine?, new: GitDiffLine?)] {
        var result: [(GitDiffLine?, GitDiffLine?)] = []
        var deleted: [GitDiffLine] = []
        var added: [GitDiffLine] = []
        func flush() {
            for index in 0..<max(deleted.count, added.count) {
                result.append((deleted.indices.contains(index) ? deleted[index] : nil, added.indices.contains(index) ? added[index] : nil))
            }
            deleted.removeAll(keepingCapacity: true)
            added.removeAll(keepingCapacity: true)
        }
        for line in lines {
            switch line.kind {
            case .deletion: deleted.append(line)
            case .addition: added.append(line)
            case .context,
                .note:
                flush()
                result.append((line, line))
            }
        }
        flush()
        return result
    }
}

struct GitFilePatch: Equatable, Sendable {
    var hunks: [GitDiffHunk]
    var message: String?

    static func parse(_ output: String) -> Self {
        var hunks: [GitDiffHunk] = []
        var oldNumber = 0
        var newNumber = 0
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("@@ ") {
                let parts = line.split(separator: " ")
                guard
                    parts.count >= 3,
                    let old = Int(parts[1].dropFirst().split(separator: ",")[0]),
                    let new = Int(parts[2].dropFirst().split(separator: ",")[0])
                else {
                    continue
                }
                oldNumber = old
                newNumber = new
                hunks.append(GitDiffHunk(id: hunks.count, header: line, lines: []))
            } else if !hunks.isEmpty, let prefix = line.first {
                let parsed: GitDiffLine
                switch prefix {
                case " ":
                    parsed = GitDiffLine(kind: .context, text: String(line.dropFirst()), oldNumber: oldNumber, newNumber: newNumber)
                    oldNumber += 1
                    newNumber += 1
                case "-":
                    parsed = GitDiffLine(kind: .deletion, text: String(line.dropFirst()), oldNumber: oldNumber, newNumber: nil)
                    oldNumber += 1
                case "+":
                    parsed = GitDiffLine(kind: .addition, text: String(line.dropFirst()), oldNumber: nil, newNumber: newNumber)
                    newNumber += 1
                case "\\":
                    parsed = GitDiffLine(kind: .note, text: line, oldNumber: nil, newNumber: nil)
                default: continue
                }
                hunks[hunks.count - 1].lines.append(parsed)
            }
        }
        let binary = output.contains("Binary files ") || output.contains("GIT binary patch")
        return Self(hunks: hunks, message: binary ? "Binary file changed" : (hunks.isEmpty ? "No textual changes (metadata only)." : nil))
    }
}
