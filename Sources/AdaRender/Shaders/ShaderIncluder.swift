//
//  ShaderIncluder.swift
//  AdaEngine
//
//  Created by v.prusakov on 3/16/23.
//

import AdaUtils
import Foundation

// TODO: Make include depth (with cycle detection)
// TODO: Optimizations, decrease loops

/// An object replace includes in GLSL with their contents.
/// Supports module include with <>-style where first element is a name of module, and supports local include with ""-style.
///
///
/// Example of includes.
/// ```
/// #include <AdaEngine/PATH_TO_INCLUDED_FILE> // Search in modules
/// #include "PATH_TO_INCLUDED_FILE" // Search in local
/// ```
enum ShaderIncluder {
    private static let localIncludePattern = "#include(?:\\s+)\"([^\"]+)\"\n"

    // FIXME: That's wierd to use `\n` in regex. `$` doesn't works
    private static let moduleIncludePattern = "#include(?:\\s+)<([^\"]+)>\n"
    private static let fileSystem = FileSystem.current

    enum IncluderError: LocalizedError {
        case includeNotFound(String)

        var errorDescription: String? {
            switch self {
            case let .includeNotFound(includeName):
                return "[ShaderIncluder] Could not find include by \(includeName)"
            }
        }
    }

    static func processIncludes(
        in source: String,
        includeSearchPath: [ShaderSource.IncludeSearchPath]
    ) throws -> String {
        var newString = source
        newString = try self.processLocalIncludes(in: newString, includeSearchPath: includeSearchPath)
        newString = try self.processModuleIncludes(in: newString, includeSearchPath: includeSearchPath)

        return newString
    }

    // MARK: - Private

    static func processModuleIncludes(
        in source: String,
        includeSearchPath: [ShaderSource.IncludeSearchPath]
    ) throws -> String {
        let localIncludeRegex = try NSRegularExpression(pattern: Self.moduleIncludePattern, options: [])

        var modifiedString = source

        var firstLocalInclude = localIncludeRegex.firstMatch(
            in: modifiedString,
            options: [],
            range: NSRange(modifiedString.startIndex..<modifiedString.endIndex, in: modifiedString)
        )

        while let localIncludeMatch = firstLocalInclude {
            let moduleInclude = modifiedString.getSubstring(from: localIncludeMatch.range(at: 0))
            let moduleIncludePath = modifiedString.getSubstring(from: localIncludeMatch.range(at: 1))

            var modulePath = moduleIncludePath.split(separator: "/")

            if modulePath.count < 2 {
                throw IncluderError.includeNotFound(String(moduleIncludePath))
            }

            let includeModuleName = modulePath.removeFirst()
            let pathToFile = modulePath.joined()

            var wasFoundContent = false

            searchPathLoop: for localSearchPath in includeSearchPath {
                switch localSearchPath {
                case ._local:
                    continue
                case let ._module(moduleName, pathToModule):

                    if moduleName != includeModuleName {
                        continue
                    }

                    let fileURL = pathToModule.appendingPathComponent(String(pathToFile))
                    guard let includeContent = self.getIncludeContents(at: fileURL, includeSearchPath: includeSearchPath) else {
                        continue searchPathLoop
                    }

                    modifiedString.removeSubrange(moduleInclude.startIndex..<moduleInclude.endIndex)
                    modifiedString.insert(contentsOf: includeContent, at: moduleInclude.startIndex)
                    wasFoundContent = true

                    break searchPathLoop
                }
            }

            // Include not found
            if !wasFoundContent {
                throw IncluderError.includeNotFound(String(moduleInclude))
            }

            firstLocalInclude = localIncludeRegex.firstMatch(
                in: modifiedString,
                options: [],
                range: NSRange(modifiedString.startIndex..<modifiedString.endIndex, in: modifiedString)
            )
        }

        return modifiedString
    }

    private static func processLocalIncludes(
        in source: String,
        includeSearchPath: [ShaderSource.IncludeSearchPath]
    ) throws -> String {
        let localIncludeRegex = try NSRegularExpression(pattern: Self.localIncludePattern, options: [])

        var modifiedString = source

        var firstLocalInclude = localIncludeRegex.firstMatch(
            in: modifiedString,
            options: [],
            range: NSRange(modifiedString.startIndex..<modifiedString.endIndex, in: modifiedString)
        )

        while let localIncludeMatch = firstLocalInclude {
            let localInclude = modifiedString.getSubstring(from: localIncludeMatch.range(at: 0))
            let localIncludePath = modifiedString.getSubstring(from: localIncludeMatch.range(at: 1))

            var wasFoundContent = false

            searchPathLoop: for localSearchPath in includeSearchPath {
                switch localSearchPath {
                case let ._local(path):
                    let fileUrl = path.appendingPathComponent(String(localIncludePath))

                    guard let includeContent = self.getIncludeContents(at: fileUrl, includeSearchPath: includeSearchPath) else {
                        continue searchPathLoop
                    }

                    modifiedString.removeSubrange(localInclude.startIndex..<localInclude.endIndex)
                    modifiedString.insert(contentsOf: includeContent, at: localInclude.startIndex)
                    wasFoundContent = true
                    break searchPathLoop
                case ._module:
                    continue
                }
            }

            // Include not found
            if !wasFoundContent {
                throw IncluderError.includeNotFound(String(localInclude))
            }

            firstLocalInclude = localIncludeRegex.firstMatch(
                in: modifiedString,
                options: [],
                range: NSRange(modifiedString.startIndex..<modifiedString.endIndex, in: modifiedString)
            )
        }

        return modifiedString
    }

    private static func getIncludeContents(at fileURL: URL, includeSearchPath: [ShaderSource.IncludeSearchPath]) -> String? {
        guard let data = self.fileSystem.readFile(at: fileURL), let content = String(bytes: data, encoding: .utf8) else {
            return nil
        }

        let source = ShaderUtils.removeComments(from: content)

        var includeSearchPath = includeSearchPath
        includeSearchPath.append(.local(fileURL.deletingLastPathComponent()))

        guard let includedSource = try? Self.processIncludes(in: source, includeSearchPath: includeSearchPath) else {
            return nil
        }

        return includedSource
    }
}
