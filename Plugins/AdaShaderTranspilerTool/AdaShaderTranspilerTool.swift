import Foundation
import SPIRVCompiler
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
        let source = try String(contentsOf: options.input, encoding: .utf8)
        let stages = try GLSLProcessor.splitStages(in: source)

        guard glslang_initialize() != 0 else {
            throw ToolError.glslangInitializationFailed
        }
        defer {
            glslang_finalize()
        }

        try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)

        for stageSource in stages {
            let processedSource = try GLSLProcessor.processIncludes(
                in: stageSource.source,
                fileURL: options.input,
                moduleIncludes: options.moduleIncludes
            )
            let (entryPoint, mainSource) = GLSLProcessor.dropEntryPoint(in: processedSource)
            let spirv = try compileSPIRV(source: mainSource, stage: stageSource.stage)
            let wgsl = try runTint(
                tintExecutable: options.tintExecutable,
                spirv: spirv,
                entryPoint: entryPoint
            )
            let output = options.outputDirectory
                .appending(component: options.input.deletingPathExtension().lastPathComponent, directoryHint: .notDirectory)
                .appendingPathExtension(stageSource.stage.fileExtension)
                .appendingPathExtension("wgsl")

            try wgsl.write(to: output, atomically: true, encoding: .utf8)
            print(output.path())
        }
    }

    private static func compileSPIRV(source: String, stage: ShaderStage) throws -> Data {
        var error: UnsafePointer<CChar>?
        let source = source.insertingDefaultVertexDefines()
        let options = spirv_options(preamble: nil)
        let binary = source.withCString { sourcePointer in
            compile_shader_glsl(
                sourcePointer,
                stage.shadercStage,
                options,
                &error
            )
        }

        if let error {
            throw ToolError.glslCompilationFailed(String(cString: error))
        }

        guard let bytes = binary.bytes, binary.length > 0 else {
            throw ToolError.glslCompilationFailed("GLSL compiler returned an empty SPIR-V module.")
        }

        return Data(bytes: bytes, count: Int(binary.length))
    }

    private static func runTint(tintExecutable: URL, spirv: Data, entryPoint: String) throws -> String {
        let temporaryFile = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString, directoryHint: .notDirectory)
            .appendingPathExtension("spv")
        try spirv.write(to: temporaryFile)
        defer {
            try? FileManager.default.removeItem(at: temporaryFile)
        }

        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = tintExecutable
        // GLSL materials may compute derivatives under data-dependent control flow.
        // Preserve that source behavior when translating SPIR-V; Tint emits the
        // corresponding WGSL derivative_uniformity diagnostic directive.
        process.arguments = ["--format", "wgsl", "--allow-non-uniform-derivatives", "true", temporaryFile.path()]
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = String(decoding: errorData, as: UTF8.self)

        guard process.terminationStatus == 0 else {
            throw ToolError.tintFailed(errorOutput.isEmpty ? "Tint exited with status \(process.terminationStatus)." : errorOutput)
        }

        let output = String(decoding: outputData, as: UTF8.self)
        guard !output.isEmpty else {
            throw ToolError.tintFailed("Tint produced no WGSL output.")
        }

        let renamed = output.replacingOccurrences(of: "fn main(", with: "fn \(entryPoint)(")
        return """
        // Generated from GLSL by AdaShaderTranspilerTool.
        \(renamed)
        """
    }
}

private struct Options {
    let input: URL
    let outputDirectory: URL
    let tintExecutable: URL
    let moduleIncludes: [String: URL]

    init(arguments: ArraySlice<String>) throws {
        var input: URL?
        var outputDirectory: URL?
        var tintExecutable: URL?
        var moduleIncludes: [String: URL] = [:]
        var iterator = arguments.makeIterator()

        while let argument = iterator.next() {
            switch argument {
            case "--input":
                input = try Self.nextURL(from: &iterator, for: argument)
            case "--output-directory":
                outputDirectory = try Self.nextURL(from: &iterator, for: argument)
            case "--tint":
                tintExecutable = try Self.nextURL(from: &iterator, for: argument)
            case "--module-include":
                let value = try Self.nextValue(from: &iterator, for: argument)
                let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else {
                    throw ToolError.invalidArgument("--module-include expects ModuleName=/path/to/include")
                }
                moduleIncludes[parts[0]] = URL(fileURLWithPath: parts[1])
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
        guard let tintExecutable else {
            throw ToolError.invalidArgument("Missing --tint")
        }

        self.input = input
        self.outputDirectory = outputDirectory
        self.tintExecutable = tintExecutable
        self.moduleIncludes = moduleIncludes
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

private enum GLSLProcessor {
    struct StageSource {
        let stage: ShaderStage
        let source: String
    }

    static func splitStages(in source: String) throws -> [StageSource] {
        let source = removeComments(from: source)
        let lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var stageStarts: [(ShaderStage, Int)] = []
        var latestVersionLine = 0

        for (index, line) in lines.enumerated() {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#version") {
                latestVersionLine = index
            } else if trimmed.hasPrefix("#pragma") {
                let tokens = trimmed
                    .replacingOccurrences(of: ":", with: " : ")
                    .split(whereSeparator: \.isWhitespace)
                    .map(String.init)
                if tokens.count >= 4, tokens[1] == "stage", tokens[2] == ":", let stage = ShaderStage(tokens[3]) {
                    stageStarts.append((stage, latestVersionLine))
                }
            }
        }

        guard !stageStarts.isEmpty else {
            throw ToolError.noStagesFound
        }

        return stageStarts.enumerated().map { index, stageStart in
            let end = index + 1 < stageStarts.count ? stageStarts[index + 1].1 : lines.count
            return StageSource(
                stage: stageStart.0,
                source: lines[stageStart.1..<end].joined(separator: "\n")
            )
        }
    }

    static func processIncludes(in source: String, fileURL: URL, moduleIncludes: [String: URL]) throws -> String {
        try processIncludes(
            in: source,
            fileURL: fileURL,
            moduleIncludes: moduleIncludes,
            includeStack: []
        )
    }

    private static func processIncludes(
        in source: String,
        fileURL: URL,
        moduleIncludes: [String: URL],
        includeStack: Set<URL>
    ) throws -> String {
        let includeRegex = try NSRegularExpression(pattern: #"^\s*#include\s+([<"])([^>"]+)[>"]"#, options: [.anchorsMatchLines])
        let fullRange = NSRange(source.startIndex..., in: source)
        var result = ""
        var cursor = source.startIndex

        for match in includeRegex.matches(in: source, range: fullRange) {
            guard
                let fullMatchRange = Range(match.range(at: 0), in: source),
                let delimiterRange = Range(match.range(at: 1), in: source),
                let pathRange = Range(match.range(at: 2), in: source)
            else {
                continue
            }

            result.append(contentsOf: source[cursor..<fullMatchRange.lowerBound])
            let delimiter = source[delimiterRange]
            let includePath = String(source[pathRange])
            let includeURL = try resolveInclude(
                includePath,
                delimiter: delimiter,
                fileURL: fileURL,
                moduleIncludes: moduleIncludes
            )

            if includeStack.contains(includeURL) {
                throw ToolError.includeCycle(includeURL.path())
            }

            let includeSource = try String(contentsOf: includeURL, encoding: .utf8)
            var nextStack = includeStack
            nextStack.insert(includeURL)
            result.append(try processIncludes(
                in: includeSource,
                fileURL: includeURL,
                moduleIncludes: moduleIncludes,
                includeStack: nextStack
            ))
            cursor = fullMatchRange.upperBound
        }

        result.append(contentsOf: source[cursor...])
        return result
    }

    private static func resolveInclude(
        _ includePath: String,
        delimiter: Substring,
        fileURL: URL,
        moduleIncludes: [String: URL]
    ) throws -> URL {
        if delimiter == "\"" {
            let localURL = fileURL.deletingLastPathComponent().appending(path: includePath)
            if FileManager.default.fileExists(atPath: localURL.path()) {
                return localURL
            }
        } else {
            let parts = includePath.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2, let modulePath = moduleIncludes[parts[0]] {
                let moduleURL = modulePath.appending(path: parts[1])
                if FileManager.default.fileExists(atPath: moduleURL.path()) {
                    return moduleURL
                }
            }
        }

        throw ToolError.includeNotFound(includePath)
    }

    static func dropEntryPoint(in source: String) -> (String, String) {
        let pattern = #"\[\[(\w+)\]\]\s*(?:\[[^\]]+\])*\s*\w+\s([^\(]+)"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
            let attributeRange = Range(match.range(at: 1), in: source),
            let functionRange = Range(match.range(at: 2), in: source),
            source[attributeRange] == "main"
        else {
            return ("main", source)
        }

        let entryPoint = String(source[functionRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        var output = source
        guard let outputFunctionRange = Range(match.range(at: 2), in: output) else {
            return (entryPoint, output)
        }
        output.replaceSubrange(outputFunctionRange, with: "main")

        guard
            let outputAttributeRange = output.range(of: "[[main]]", range: output.startIndex..<outputFunctionRange.lowerBound)
        else {
            return (entryPoint, output)
        }
        output.removeSubrange(outputAttributeRange)
        return (entryPoint, output)
    }

    private static func removeComments(from source: String) -> String {
        var output = ""
        var iterator = source.makeIterator()
        var previous: Character?
        var inLineComment = false
        var inBlockComment = false

        while let character = iterator.next() {
            if inLineComment {
                if character.isNewline {
                    inLineComment = false
                    output.append(character)
                }
                continue
            }

            if inBlockComment {
                if previous == "*", character == "/" {
                    inBlockComment = false
                    previous = nil
                } else {
                    if character.isNewline {
                        output.append(character)
                    }
                    previous = character
                }
                continue
            }

            if character == "/", let next = iterator.next() {
                if next == "/" {
                    inLineComment = true
                } else if next == "*" {
                    inBlockComment = true
                    previous = nil
                } else {
                    output.append(character)
                    output.append(next)
                }
                continue
            }

            output.append(character)
        }

        return output
    }
}

private extension String {
    func insertingDefaultVertexDefines() -> String {
        let defines = """
        #define VERTEX_POSITIONS 1
        #define VERTEX_NORMALS 1
        #define VERTEX_UVS 1
        #define VERTEX_COLORS 1
        """
        guard let versionRange = range(of: #"^\s*#version[^\n]*(?:\n|$)"#, options: .regularExpression) else {
            return "\(defines)\n\(self)"
        }

        var output = self
        output.insert(contentsOf: "\(defines)\n", at: versionRange.upperBound)
        return output
    }
}

private enum ShaderStage {
    case vertex
    case fragment
    case compute

    init?(_ value: String) {
        switch value {
        case "vert", "vertex":
            self = .vertex
        case "frag", "fragment":
            self = .fragment
        case "comp", "compute":
            self = .compute
        default:
            return nil
        }
    }

    var fileExtension: String {
        switch self {
        case .vertex:
            "vert"
        case .fragment:
            "frag"
        case .compute:
            "comp"
        }
    }

    var shadercStage: shaderc_stage {
        switch self {
        case .vertex:
            SHADER_STAGE_VERTEX
        case .fragment:
            SHADER_STAGE_FRAGMENT
        case .compute:
            SHADER_STAGE_COMPUTE
        }
    }
}

private enum ToolError: LocalizedError, CustomStringConvertible {
    case help
    case invalidArgument(String)
    case glslangInitializationFailed
    case noStagesFound
    case includeNotFound(String)
    case includeCycle(String)
    case glslCompilationFailed(String)
    case tintFailed(String)

    var errorDescription: String? {
        description
    }

    var description: String {
        switch self {
        case .help:
            "Usage: AdaShaderTranspilerTool --input shader.glsl --output-directory <dir> --tint <path> [--module-include AdaEngine=<dir>]"
        case .invalidArgument(let message):
            message
        case .glslangInitializationFailed:
            "Failed to initialize glslang."
        case .noStagesFound:
            "No #pragma stage declarations found."
        case .includeNotFound(let includePath):
            "Could not resolve shader include \(includePath)."
        case .includeCycle(let path):
            "Shader include cycle detected at \(path)."
        case .glslCompilationFailed(let message):
            "GLSL compilation failed: \(message)"
        case .tintFailed(let message):
            "Tint conversion failed: \(message)"
        }
    }
}
