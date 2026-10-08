//
//  WebGPUBuildPlugin.swift
//  AdaEngine
//
//  Created by build plugin
//

import Foundation
import PackagePlugin

@main
struct WebGPUBuildPlugin: BuildToolPlugin {

    let fileManager = FileManager.default

    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        if ProcessInfo.processInfo.environment["ADAENGINE_SKIP_WEBGPU_PLUGINS"]?.isEmpty == false {
            Diagnostics.remark("Skipping WebGPU build plugin (ADAENGINE_SKIP_WEBGPU_PLUGINS is set)")
            return []
        }

        var commands: [Command] = []
        
        #if os(Windows)
        commands.append(contentsOf: try createWindowsCommands(context: context, target: target))
        #endif

        try commands.append(contentsOf: copyTintToAdaEngine(context: context, target: target))
        return commands
    }
    
    #if os(Windows)
    private func createWindowsCommands(context: PluginContext, target: Target) throws -> [Command] {
        let buildDirectory = context.pluginWorkDirectory
        let dllNames = ["D3DCompiler.dll"]
        var searchPaths: [String] = [
            "C:\\Windows\\System32",
            "C:\\Windows\\SysWOW64"
        ]

        var commands: [Command] = []
        
        for dllName in dllNames {
            let outputPath = buildDirectory.appending(dllName)
            
            let searchPathsString = searchPaths.map { "\"\($0.replacingOccurrences(of: "\\", with: "\\\\"))\"" }.joined(separator: ", ")
            let outputPathEscaped = outputPath.string.replacingOccurrences(of: "\\", with: "\\\\")
            let scriptContent = """
            $dllName = "\(dllName)"
            $outputPath = "\(outputPathEscaped)"
            $searchPaths = @(\(searchPathsString))
            
            $found = $false
            foreach ($path in $searchPaths) {
                if (Test-Path $path) {
                    $dllPath = Join-Path $path $dllName
                    if (Test-Path $dllPath) {
                        $outputDir = Split-Path -Parent $outputPath
                        if (-not (Test-Path $outputDir)) {
                            New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
                        }
                        Copy-Item $dllPath $outputPath -Force
                        Write-Host "Copied $dllName from $dllPath to $outputPath"
                        $found = $true
                        break
                    }
                }
            }
            
            if (-not $found) {
                Write-Warning "Could not find $dllName in any of the search paths"
            }
            """
            commands.append(
                .prebuildCommand(
                    displayName: "Copy \(dllName) to build directory",
                    executable: Path("C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"),
                    arguments: [
                        "-ExecutionPolicy", "Bypass",
                        "-NoProfile",
                        "-Command", scriptContent
                    ],
                    outputFilesDirectory: buildDirectory
                )
            )
        }
        
        return commands
    }
    #endif

    private func copyTintToAdaEngine(
        context: PluginContext,
        target: Target
    ) throws -> [Command] {
        let packageDirectory = context.package.directoryURL
        let binDirecotry = packageDirectory.appending(
            components: ".build", "plugins", "WebGPUTintPlugin", "outputs", "bin", .tintBinaryPlatform, .tintBinaryName,
            directoryHint: .notDirectory
        )

        guard fileManager.fileExists(atPath: binDirecotry.path()) else {
            throw PluginError.error("""
            Tint binary not found at working directory. 
            Please run `swift package plugin build-tint` to download tint
            """)
        }

        let tintOutputDirectory = context.pluginWorkDirectoryURL.appending(
            component: "tools",
            directoryHint: .isDirectory
        )

        if !fileManager.fileExists(atPath: tintOutputDirectory.path()) {
            try fileManager.createDirectory(
                at: tintOutputDirectory,
                withIntermediateDirectories: true
            )
        }

        let outputPath = tintOutputDirectory.appending(component: String.tintBinaryName, directoryHint: .notDirectory)

        return [
            .buildCommand(
                displayName: "Copy Tint binary",
                executable: URL(fileURLWithPath: "/bin/cp"),
                arguments: [
                    binDirecotry.path(),
                    outputPath.path()
                ],
                environment: [:],
                inputFiles: [
                    binDirecotry
                ],
                outputFiles: [
                    outputPath
                ]
            )
        ]
    }
}

private extension String {
    static var tintBinaryPlatform: String {
#if arch(arm64)

#if os(macOS)
        return "arm64-macos"
#elseif os(Linux)
        return "arm64-linux"
#else
        Diagnostics.error("Not supported platform")
        return ""
#endif
#else

#if os(macOS)
        return "x86_64-macos"
#elseif os(Linux)
        return "x86_64-linux"
#elseif os(Windows)
        return "x86_64-win32"
#else
        Diagnostics.error("Not supported platform")
        return ""
#endif

#endif
    }

    static var tintBinaryName: String {
        #if os(Windows)
        "tint.exe"
        #else
        "tint"
        #endif
    }
}

enum PluginError: LocalizedError {

    case error(String)

    var errorDescription: String? {
        switch self {
        case .error(let string):
            return string
        }
    }
}
