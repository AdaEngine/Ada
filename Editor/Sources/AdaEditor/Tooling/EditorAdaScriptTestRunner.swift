import AdaScriptCompilerCore
import AdaScripting
import Foundation

/// One finished `@test`, in a form the editor and the MCP tools can print.
struct EditorAdaScriptTestOutcome: Equatable, Sendable {
    let name: String
    let path: String
    let line: Int
    let passed: Bool
    let seconds: Double
    let diagnostics: [String]
}

/// Counts shown by `editor.task.status` after a test run.
struct EditorAdaScriptTestSummary: Equatable, Sendable {
    var passed: Int
    var failed: Int
    var filter: String?
    var outcomes: [EditorAdaScriptTestOutcome]
    var finished: Bool

    var total: Int { passed + failed }
}

enum EditorAdaScriptTestError: Error, LocalizedError, Equatable {
    case noTests(filter: String?)
    case sourceReadFailed(path: String, message: String)
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case let .noTests(filter):
            if let filter, !filter.isEmpty {
                return "No @test function matches '\(filter)'. Tests are free functions marked @test in any .ada file or under Tests/."
            }
            return "This project has no AdaScript tests. Write @test functions in any .ada file or under Tests/, then run editor.test.start again."
        case let .sourceReadFailed(path, message): return "Could not read \(path): \(message)"
        case let .loadFailed(message): return message
        }
    }
}

/// Runs the `@test` functions of an AdaScript project inside the editor process, without SwiftPM (ADR-0024).
///
/// Sources come from the project's source root and its `Tests/` directory, with project-relative paths so failures read
/// as `Tests/FlightTests.ada:4:2: ...`. `Tools/` and library lock files follow the same rules as a project build.
struct EditorAdaScriptTestRunner {
    static let defaultTestTimeout: Duration = .seconds(30)

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Whether the project has anything that looks like a test, without compiling it.
    func hasTests(project: AdaProject, at projectURL: URL) -> Bool {
        guard let sources = try? loadSources(project: project, at: projectURL) else { return false }
        return sources.contains { $0.source.contains("@test") }
    }

    /// Discovers declarations without loading a VM or executing project code.
    func discover(project: AdaProject, at projectURL: URL) throws(EditorAdaScriptTestError) -> [EditorTestItem] {
        try loadSources(project: project, at: projectURL).flatMap { source in
            AdaScriptSyntax.parse(source: source.source, path: source.path).tests.map { test in
                EditorTestItem(id: source.path + ":" + test.name, name: test.displayName,
                               filter: test.name, path: source.path, line: test.range.start.line + 1)
            }
        }
    }

    /// Compiles the project with tests and runs them. Throws for load problems and when nothing matches.
    func run(
        project: AdaProject,
        at projectURL: URL,
        filter: String?,
        exactName: String? = nil,
        testTimeout: Duration = Self.defaultTestTimeout,
        onResult: ((EditorAdaScriptTestOutcome) -> Void)? = nil
    ) throws(EditorAdaScriptTestError) -> [EditorAdaScriptTestOutcome] {
        let sources = try loadSources(project: project, at: projectURL)
        let results: [AdaScriptTestResult]
        do {
            let plugin = try AdaScriptPlugin(
                sources: sources,
                name: project.project.name ?? projectURL.lastPathComponent,
                includeTests: true,
                testTimeout: testTimeout
            )
            results = plugin.runTests(matching: filter, exactName: exactName, onResult: { onResult?(Self.outcome(of: $0)) })
        } catch let error as AdaScriptError {
            throw .loadFailed(error.errorDescription ?? error.localizedDescription)
        } catch {
            throw .loadFailed(error.localizedDescription)
        }
        guard !results.isEmpty else { throw .noTests(filter: filter) }
        return results.map(Self.outcome(of:))
    }

    static func outcome(of result: AdaScriptTestResult) -> EditorAdaScriptTestOutcome {
        let parts = result.duration.components
        return EditorAdaScriptTestOutcome(
            name: result.test.displayName,
            path: result.test.path,
            line: result.test.line,
            passed: result.outcome == .passed,
            seconds: Double(parts.seconds) + Double(parts.attoseconds) / 1e18,
            diagnostics: result.diagnostics
        )
    }

    /// Output lines for one test: a status line, then its diagnostics.
    static func lines(for outcome: EditorAdaScriptTestOutcome) -> [String] {
        let duration = String(format: "%.3fs", outcome.seconds)
        if outcome.passed {
            return ["PASS \(outcome.name) (\(outcome.path):\(outcome.line), \(duration))"]
        }
        return ["FAIL \(outcome.name) (\(outcome.path):\(outcome.line), \(duration))"] + outcome.diagnostics.map { "  \($0)" }
    }

    static func summaryLine(passed: Int, failed: Int) -> String {
        "\(passed) passed, \(failed) failed, \(passed + failed) total"
    }

    // MARK: Sources

    private func loadSources(project: AdaProject, at projectURL: URL) throws(EditorAdaScriptTestError) -> [AdaScriptSource] {
        let root = projectURL.resolvingSymlinksInPath().standardizedFileURL
        let sourceRoot = project.paths.sources ?? "Sources"
        var seen = Set<String>()
        var sources: [AdaScriptSource] = []
        for directory in [sourceRoot, "Tests"] {
            for source in try adaFiles(under: root.appendingPathComponent(directory, isDirectory: true), projectRoot: root) where seen.insert(source.path).inserted {
                sources.append(source)
            }
        }
        sources.sort { $0.path < $1.path }
        do {
            return sources + (try AdaScriptLibraryLock.load(at: projectURL).loadSources(at: projectURL))
        } catch {
            throw .loadFailed(error.localizedDescription)
        }
    }

    private func adaFiles(under directory: URL, projectRoot: URL) throws(EditorAdaScriptTestError) -> [AdaScriptSource] {
        guard
            let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }
        let tools = projectRoot.appendingPathComponent("Tools").path
        let prefix = projectRoot.path + "/"
        var sources: [AdaScriptSource] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "ada" {
            let standardized = url.standardizedFileURL
            guard !standardized.path.hasPrefix(tools + "/") else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            let path = standardized.path.hasPrefix(prefix) ? String(standardized.path.dropFirst(prefix.count)) : url.lastPathComponent
            do {
                sources.append(AdaScriptSource(path: path, source: try String(contentsOf: url, encoding: .utf8)))
            } catch {
                throw .sourceReadFailed(path: path, message: error.localizedDescription)
            }
        }
        return sources
    }
}
