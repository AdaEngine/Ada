//
//  ShaderUtils.swift
//  AdaEngine
//
//  Created by v.prusakov on 3/13/23.
//

// FIXME: Replace NSRegularExpression on full swift implementation.
// Currently Swift Regex doesn't supports on macOS less than 13.0 and that's a problem here.
// I want to use swift like solution instead of Foundation.

import Foundation

/// Collection of utils for works with shaders.
enum ShaderUtils {
    enum CommentState {
        case singleLineComment
        case multiLineComment
        case notAComment
        case slash
        case star
    }

    enum ProcessingError: LocalizedError {
        case noMacroSymbols
        case invalidDeclaration(String)
        case noStageFound

        var errorDescription: String? {
            switch self {
            case .noMacroSymbols:
                return "[ShaderCompiler] Macro symbol `#` not found."
            case let .invalidDeclaration(message):
                return "[ShaderCompiler] Invalid declaration: \(message)."
            case .noStageFound:
                return "[ShaderCompiler] Stages not found."
            }
        }
    }

    /// Split GLSL shader source code by available stages.
    /// - Throws: Error if missed pragmas: `#version` or `#pragma stage`. Also throw error if not stage found.
    static func processGLSLShader(source: String) throws -> [ShaderStage: String] {
        let finalSource = Self.removeComments(from: source)

        var shaderSources: [ShaderStage: String] = [:]
        var stagePositions: [(ShaderStage, String.Index)] = []

        guard var pointer = finalSource.firstIndex(of: "#") else {
            throw ProcessingError.noMacroSymbols
        }

        var startStagePosition = pointer

        while pointer < finalSource.endIndex {
            let newSource = finalSource[pointer..<finalSource.endIndex]

            guard let endOfLine = newSource.firstIndex(where: { $0.isNewline }) else {
                break
            }

            let regular = try NSRegularExpression(pattern: "((^\\W|^\\w+)|(\\w+)|[:()])", options: [])
            let rangeLocation = finalSource.utf16.distance(from: finalSource.startIndex, to: pointer)
            let rangeLength = finalSource.utf16.distance(from: pointer, to: endOfLine)
            let matches = regular.matches(
                in: finalSource,
                options: [],
                range: NSRange(location: rangeLocation, length: rangeLength)
            )

            let firstToken = finalSource.getSubstring(from: matches[1].range)

            switch firstToken {
            case "version":
                startStagePosition = finalSource.getSubstring(from: matches[0].range).startIndex
            case "pragma":
                if finalSource.getSubstring(from: matches[2].range) == "stage" {
                    if finalSource.getSubstring(from: matches[3].range) == ":" {
                        let stageString = finalSource.getSubstring(from: matches[4].range)
                        let stage = self.shaderStage(from: String(stageString)) ?? .max
                        stagePositions.append((stage, startStagePosition))
                    } else {
                        throw ProcessingError.invalidDeclaration("Invalid stage declaration. Use `pragma stage : YOUR_STAGE`")
                    }
                }
            default:
                break
            }

            guard let newPosition = newSource[endOfLine...].firstIndex(of: "#") else {
                break
            }

            pointer = newPosition
        }

        if stagePositions.isEmpty {
            throw ProcessingError.noStageFound
        }

        for index in 0..<stagePositions.count {
            let (currentStage, currentStringIndex) = stagePositions[index]

            if stagePositions.indices.contains(index + 1) {
                let (_, nextStringIndex) = stagePositions[index + 1]

                let stageSource = finalSource[currentStringIndex..<nextStringIndex]
                shaderSources[currentStage] = String(stageSource)
            } else {
                let stageSource = finalSource[currentStringIndex..<finalSource.endIndex]
                shaderSources[currentStage] = String(stageSource)
            }
        }

        return shaderSources
    }

    /// Remove comments from source code.
    /// Supports multi-line and single-line comments.
    static func removeComments(from string: String) -> String {
        var state: CommentState = .notAComment

        var newString = ""
        newString.reserveCapacity(string.count)

        for char in string {
            switch state {
            case .star:
                if char == "/" {
                    state = .notAComment
                } else {
                    state = .multiLineComment
                }
            case .notAComment:
                if char == "/" {
                    state = .slash
                } else {
                    newString += String(char)
                }
            case .singleLineComment:
                if char.isNewline {
                    state = .notAComment
                    newString += String(char)
                }
            case .multiLineComment:
                if char == "*" {
                    state = .star
                } else if char.isNewline {
                    newString += String(char)
                }
            case .slash:
                if char == "/" {
                    state = .singleLineComment
                } else if char == "*" {
                    state = .multiLineComment
                } else {
                    state = .notAComment
                    newString += "/"
                    newString += String(char)
                }
            }
        }

        return newString
    }

    /// Return shader language from file extension.
    static func shaderLang(from fileExt: String) -> ShaderLanguage {
        switch fileExt {
        case "vert",
            "frag",
            "glsl",
            "comp":
            return .glsl
        case "hlsl":
            return .hlsl
        case "wgsl":
            return .wgsl
        default:
            return .glsl
        }
    }

    /// Return shader stage from string.
    static func shaderStage(from string: String) -> ShaderStage? {
        switch string {
        case "vert",
            "vertex":
            return .vertex
        case "frag",
            "fragment":
            return .fragment
        case "comp",
            "compute":
            return .compute
        default:
            return nil
        }
    }

    /// Find entry point in double braces.
    /// Example:
    /// ```
    /// [[vertex]]
    /// void myShaderFunc() { ... }
    /// ```
    private static let entryPointRegex: String = #"\[\[(\w+)\]\]\s*(?:\[[^\]]+\])*\s*\w+\s([^\\(]+)"#

    /// Drop user entry point annotated with `[[main]]` attribute and replace it to `main`.
    ///
    /// We support custom entry points for GLSL shaders. GLSLang compiler can't supports custom entry points
    /// and we change user entry point to `main` and return user entry point for SPIRV-Cross.
    /// That's because we want support user entry point name in final, GPU specific shader source.
    ///
    /// For example, if user set custom entry point and after that shader will compile to MSL shader, we want to see user entry point in debug instead of default `main0`.
    static func dropEntryPoint(from string: String) throws -> (String, String) {
        var newString = string
        if let (attributeName, functionName) = self.getFirstFunctionAttribute(in: newString), attributeName == "main" {
            newString.replaceSubrange(functionName.startIndex..<functionName.endIndex, with: attributeName)

            // Remove it from source
            newString.removeSubrange(string.index(attributeName.startIndex, offsetBy: -2)..<string.index(attributeName.endIndex, offsetBy: 2))

            return (String(functionName), newString)
        }

        // We don't find any attributes
        return ("main", string)
    }

    /// Get first matched attribute in string.
    /// - Returns: Attribute name and function name
    static func getFirstFunctionAttribute(in string: String) -> (Substring, Substring)? {
        guard let regex = try? NSRegularExpression(pattern: Self.entryPointRegex, options: []) else {
            return nil
        }

        guard
            let firstMatch = regex.firstMatch(
                in: string,
                options: [],
                range: NSRange(location: 0, length: string.utf16.count)
            )
        else {
            // We don't find any attributes
            return nil
        }

        let attributeNameMatch = firstMatch.range(at: 1)  // attribute name
        let functionNameMatch = firstMatch.range(at: 2)  // function name
        let attribute = string.getSubstring(from: attributeNameMatch)
        let functionName = string.getSubstring(from: functionNameMatch)

        return (attribute, functionName)
    }
}

extension String {
    /// Get substring from ``NSRange``.
    ///
    /// We use it because we ``NSRegularExpression`` returns ``NSRange`` instead of `Range<String.Index>`
    @inlinable
    @inline(__always)
    func getSubstring(from nsRange: NSRange) -> Substring {
        let start = self.index(self.startIndex, offsetBy: nsRange.lowerBound)
        let end = self.index(self.startIndex, offsetBy: nsRange.upperBound)

        return self[start..<end]
    }
}
