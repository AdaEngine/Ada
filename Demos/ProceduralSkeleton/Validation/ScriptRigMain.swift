import AdaAssets
import AdaScriptCompilerCore
import AdaScripting
import Foundation

/// Developer harness: the model is authored entirely by the same interpreted generator used in the app.
@main
struct ScriptRigMain {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { return }
        let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let issues = AdaScriptLinter.lint(source: source)
        guard issues.isEmpty else {
            let details = issues.prefix(8).map { "\($0.rule.rawValue) at line \($0.range.start.line + 1)" }.joined(separator: ", ")
            throw NSError(domain: "ScriptRigStudy", code: 1, userInfo: [NSLocalizedDescriptionKey: "Recipe lint: \(issues.count) issues: \(details)"])
        }
        let start = ContinuousClock.now
        let model = try AdaScriptModelGenerator.generate(source: source)
        let duration = start.duration(to: .now)
        let data = try GLBWriter().encode(model)
        let loaded = try NativeGLTFLoader().load(data: data)
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
        let report: [String: Any] = ["sourceBytes": source.utf8.count, "sourceLintIssues": issues.count, "bytes": data.count, "joints": loaded.skins.first?.joints.count ?? 0,
                                   "clips": loaded.animations.map { $0.name ?? "" }, "meshes": loaded.meshes.count,
                                   "execution": "AdaScript bytecode VM plus precompiled native builder; no subprocess during generation",
                                   "generationSeconds": Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
