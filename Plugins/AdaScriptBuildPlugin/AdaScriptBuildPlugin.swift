import Foundation
import PackagePlugin

@main
struct AdaScriptBuildPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let sourceModule = target.sourceModule else {
            return []
        }

        let tool = try context.tool(named: "AdaScriptGeneratorTool")
        let scripts = sourceModule.sourceFiles
            .map(\.url)
            .filter { $0.pathExtension.lowercased() == "ada" }
            .sorted { $0.path < $1.path }
        let output = context.pluginWorkDirectoryURL.appendingPathComponent("AdaScriptPluginsGenerated.swift")

        let libraryInputs = libraryInputFiles(at: context.package.directoryURL)
        let projectSettings = context.package.directoryURL.appendingPathComponent(".ada/project.json")
        let projectInputs = FileManager.default.fileExists(atPath: projectSettings.path) ? [projectSettings] : []
        let typeCheckingArguments = isStrictTypeCheckingEnabled(at: projectSettings) ? ["--strict"] : []

        return [
            .buildCommand(
                displayName: "Generate Ada script plugins for \(target.name)",
                executable: tool.url,
                arguments: [
                    "--output", output.path,
                    "--root", target.directoryURL.path,
                    "--module-name", target.name,
                    "--libraries-root", context.package.directoryURL.path
                ] + typeCheckingArguments + scripts.map(\.path),
                environment: [:],
                inputFiles: scripts + libraryInputs.sorted { $0.path < $1.path } + projectInputs,
                outputFiles: [output]
            )
        ]
    }

    private func isStrictTypeCheckingEnabled(at settingsURL: URL) -> Bool {
        guard
            let data = try? Data(contentsOf: settingsURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let build = object["build"] as? [String: Any],
            let mode = build["adaScriptTypeChecking"] as? String
        else {
            return false
        }
        return mode == "strict"
    }

    private func libraryInputFiles(at packageURL: URL) -> [URL] {
        let libraryRoot = packageURL.appendingPathComponent(".ada")
        var libraryInputs: [URL] = []
        let lock = libraryRoot.appendingPathComponent("libraries.lock.json")
        if FileManager.default.fileExists(atPath: lock.path) {
            libraryInputs.append(lock)
            if let files = FileManager.default.enumerator(
                at: libraryRoot.appendingPathComponent("libraries"),
                includingPropertiesForKeys: [.isRegularFileKey]
            ) {
                for case let url as URL in files where url.pathExtension == "ada" {
                    libraryInputs.append(url)
                }
            }
        }
        return libraryInputs
    }
}
