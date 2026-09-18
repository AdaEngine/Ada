import Foundation

struct EditorTextSearchMatch: Identifiable, Equatable, Sendable {
    var id: String { "\(filePath):\(range.start.line):\(range.start.character)" }
    let filePath: String
    let relativePath: String
    let lineText: String
    let range: EditorSourceRange
}

struct EditorTextSearchResults: Sendable {
    var matches: [EditorTextSearchMatch] = []
    var isTruncated = false
    var skippedFiles = 0
}

/// Disk traversal runs on this actor, never on the editor's main actor.
actor EditorTextSearchService {
    static let ignoredDirectories: Set<String> = [".ada", ".build", ".git", ".swiftpm", "DerivedData", "node_modules"]
    static let maximumFileSize = 4 * 1024 * 1024

    func search(
        root: URL,
        query: String,
        caseSensitive: Bool = false,
        wholeWord: Bool = false,
        openBuffers: [String: String] = [:],
        limit: Int = 500
    ) throws -> EditorTextSearchResults {
        var result = EditorTextSearchResults()
        guard !query.isEmpty, limit > 0 else {
            return result
        }
        let searchRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        var buffers: [String: String] = [:]
        for (path, content) in openBuffers {
            buffers[URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path] = content
        }
        let pattern = NSRegularExpression.escapedPattern(for: query)
        let expression = try NSRegularExpression(
            pattern: wholeWord ? "(?<![\\p{L}\\p{N}_])(?:\(pattern))(?![\\p{L}\\p{N}_])" : pattern,
            options: caseSensitive ? [] : [.caseInsensitive]
        )
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: searchRoot,
                includingPropertiesForKeys: keys,
                options: [],
                errorHandler: { _, _ in true }
            )
        else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var files: [URL] = []
        for case let entry as URL in enumerator {
            try Task.checkCancellation()
            let url = entry.standardizedFileURL
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                result.skippedFiles += 1
                continue
            }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values.isDirectory == true {
                if Self.ignoredDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
            } else if values.isRegularFile == true {
                if (values.fileSize ?? 0) <= Self.maximumFileSize {
                    files.append(url.resolvingSymlinksInPath())
                } else {
                    result.skippedFiles += 1
                }
            }
        }
        let rootPath = searchRoot.path + "/"
        for url in files.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            let content: String
            if let buffer = buffers[url.path] {
                content = buffer
            } else if let data = try? Data(contentsOf: url), !data.contains(0),
                let text = String(bytes: data, encoding: .utf8) {
                content = text
            } else {
                result.skippedFiles += 1
                continue
            }
            var lineNumber = 0
            var cancelled = false
            content.enumerateSubstrings(in: content.startIndex..<content.endIndex, options: .byLines) { line, _, _, stop in
                if Task.isCancelled {
                    cancelled = true
                    stop = true
                    return
                }
                defer { lineNumber += 1 }
                guard let line else {
                    return
                }
                expression.enumerateMatches(in: line, range: NSRange(location: 0, length: line.utf16.count)) { match, _, stopMatches in
                    guard let match else {
                        return
                    }
                    if result.matches.count == limit {
                        result.isTruncated = true
                        stopMatches.pointee = true
                        return
                    }
                    result.matches.append(
                        EditorTextSearchMatch(
                            filePath: root.appendingPathComponent(String(url.path.dropFirst(rootPath.count))).path,
                            relativePath: String(url.path.dropFirst(rootPath.count)),
                            lineText: line,
                            range: EditorSourceRange(
                                start: EditorSourceLocation(line: lineNumber, character: match.range.location),
                                end: EditorSourceLocation(line: lineNumber, character: NSMaxRange(match.range))
                            )
                        )
                    )
                }
                if result.isTruncated {
                    stop = true
                }
            }
            if cancelled {
                throw CancellationError()
            }
            if result.isTruncated {
                break
            }
        }
        return result
    }
}
