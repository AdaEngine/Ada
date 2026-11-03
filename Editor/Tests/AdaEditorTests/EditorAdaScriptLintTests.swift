#if os(macOS) || os(Windows) || os(Linux)
import Foundation
import Testing

@testable import AdaEditor

@Suite("Ada Studio CLI style checks", .serialized)
struct EditorAdaScriptLintTests {
    @Test("Validation warns by default, fails in strict mode and can skip style checks")
    func validationModes() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Sources/Main.ada")
        let original = try Data(contentsOf: file)
        let metadata = try Data(contentsOf: ProjectSystem.metadataURL(forProjectAt: root))
        for mode in ["warning", "strict", "off"] {
            let invocation = try EditorCLIInvocation(arguments: ["validate", "--project", root.path, "--lint", mode, "--format", "json"])
            let report = await EditorCLI.execute(invocation)
            #expect(report.ok == (mode != "strict"))
            #expect(report.exitCode == (mode == "strict" ? 3 : 0))
            if mode == "off" {
                #expect(report.diagnostics.isEmpty)
            } else {
                let issue = try #require(report.diagnostics.first)
                #expect(issue.code == "adascript-lint.operator_spacing")
                #expect(issue.severity == "warning")
                #expect(issue.file == "Sources/Main.ada")
                #expect(issue.line == 2)
                #expect(issue.column == 14)
                #expect(issue.text.hasPrefix("Sources/Main.ada:2:14: warning:"))
                let decoded = try JSONDecoder().decode(EditorCLIReport.self, from: report.encoded())
                #expect(decoded.diagnostics == report.diagnostics)
            }
        }
        let defaultReport = await EditorCLI.execute(try EditorCLIInvocation(arguments: ["validate", "--project", root.path]))
        #expect(defaultReport.ok)
        #expect(!defaultReport.diagnostics.isEmpty)
        #expect(try Data(contentsOf: file) == original)
        #expect(try Data(contentsOf: ProjectSystem.metadataURL(forProjectAt: root)) == metadata)
        try "func main() { return 42; }".write(to: file, atomically: true, encoding: .utf8)
        let cleanReport = await EditorCLI.execute(try EditorCLIInvocation(arguments: ["validate", "--project", root.path, "--lint", "strict"]))
        #expect(cleanReport.ok)
        #expect(cleanReport.diagnostics.isEmpty)
    }

    @Test("Saved tests are linted, hidden files and third-party libraries are skipped")
    func authoredFiles() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Tests/Rules.gravity", "Sources/.hidden/Generated.ada", ".ada/libraries/Library.ada"] {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "var count=1;".write(to: file, atomically: true, encoding: .utf8)
        }
        let project = try ProjectSystem.loadProject(at: root)
        let diagnostics = try EditorAdaScriptLint.diagnostics(project: project, at: root)
        #expect(Set(diagnostics.compactMap(\.file)) == ["Sources/Main.ada", "Tests/Rules.gravity"])
        #expect(diagnostics.contains { $0.file == "Tests/Rules.gravity" && $0.code == "adascript-lint.operator_spacing" })
    }

    @Test("Invalid modes and lint options on other commands are usage errors")
    func arguments() {
        for words in [["validate", "--lint", "unknown"], ["inspect", "--lint", "strict"], ["build", "--lint", "strict"]] {
            #expect(throws: EditorCLIError.self) { try EditorCLIInvocation(arguments: words) }
        }
    }

    @Test("The active target's excluded source files do not produce style warnings")
    func sourceMembership() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var project = try ProjectSystem.loadProject(at: root)
        project.build.excludedFiles = ["Sources/Main.ada"]
        #expect(try EditorAdaScriptLint.diagnostics(project: project, at: root).isEmpty)
    }

    @Test("Live editor warnings survive builds and clear after an unsaved correction")
    @MainActor
    func liveEditorDiagnostics() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Sources/Main.ada")
        let original = try String(contentsOf: file, encoding: .utf8)
        let document = EditorTextDocument(
            id: "main", title: "Main.ada", relativePath: "Sources/Main.ada", absolutePath: file.path, language: .ada, content: original
        )
        let model = EditorViewModel(
            project: EditorProjectReference(name: "Lint Game", path: root.path),
            workspaceService: SwiftPMWorkspaceService(),
            workbench: EditorWorkbenchViewModel(
                activeEditorTab: document.title, openDocuments: [.text(document)], activeDocumentID: document.id
            )
        )
        model.refreshSemanticTokens(for: .text(document))
        for _ in 0..<200 {
            if model.problems.contains(where: { $0.source == "adascript-lint" }) {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let issue = try #require(model.problems.first { $0.source == "adascript-lint" })
        #expect(issue.isLanguageServiceDiagnostic)
        #expect(issue.severity == .warning)
        #expect(issue.code == "operator_spacing")
        #expect(model.workbench.textDocument(id: document.id)?.diagnostics.contains(issue) == true)
        #expect(L10n.catalog.string(issue.message, language: .russian) == "Добавьте пробелы вокруг бинарных операторов.")
        model.replaceBuildDiagnostics(with: [])
        #expect(model.problems.contains(issue))
        var fixed = document
        fixed.content = "func main() { return 42; }"
        model.workbench.updateTextDocument(id: fixed.id) { $0.content = fixed.content }
        model.refreshSemanticTokens(for: .text(fixed))
        for _ in 0..<200 {
            if model.problems.isEmpty {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.problems.isEmpty)
        #expect(model.workbench.textDocument(id: document.id)?.diagnostics.isEmpty == true)
        #expect(try String(contentsOf: file, encoding: .utf8) == original)
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Lint Game \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Assets"), withIntermediateDirectories: true)
        var project = ProjectSystem.defaultProject(projectName: "Lint Game", buildSystem: .adaScript)
        project.runtime.entry = .init(scene: "Assets/Main.ascn")
        try ProjectSystem.saveProject(project, at: root)
        try "func main() {\n    var speed=1;speed+=1;\n    return speed;\n}".write(
            to: root.appendingPathComponent("Sources/Main.ada"), atomically: true, encoding: .utf8
        )
        try EditorSceneModel.default(projectName: "Lint Game").encodedYAML().write(
            to: root.appendingPathComponent("Assets/Main.ascn"), atomically: true, encoding: .utf8
        )
        return root
    }
}
#endif
