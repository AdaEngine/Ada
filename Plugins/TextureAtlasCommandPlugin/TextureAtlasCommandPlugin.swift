//
//  TextureAtlasCommandPlugin.swift
//  AdaEngine
//

import Foundation
import PackagePlugin

@main
struct TextureAtlasCommandPlugin: CommandPlugin {

    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let tool = try context.tool(named: "TextureAtlasBuilderTool")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool.path.string)
        process.arguments = arguments
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            Diagnostics.error("TextureAtlasBuilderTool exited with status \(process.terminationStatus)")
        }
    }
}
