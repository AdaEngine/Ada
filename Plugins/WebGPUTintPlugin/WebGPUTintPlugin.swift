//
//  WebGPUTintPlugin.swift
//  AdaEngine
//
//  Created by build plugin
//

import Foundation
import PackagePlugin

@main
class WebGPUTintPlugin: CommandPlugin {
    
    required init() {}
    
    let fileManager = FileManager.default
    
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        if ProcessInfo.processInfo.environment["ADAENGINE_SKIP_WEBGPU_PLUGINS"]?.isEmpty == false {
            Diagnostics.remark("Skipping WebGPU tint plugin (ADAENGINE_SKIP_WEBGPU_PLUGINS is set)")
            return
        }

        Diagnostics.remark("Building Tint Compiler...")
        
        #if os(Windows)
        try await buildTintWindows(context: context, arguments: arguments)
        #elseif os(macOS) || os(Linux)
        try await buildTintUnix(context: context, arguments: arguments)
        #else
        Diagnostics.error("Unsupported platform")
        #endif
    }
    
    #if os(macOS) || os(Linux)
    private func buildTintUnix(context: PluginContext, arguments: [String]) async throws {
        let buildDirectory = context.pluginWorkDirectoryURL
        
        // Ensure the work directory exists
        try fileManager.createDirectory(at: buildDirectory, withIntermediateDirectories: true)
        
        let sourceDir = buildDirectory.appendingPathComponent("source")
        let buildDir = buildDirectory.appendingPathComponent("build")
        let binDir = buildDirectory.appendingPathComponent("bin")
        
        // Determine platform architecture
        let platform: String
        #if arch(arm64)
        #if os(macOS)
        platform = "arm64-macos"
        #else
        platform = "arm64-linux"
        #endif
        #else
        #if os(macOS)
        platform = "x86_64-macos"
        #else
        platform = "x86_64-linux"
        #endif
        #endif
        
        let tintBinary = binDir.appendingPathComponent(platform).appendingPathComponent("tint")
        
        // SHA1 from Defold script
        let sha1 = "7bd151a780126e54de1ca00e9c1ab73dedf96e59"
        // Use GitHub mirror as googlesource may not be accessible
        let repoURL = "https://github.com/google/dawn.git"
        
        // Check if binary already exists
        if fileManager.fileExists(atPath: tintBinary.path) {
            Diagnostics.remark("Tint binary already exists at \(tintBinary.path)")
            return
        }
        
        // Determine source directory
        let actualSourceDir: URL
        if let customSourceDir = ProcessInfo.processInfo.environment["TINT_SOURCE_DIR"],
           !customSourceDir.isEmpty,
           fileManager.fileExists(atPath: customSourceDir) {
            actualSourceDir = URL(fileURLWithPath: customSourceDir)
            Diagnostics.remark("Using custom source directory from TINT_SOURCE_DIR: \(actualSourceDir.path)")
        } else {
            actualSourceDir = sourceDir
        }
        
        // Clone the repo if it doesn't exist
        if !fileManager.fileExists(atPath: actualSourceDir.path) {
            // Ensure parent directory exists for git clone (if using custom source dir)
            if actualSourceDir != sourceDir {
                try fileManager.createDirectory(at: actualSourceDir.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            
            Diagnostics.remark("Cloning Dawn repository...")
            try runCommand(in: actualSourceDir.deletingLastPathComponent(), executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: [
                "clone",
                repoURL,
                actualSourceDir.path
            ])
            
            Diagnostics.remark("Checking out commit \(sha1)...")
            try runGitCommand(in: actualSourceDir, arguments: [
                "reset",
                "--hard",
                sha1
            ])
        } else {
            // Update to correct commit if needed
            Diagnostics.remark("Updating repository to commit \(sha1)...")
            try runGitCommand(in: actualSourceDir, arguments: [
                "fetch",
                "origin"
            ])
            
            try runGitCommand(in: actualSourceDir, arguments: [
                "reset",
                "--hard",
                sha1
            ])
        }
        
        // Create build directories
        let platformBuildDir = buildDir.appendingPathComponent(platform)
        let platformBinDir = binDir.appendingPathComponent(platform)
        
        try fileManager.createDirectory(at: platformBuildDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: platformBinDir, withIntermediateDirectories: true)
        
        // Determine CMake flags based on platform
        var cmakeFlags: [String] = [
            "-DTINT_BUILD_DOCS=OFF",
            "-DTINT_BUILD_TESTS=OFF",
            "-DTINT_BUILD_SPV_READER=ON",
            "-DTINT_ENABLE_INSTALL=ON",
            "-DTINT_BUILD_MSL_WRITER=OFF",
            "-DCMAKE_BUILD_TYPE=Release",
            "-DBUILD_SHARED_LIBS=OFF",
            "-DDAWN_FETCH_DEPENDENCIES=ON"
        ]
        
        // Platform-specific flags
        switch platform {
        case "arm64-macos":
            cmakeFlags.append("-DCMAKE_OSX_ARCHITECTURES=arm64")
            cmakeFlags.append("-DCMAKE_OSX_DEPLOYMENT_TARGET=11.0")
        case "x86_64-macos":
            cmakeFlags.append("-DCMAKE_OSX_ARCHITECTURES=x86_64")
            cmakeFlags.append("-DCMAKE_OSX_DEPLOYMENT_TARGET=11.0")
        case "arm64-linux", "x86_64-linux":
            // Use clang if available
            if fileManager.fileExists(atPath: "/usr/bin/clang") {
                cmakeFlags.append("-DCMAKE_C_COMPILER=clang")
                cmakeFlags.append("-DCMAKE_CXX_COMPILER=clang++")
            }
        default:
            break
        }

        if let pythonExecutable = findPythonExecutable() {
            cmakeFlags.append("-DPython3_EXECUTABLE=\(pythonExecutable.path)")
            cmakeFlags.append("-DPYTHON_EXECUTABLE=\(pythonExecutable.path)")
        }
        
        cmakeFlags.append(actualSourceDir.path)
        
        // Configure CMake
        Diagnostics.remark("Configuring CMake...")
        let cmakePath = URL(fileURLWithPath: "/usr/bin/env")
        cmakeFlags.insert("cmake", at: 0)
        try runCommand(in: platformBuildDir, executable: cmakePath, arguments: cmakeFlags)
        
        // Build
        Diagnostics.remark("Building tint compiler...")
        let cpuCount = ProcessInfo.processInfo.processorCount
        try runCommand(in: platformBuildDir, executable: cmakePath, arguments: [
            "cmake",
            "--build", ".",
            "--target", "tint_cmd_tint_cmd",
            "-j", "\(cpuCount)"
        ])
        
        // Copy binary
        let builtTint = platformBuildDir.appendingPathComponent("tint")
        if fileManager.fileExists(atPath: builtTint.path) {
            let destPath = platformBinDir.appendingPathComponent("tint")
            try fileManager.copyItem(at: builtTint, to: destPath)
            
            // Strip binary if strip is available
            if fileManager.fileExists(atPath: "/usr/bin/strip") {
                try runCommand(in: platformBinDir, executable: URL(fileURLWithPath: "/usr/bin/strip"), arguments: [destPath.path])
            }
            
            Diagnostics.remark("Tint binary built successfully at \(destPath.path)")
        } else {
            throw TintBuildError.binaryNotFound
        }
    }
    
    private func runGitCommand(in directory: URL, arguments: [String]) throws {
        try runCommand(in: directory, executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: arguments)
    }

    private func findPythonExecutable() -> URL? {
        let candidates = [
            ProcessInfo.processInfo.environment["PYTHON3"],
            "/Users/vlad-prusakov/.pyenv/shims/python3",
            "/usr/bin/python3",
            "/opt/homebrew/bin/python3"
        ].compactMap { $0 }

        return candidates
            .map(URL.init(fileURLWithPath:))
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }
    
    private func runCommand(in directory: URL, executable: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            throw TintBuildError.commandFailed(executable: executable.path, status: process.terminationStatus)
        }
    }
    #endif
    
    #if os(Windows)
    private func buildTintWindows(context: PluginContext, arguments: [String]) async throws {
        let buildDirectory = context.pluginWorkDirectoryURL
        
        // Ensure the work directory exists
        try fileManager.createDirectory(at: buildDirectory, withIntermediateDirectories: true)
        
        let sourceDir = buildDirectory.appendingPathComponent("source")
        let buildDir = buildDirectory.appendingPathComponent("build")
        let binDir = buildDirectory.appendingPathComponent("bin")

        if !fileManager.fileExists(atPath: sourceDir.path) {
            try fileManager.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        }
        
        let platform = "x86_64-win32"
        let tintBinary = binDir.appendingPathComponent(platform).appendingPathComponent("tint.exe")
        
        // SHA1 from Defold script
        let sha1 = "7bd151a780126e54de1ca00e9c1ab73dedf96e59"
        // Use GitHub mirror as googlesource may not be accessible
        let repoURL = "https://github.com/google/dawn.git"
        
        // Check if binary already exists
        if fileManager.fileExists(atPath: tintBinary.path) {
            Diagnostics.remark("Tint binary already exists at \(tintBinary.path)")
            return
        }
        
        // Determine source directory
        let actualSourceDir: URL
        if let customSourceDir = ProcessInfo.processInfo.environment["TINT_SOURCE_DIR"],
           !customSourceDir.isEmpty,
           fileManager.fileExists(atPath: customSourceDir) {
            actualSourceDir = URL(fileURLWithPath: customSourceDir)
            Diagnostics.remark("Using custom source directory from TINT_SOURCE_DIR: \(actualSourceDir.path)")
        } else {
            actualSourceDir = sourceDir
        }
        
        // Clone the repo if it doesn't exist
        if !fileManager.fileExists(atPath: actualSourceDir.path) {
            // Ensure parent directory exists for git clone (if using custom source dir)
            if actualSourceDir != sourceDir {
                try fileManager.createDirectory(at: actualSourceDir.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            
            Diagnostics.remark("Cloning Dawn repository...")
            let gitPath = URL(fileURLWithPath: "C:\\Program Files\\Git\\cmd\\git.exe")
            if !fileManager.fileExists(atPath: gitPath.path) {
                // Try alternative path
                let altGitPath = URL(fileURLWithPath: "C:\\Program Files (x86)\\Git\\cmd\\git.exe")
                if fileManager.fileExists(atPath: altGitPath.path) {
                    try runCommandWindows(in: actualSourceDir.deletingLastPathComponent(), executable: altGitPath, arguments: [
                        "clone",
                        repoURL,
                        actualSourceDir.path
                    ])
                } else {
                    throw TintBuildError.gitNotFound
                }
            } else {
                try runCommandWindows(in: actualSourceDir.deletingLastPathComponent(), executable: gitPath, arguments: [
                    "clone",
                    repoURL,
                    actualSourceDir.path
                ])
            }
            
            Diagnostics.remark("Checking out commit \(sha1)...")
            try runGitCommandWindows(in: actualSourceDir, arguments: [
                "reset",
                "--hard",
                sha1
            ])
        } else {
            // Update to correct commit if needed
            Diagnostics.remark("Updating repository to commit \(sha1)...")
            try runGitCommandWindows(in: actualSourceDir, arguments: [
                "fetch",
                "origin"
            ])
            
            try runGitCommandWindows(in: actualSourceDir, arguments: [
                "reset",
                "--hard",
                sha1
            ])
        }
        
        // Create build directories
        let platformBuildDir = buildDir.appendingPathComponent(platform)
        let platformBinDir = binDir.appendingPathComponent(platform)
        
        try fileManager.createDirectory(at: platformBuildDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: platformBinDir, withIntermediateDirectories: true)
        
        // CMake flags
        var cmakeFlags: [String] = [
            "-DTINT_BUILD_DOCS=OFF",
            "-DTINT_BUILD_TESTS=OFF",
            "-DTINT_BUILD_SPV_READER=ON",
            "-DTINT_ENABLE_INSTALL=ON",
            "-DTINT_BUILD_MSL_WRITER=OFF",
            "-DCMAKE_BUILD_TYPE=Release",
            "-DBUILD_SHARED_LIBS=OFF",
            "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded",
            "-DDAWN_FETCH_DEPENDENCIES=ON",
            actualSourceDir.path
        ]
        
        // Configure CMake
        Diagnostics.remark("Configuring CMake...")
        try runCommandWindows(in: platformBuildDir, executable: URL(fileURLWithPath: "cmake"), arguments: cmakeFlags)
        
        // Build
        Diagnostics.remark("Building tint compiler...")
        try runCommandWindows(in: platformBuildDir, executable: URL(fileURLWithPath: "cmake"), arguments: [
            "--build", ".",
            "--target", "tint_cmd_tint_cmd",
            "-j", "8"
        ])
        
        // Copy binary
        let builtTint = platformBuildDir.appendingPathComponent("tint.exe")
        if fileManager.fileExists(atPath: builtTint.path) {
            let destPath = platformBinDir.appendingPathComponent("tint.exe")
            try fileManager.copyItem(at: builtTint, to: destPath)
            Diagnostics.remark("Tint binary built successfully at \(destPath.path)")
        } else {
            throw TintBuildError.binaryNotFound
        }
    }
    
    private func runGitCommandWindows(in directory: URL, arguments: [String]) throws {
        let gitPath = URL(fileURLWithPath: "C:\\Program Files\\Git\\cmd\\git.exe")
        let altGitPath = URL(fileURLWithPath: "C:\\Program Files (x86)\\Git\\cmd\\git.exe")
        
        let executable: URL
        if fileManager.fileExists(atPath: gitPath.path) {
            executable = gitPath
        } else if fileManager.fileExists(atPath: altGitPath.path) {
            executable = altGitPath
        } else {
            throw TintBuildError.gitNotFound
        }
        
        try runCommandWindows(in: directory, executable: executable, arguments: arguments)
    }
    
    private func runCommandWindows(in directory: URL, executable: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            throw TintBuildError.commandFailed(executable: executable.path, status: process.terminationStatus)
        }
    }
    #endif
}

enum TintBuildError: LocalizedError {
    case binaryNotFound
    case gitNotFound
    case commandFailed(executable: String, status: Int32)
    
    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "Tint binary not found after build"
        case .gitNotFound:
            return "Git executable not found. Please install Git for Windows."
        case .commandFailed(let executable, let status):
            return "Command '\(executable)' failed with exit status \(status)"
        }
    }
}
