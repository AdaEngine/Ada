import AdaWGSLCompiler
import Foundation
#if os(Windows)
import CRT
#elseif canImport(Glibc)
import Glibc
#else
import Darwin
#endif

@main
struct AdaShaderTranspilerTool {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func run() throws {
        let options = try Options(arguments: CommandLine.arguments.dropFirst())
        try compileWESL(options)
    }

    private static func compileWESL(_ options: Options) throws {
        let input = options.input.standardizedFileURL
        let root = (options.weslRoot ?? input.deletingLastPathComponent()).standardizedFileURL
        let features = Dictionary(uniqueKeysWithValues: options.features.map { ($0, true) })
        let artifact = try WESLHostCompiler.compile(sourceFile: input, packageRoot: root, features: features, dependencies: options.weslDependencies)
        if options.target != "wgsl" {
            try compileNativeStages(artifact, options: options)
            return
        }
        try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
        if options.webStages {
            var stages: Set<String> = []
            for entry in artifact.entryPoints {
                guard stages.insert(entry.stage).inserted else {
                    throw ToolError.invalidArgument("A bundled WESL shader must have one entry point per active stage.")
                }
            }
            let stem = ([input.lastPathComponent] + options.features).joined(separator: ".")
            for stage in stages.sorted() {
                let suffix = switch stage {
                case "vertex": "vert"
                case "fragment": "frag"
                case "compute": "comp"
                default: throw ToolError.invalidArgument("Unsupported WESL stage '\(stage)'.")
                }
                let output = options.outputDirectory.appendingPathComponent(stem)
                    .appendingPathExtension(suffix).appendingPathExtension("wgsl")
                try artifact.wgsl.write(to: output, atomically: true, encoding: .utf8)
                print(output.path)
            }
            return
        }
        let stem = ([input.deletingPathExtension().lastPathComponent] + options.features).joined(separator: ".")
        let output = options.outputDirectory.appendingPathComponent(stem).appendingPathExtension("wgsl")
        try artifact.wgsl.write(to: output, atomically: true, encoding: .utf8)
        print(output.path)
    }

    private static func compileNativeStages(_ module: WESLHostCompiler.Artifact, options: Options) throws {
        guard let target = WESLBackendCompiler.Target(rawValue: options.target) else {
            throw ToolError.invalidArgument("Unsupported WESL backend target")
        }
        var stages: Set<String> = []
        for entry in module.entryPoints {
            guard stages.insert(entry.stage).inserted else {
                throw ToolError.invalidArgument("A bundled WESL shader must have one entry point per active stage.")
            }
        }
        // Compile the complete batch before writing any output if a stage is unsupported.
        let compiled = try WESLBackendCompiler.compile(module, to: target)
        try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
        let stem = ([options.input.deletingPathExtension().lastPathComponent] + options.features).joined(separator: ".")
        let suffix = target == .spirv ? "spv" : "msl"
        for entry in compiled {
            let output = options.outputDirectory.appendingPathComponent(stem)
                .appendingPathExtension(entry.fileExtension).appendingPathExtension(suffix)
            try entry.data.write(to: output, options: .atomic)
            print(output.path)
        }
    }
}

private struct Options {
    let input: URL
    let outputDirectory: URL
    let weslRoot: URL?
    let weslDependencies: [String: URL]
    let features: [String]
    let webStages: Bool
    let target: String

    init(arguments: ArraySlice<String>) throws {
        var input: URL?
        var outputDirectory: URL?
        var weslRoot: URL?
        var weslDependencies: [String: URL] = [:]
        var features: Set<String> = []
        var webStages = false
        var target = "wgsl"
        var iterator = arguments.makeIterator()

        while let argument = iterator.next() {
            switch argument {
            case "--input":
                input = try Self.nextURL(from: &iterator, for: argument)
            case "--output-directory":
                outputDirectory = try Self.nextURL(from: &iterator, for: argument)
            case "--wesl-root":
                weslRoot = try Self.nextURL(from: &iterator, for: argument)
            case "--wesl-dependency":
                let value = try Self.nextValue(from: &iterator, for: argument)
                let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, weslDependencies[parts[0]] == nil else {
                    throw ToolError.invalidArgument("--wesl-dependency expects a unique PackageName=/path/to/package")
                }
                weslDependencies[parts[0]] = URL(fileURLWithPath: parts[1])
            case "--feature":
                features.insert(try Self.nextValue(from: &iterator, for: argument))
            case "--target":
                target = try Self.nextValue(from: &iterator, for: argument)
                guard ["wgsl", "msl", "spirv"].contains(target) else {
                    throw ToolError.invalidArgument("--target expects wgsl, msl, or spirv")
                }
            case "--web-stages":
                webStages = true
            case "--help", "-h":
                throw ToolError.help
            default:
                throw ToolError.invalidArgument("Unknown argument: \(argument)")
            }
        }

        guard let input else {
            throw ToolError.invalidArgument("Missing --input")
        }
        guard let outputDirectory else {
            throw ToolError.invalidArgument("Missing --output-directory")
        }
        guard input.pathExtension.lowercased() == "wesl" else {
            throw ToolError.invalidArgument(
                "Unsupported shader input `\(input.path)`. Port the shader to WESL and see the WESLShaders guide."
            )
        }
        if webStages, target != "wgsl" {
            throw ToolError.invalidArgument("--web-stages requires WGSL output")
        }
        self.target = target
        self.input = input
        self.outputDirectory = outputDirectory
        self.weslRoot = weslRoot
        self.weslDependencies = weslDependencies
        self.features = features.sorted()
        self.webStages = webStages
    }

    private static func nextURL<I: IteratorProtocol>(from iterator: inout I, for argument: String) throws -> URL where I.Element == String {
        URL(fileURLWithPath: try nextValue(from: &iterator, for: argument))
    }

    private static func nextValue<I: IteratorProtocol>(from iterator: inout I, for argument: String) throws -> String where I.Element == String {
        guard let value = iterator.next() else {
            throw ToolError.invalidArgument("Missing value for \(argument)")
        }
        return value
    }
}

private enum ToolError: LocalizedError, CustomStringConvertible {
    case help
    case invalidArgument(String)

    var errorDescription: String? {
        description
    }

    var description: String {
        switch self {
        case .help:
            """
            Usage: AdaShaderTranspilerTool --input shader.wesl --output-directory <dir> [--wesl-root <dir>]
                       [--wesl-dependency name=<dir>] [--feature name] [--target wgsl|msl|spirv] [--web-stages]
            """
        case .invalidArgument(let message):
            message
        }
    }
}
