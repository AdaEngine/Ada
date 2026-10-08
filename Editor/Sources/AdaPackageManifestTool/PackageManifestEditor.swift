import Foundation
import SwiftParser

public struct PackageManifestEditResult: Equatable, Sendable {
    public var manifest: String
    public var changed: Bool

    public init(manifest: String, changed: Bool) {
        self.manifest = manifest
        self.changed = changed
    }
}

public enum PackageManifestEditError: Error, Equatable, Sendable {
    case invalidSwiftSyntax
    case unsupportedManifestShape(reason: String, suggestedPatch: String)
    case invalidArgument(String)

    public var structuredDescription: String {
        switch self {
        case .invalidSwiftSyntax:
            #"{"error":"invalidSwiftSyntax","reason":"Package.swift could not be parsed as Swift."}"#
        case let .unsupportedManifestShape(reason, suggestedPatch):
            #"{"error":"unsupportedManifestShape","reason":"\#(Self.escape(reason))","suggestedPatch":"\#(Self.escape(suggestedPatch))"}"#
        case let .invalidArgument(message):
            #"{"error":"invalidArgument","reason":"\#(Self.escape(message))"}"#
        }
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

public enum PackageManifestCommand: Equatable, Sendable {
    case addTarget(name: String, dependencies: [String])
    case addExecutableTarget(name: String, dependencies: [String])
    case addTestTarget(name: String, dependencies: [String])
    case addDependency(url: String, requirement: String)
    case addLocalDependency(name: String?, path: String)
    case removeDependency(identity: String)
    case ensureAdaEngineDependency(path: String, targetName: String?)
    case configureTarget(name: String, sources: [String], exclude: [String], resources: [String])
    case addPlugin(name: String, capability: String)
    case ensureAssetResources(targetName: String?, assetsPath: String)
}

public enum PackageManifestEditor {
    public static func edit(_ manifest: String, command: PackageManifestCommand) throws -> PackageManifestEditResult {
        try validateManifestSyntax(manifest)

        let result: PackageManifestEditResult
        switch command {
        case let .addTarget(name, dependencies):
            result = try insertTarget(manifest, entry: targetEntry(kind: "target", name: name, dependencies: dependencies))
        case let .addExecutableTarget(name, dependencies):
            let withProduct = try insertProduct(manifest, entry: productEntry(kind: "executable", name: name))
            result = try insertTarget(withProduct.manifest, entry: targetEntry(kind: "executableTarget", name: name, dependencies: dependencies))
        case let .addTestTarget(name, dependencies):
            result = try insertTarget(manifest, entry: targetEntry(kind: "testTarget", name: name, dependencies: dependencies))
        case let .addDependency(url, requirement):
            result = try insertDependency(manifest, entry: dependencyEntry(url: url, requirement: try validatedRequirement(requirement)))
        case let .addLocalDependency(name, path):
            result = try addLocalDependency(manifest, name: name, path: path)
        case let .removeDependency(identity):
            result = try removeDependency(manifest, identity: identity)
        case let .ensureAdaEngineDependency(path, targetName):
            result = try ensureAdaEngineDependency(manifest, path: path, targetName: targetName)
        case let .configureTarget(name, sources, exclude, resources):
            result = try configureTarget(manifest, name: name, sources: sources, exclude: exclude, resources: resources)
        case let .addPlugin(name, capability):
            let withProduct = try insertProduct(manifest, entry: pluginProductEntry(name: name))
            result = try insertTarget(withProduct.manifest, entry: pluginTargetEntry(name: name, capability: capability))
        case let .ensureAssetResources(targetName, assetsPath):
            result = try ensureAssetResources(manifest, targetName: targetName, assetsPath: assetsPath)
        }

        try validateManifestSyntax(result.manifest)
        return result
    }

    public static func validateManifestSyntax(_ manifest: String) throws {
        guard !Parser.parse(source: manifest).hasError else {
            throw PackageManifestEditError.invalidSwiftSyntax
        }
    }

    private static func validatedRequirement(_ requirement: String) throws -> String {
        let trimmed = requirement.trimmingCharacters(in: .whitespacesAndNewlines)
        let labelledPattern = #"^(from|exact|branch|revision)\s*:\s*"([^"\\]+)"$"#
        guard let match = trimmed.range(of: labelledPattern, options: .regularExpression) else {
            throw PackageManifestEditError.invalidArgument(
                #"Unsupported dependency requirement. Use from: "1.0.0", exact: "1.0.0", branch: "main", or revision: "hash"."#
            )
        }

        let matched = String(trimmed[match])
        if matched.hasPrefix("from") || matched.hasPrefix("exact") {
            guard
                let version = matched.split(separator: "\"").dropFirst().first,
                String(version)
                    .range(
                        of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"#,
                        options: .regularExpression
                    ) != nil
            else {
                throw PackageManifestEditError.invalidArgument("Version requirements must contain a semantic version such as 1.0.0.")
            }
        }
        return trimmed
    }

    private static func addLocalDependency(_ manifest: String, name: String?, path: String) throws -> PackageManifestEditResult {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PackageManifestEditError.invalidArgument("Dependency path must not be empty.")
        }

        let identity = normalizedPackageIdentity(name ?? URL(fileURLWithPath: path).lastPathComponent)
        if packageDependencyCalls(in: manifest).contains(where: { normalizedPackageIdentity(dependencyIdentity(in: $0.body) ?? "") == identity }) {
            return PackageManifestEditResult(manifest: manifest, changed: false)
        }

        return try insertDependency(manifest, entry: localDependencyEntry(name: name, path: path))
    }

    private static func removeDependency(_ manifest: String, identity: String) throws -> PackageManifestEditResult {
        let normalizedIdentity = normalizedPackageIdentity(identity)
        guard !normalizedIdentity.isEmpty else {
            throw PackageManifestEditError.invalidArgument("Dependency identity must not be empty.")
        }

        var editedManifest = manifest
        var changed = false
        let dependencyCalls = packageDependencyCalls(in: editedManifest)
            .filter { normalizedPackageIdentity(dependencyIdentity(in: $0.body) ?? "") == normalizedIdentity }
            .map(\.range)
            .sorted { $0.lowerBound > $1.lowerBound }
        for range in dependencyCalls {
            removeArrayElement(containing: range, from: &editedManifest)
            changed = true
        }

        let productCalls = packageProductDependencyCalls(in: editedManifest)
            .filter { normalizedPackageIdentity(packageIdentity(inProductDependency: $0.body) ?? "") == normalizedIdentity }
            .map(\.range)
            .sorted { $0.lowerBound > $1.lowerBound }
        for range in productCalls {
            removeArrayElement(containing: range, from: &editedManifest)
            changed = true
        }

        return PackageManifestEditResult(manifest: editedManifest, changed: changed)
    }

    private static func ensureAdaEngineDependency(_ manifest: String, path: String, targetName: String?) throws -> PackageManifestEditResult {
        let withPackage = try addLocalDependency(manifest, name: "AdaEngine", path: path)
        let executableTargets = targetCalls(in: withPackage.manifest, executableOnly: true)
        let targets = targetName.map { name in executableTargets.filter { $0.name == name } } ?? executableTargets
        guard !targets.isEmpty, targetName == nil || targets.count == 1 else {
            throw PackageManifestEditError.unsupportedManifestShape(
                reason: targetName.map { "Could not uniquely identify executable target '\($0)'." }
                    ?? "Could not identify an executable target for AdaEngine.",
                suggestedPatch: #"dependencies: [.product(name: "AdaEngine", package: "AdaEngine")]"#
            )
        }
        let dependency = #".product(name: "AdaEngine", package: "AdaEngine")"#
        var editedManifest = withPackage.manifest
        var changed = withPackage.changed
        for target in targets.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            guard !target.body.contains(dependency), !target.body.contains(#""AdaEngine""#) else {
                continue
            }
            let editedBody = try targetBodyByAppendingToArrayArgument(
                dependency,
                label: "dependencies",
                in: String(target.body)
            )
            editedManifest.replaceSubrange(target.range, with: editedBody)
            changed = true
        }
        return PackageManifestEditResult(manifest: editedManifest, changed: changed)
    }

    private static func configureTarget(
        _ manifest: String,
        name: String,
        sources: [String],
        exclude: [String],
        resources: [String]
    ) throws -> PackageManifestEditResult {
        let target = try selectedTarget(in: manifest, named: name, executableOnly: false)
        let targetRoot = try targetRootPath(for: target.body)
        let configuredPaths = sources + exclude
        let containsPathOutsideTarget = try configuredPaths.contains { path in
            try !isPath(path, inside: targetRoot)
        }
        let needsPackageRoot = targetRoot != "." && containsPathOutsideTarget
        let effectiveTargetRoot = needsPackageRoot ? "." : targetRoot
        let effectiveSources = needsPackageRoot && sources.isEmpty ? [targetRoot] : sources
        let targetRelativeSources = try targetRelativePaths(effectiveSources, targetRoot: effectiveTargetRoot, label: "sources")
        let targetRelativeExclude = try targetRelativePaths(exclude, targetRoot: effectiveTargetRoot, label: "exclude")
        let targetRelativeResources = try targetRelativeResourcePaths(resources, targetRoot: effectiveTargetRoot)
        var editedBody = String(target.body)
        // Swift requires labeled arguments in declaration order. Remove these adjacent
        // build-selection arguments first, then append them as exclude/sources/resources.
        editedBody = try targetBodyBySettingArrayArgument("exclude", values: [], in: editedBody)
        editedBody = try targetBodyBySettingArrayArgument("sources", values: [], in: editedBody)
        editedBody = try targetBodyBySettingArrayArgument("resources", values: [], in: editedBody)
        if needsPackageRoot {
            editedBody = try targetBodyBySettingPath(".", in: editedBody)
        }
        editedBody = try targetBodyBySettingArrayArgument("exclude", values: targetRelativeExclude.map(quoted), in: editedBody)
        editedBody = try targetBodyBySettingArrayArgument("sources", values: targetRelativeSources.map(quoted), in: editedBody)
        editedBody = try targetBodyBySettingArrayArgument("resources", values: targetRelativeResources.map { ".copy(\"\(escaped($0))\")" }, in: editedBody)

        guard editedBody != String(target.body) else {
            return PackageManifestEditResult(manifest: manifest, changed: false)
        }

        var editedManifest = manifest
        editedManifest.replaceSubrange(target.range, with: editedBody)
        return PackageManifestEditResult(manifest: editedManifest, changed: true)
    }

    private static func ensureAssetResources(_ manifest: String, targetName: String?, assetsPath: String) throws -> PackageManifestEditResult {
        let targets = executableTargetRanges(in: manifest)
        let selectedTargets: [(range: Range<String.Index>, body: Substring, name: String?)]
        if let targetName {
            selectedTargets = targets.filter { $0.name == targetName }
        } else {
            selectedTargets = targets
        }

        guard selectedTargets.count == 1, let target = selectedTargets.first else {
            throw PackageManifestEditError.unsupportedManifestShape(
                reason: "Could not uniquely identify an executable target for Assets resources.",
                suggestedPatch: #"resources: [.copy("\#(assetsPath)")]"#
            )
        }

        let editedBody = try targetBodyByEnsuringResource(in: String(target.body), targetName: target.name, assetsPath: assetsPath)
        guard editedBody != String(target.body) else {
            return PackageManifestEditResult(manifest: manifest, changed: false)
        }

        var editedManifest = manifest
        editedManifest.replaceSubrange(target.range, with: editedBody)
        return PackageManifestEditResult(manifest: editedManifest, changed: true)
    }

    private static func executableTargetRanges(in manifest: String) -> [(range: Range<String.Index>, body: Substring, name: String?)] {
        var results: [(Range<String.Index>, Substring, String?)] = []
        var searchRange = manifest.startIndex..<manifest.endIndex

        while let start = manifest.range(of: ".executableTarget(", range: searchRange)?.lowerBound {
            guard
                let openParen = manifest[start...].firstIndex(of: "("),
                let closeParen = closingDelimiterIndex(open: "(", close: ")", start: openParen, in: manifest)
            else {
                break
            }

            let end = manifest.index(after: closeParen)
            let range = start..<end
            let body = manifest[range]
            results.append((range, body, targetName(in: body)))
            searchRange = end..<manifest.endIndex
        }

        return results
    }

    private static func targetName(in body: Substring) -> String? {
        guard let range = body.range(of: #"name:\s*"([^"]+)""#, options: .regularExpression) else {
            return nil
        }

        let match = body[range]
        guard
            let firstQuote = match.firstIndex(of: "\""),
            let lastQuote = match.lastIndex(of: "\""),
            firstQuote != lastQuote
        else {
            return nil
        }

        return String(match[match.index(after: firstQuote)..<lastQuote])
    }

    private static func targetRootPath(for body: Substring) throws -> String {
        if let explicitPath = stringArgument(named: "path", in: body) {
            return try normalizedRelativePath(explicitPath, label: "target path")
        }
        guard let name = targetName(in: body) else {
            throw PackageManifestEditError.unsupportedManifestShape(
                reason: "Could not determine the selected target's default path.",
                suggestedPatch: #"path: "Sources/Game""#
            )
        }
        return "Sources/\(name)"
    }

    private static func targetRelativePaths(_ paths: [String], targetRoot: String, label: String) throws -> [String] {
        try paths.map { path in
            let normalizedPath = try normalizedRelativePath(path, label: label)
            guard targetRoot != "." else {
                return normalizedPath
            }
            if normalizedPath == targetRoot {
                return "."
            }
            let prefix = targetRoot + "/"
            guard normalizedPath.hasPrefix(prefix) else {
                throw PackageManifestEditError.invalidArgument(
                    "Project-relative \(label) path '\(path)' is outside target root '\(targetRoot)'."
                )
            }
            return String(normalizedPath.dropFirst(prefix.count))
        }
    }

    private static func isPath(_ path: String, inside targetRoot: String) throws -> Bool {
        let normalizedPath = try normalizedRelativePath(path, label: "configured")
        return targetRoot == "." || normalizedPath == targetRoot || normalizedPath.hasPrefix(targetRoot + "/")
    }

    private static func targetRelativeResourcePaths(_ paths: [String], targetRoot: String) throws -> [String] {
        try paths.map { path in
            let normalizedPath = try normalizedRelativePath(path, label: "resources")
            guard targetRoot != "." else {
                return normalizedPath
            }
            if normalizedPath == targetRoot {
                return "."
            }
            let targetPrefix = targetRoot + "/"
            if normalizedPath.hasPrefix(targetPrefix) {
                return String(normalizedPath.dropFirst(targetPrefix.count))
            }
            let parentPrefix = String(repeating: "../", count: targetRoot.split(separator: "/").count)
            return parentPrefix + normalizedPath
        }
    }

    private static func normalizedRelativePath(_ path: String, label: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PackageManifestEditError.invalidArgument("\(label.capitalized) paths must not be empty.")
        }
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~"), !trimmed.contains("\\") else {
            throw PackageManifestEditError.invalidArgument("\(label.capitalized) paths must be project-relative POSIX paths.")
        }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.contains(".."), !components.contains(where: \.isEmpty) else {
            throw PackageManifestEditError.invalidArgument("\(label.capitalized) paths must not escape the project or contain empty segments.")
        }
        let normalizedComponents = components.filter { $0 != "." }
        return normalizedComponents.isEmpty ? "." : normalizedComponents.joined(separator: "/")
    }

    private static func targetBodyByEnsuringResource(in body: String, targetName: String?, assetsPath: String) throws -> String {
        let resourceEntry = #".copy("\#(assetsPath)")"#
        let needsPackageRootPath = !body.contains("path:")
        let needsSources = needsPackageRootPath && !body.contains("sources:")
        let sourceEntry = targetName.map { #"sources: ["Sources/\#($0)"]"# }

        if body.contains(resourceEntry), !needsPackageRootPath, !needsSources {
            return body
        }

        var editedBody = body
        if needsPackageRootPath {
            editedBody = try targetBodyByAppendingArgument(#"path: ".""#, to: editedBody)
        }
        if needsSources, let sourceEntry {
            editedBody = try targetBodyByAppendingArgument(sourceEntry, to: editedBody)
        }

        if editedBody.contains(resourceEntry) {
            return editedBody
        }

        if let resourcesLabel = editedBody.range(of: "resources:"),
            let openBracket = editedBody[resourcesLabel.upperBound...].firstIndex(of: "["),
            let closeBracket = closingDelimiterIndex(open: "[", close: "]", start: openBracket, in: editedBody) {
            let prefix = editedBody[..<closeBracket]
            let suffix = editedBody[closeBracket...]
            let needsComma = prefix.last(where: { !$0.isWhitespace }).map { $0 != "[" && $0 != "," } ?? false
            let separator = needsComma ? ", " : ""
            return String(prefix) + separator + resourceEntry + String(suffix)
        }

        return try targetBodyByAppendingArgument("resources: [\(resourceEntry)]", to: editedBody)
    }

    private static func targetBodyByAppendingArgument(_ argument: String, to body: String) throws -> String {
        guard let closeParen = body.lastIndex(of: ")") else {
            throw PackageManifestEditError.invalidSwiftSyntax
        }

        let prefix = body[..<closeParen]
        let suffix = body[closeParen...]
        let hasNewline = body.contains("\n")
        if hasNewline {
            let indentation = indentationBeforeClosingBracket(at: closeParen, in: body) + "    "
            let separator = prefix.last(where: { !$0.isWhitespace }).map { $0 == "," ? "" : "," } ?? ""
            return String(prefix) + "\(separator)\n\(indentation)\(argument)\n" + String(suffix)
        }

        let separator = prefix.last(where: { !$0.isWhitespace }).map { $0 == "(" ? "" : ", " } ?? ""
        return String(prefix) + "\(separator)\(argument)" + String(suffix)
    }

    private static func selectedTarget(
        in manifest: String,
        named targetName: String?,
        executableOnly: Bool
    ) throws -> (range: Range<String.Index>, body: Substring, name: String?) {
        let candidates = targetCalls(in: manifest, executableOnly: executableOnly)
        let selected = targetName.map { name in candidates.filter { $0.name == name } } ?? candidates
        guard selected.count == 1, let target = selected.first else {
            throw PackageManifestEditError.unsupportedManifestShape(
                reason: targetName.map { "Could not uniquely identify target '\($0)'." }
                    ?? "Could not uniquely identify a target.",
                suggestedPatch: targetName.map { #".executableTarget(name: "\#($0)", dependencies: [])"# }
                    ?? ".executableTarget(name: \"Game\", dependencies: [])"
            )
        }
        return target
    }

    private static func targetCalls(
        in manifest: String,
        executableOnly: Bool
    ) -> [(range: Range<String.Index>, body: Substring, name: String?)] {
        let markers = executableOnly ? [".executableTarget("] : [".executableTarget(", ".target("]
        return markers.flatMap { callRanges(marker: $0, in: manifest) }
            .map { ($0, manifest[$0], targetName(in: manifest[$0])) }
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static func packageDependencyCalls(
        in manifest: String
    ) -> [(range: Range<String.Index>, body: Substring)] {
        guard let arrayRange = arrayContentsRange(named: "dependencies", in: manifest) else {
            return []
        }

        return callRanges(marker: ".package(", in: manifest, searchRange: arrayRange)
            .map { ($0, manifest[$0]) }
    }

    private static func packageProductDependencyCalls(
        in manifest: String
    ) -> [(range: Range<String.Index>, body: Substring)] {
        callRanges(marker: ".product(", in: manifest).map { ($0, manifest[$0]) }
    }

    private static func callRanges(
        marker: String,
        in text: String,
        searchRange: Range<String.Index>? = nil
    ) -> [Range<String.Index>] {
        var results: [Range<String.Index>] = []
        var remainingRange = searchRange ?? text.startIndex..<text.endIndex
        while let markerRange = text.range(of: marker, range: remainingRange) {
            let openParen = text.index(before: markerRange.upperBound)
            guard let closeParen = closingDelimiterIndex(open: "(", close: ")", start: openParen, in: text) else {
                break
            }
            let end = text.index(after: closeParen)
            results.append(markerRange.lowerBound..<end)
            guard end < remainingRange.upperBound else {
                break
            }
            remainingRange = end..<remainingRange.upperBound
        }
        return results
    }

    private static func arrayContentsRange(named name: String, in manifest: String) -> Range<String.Index>? {
        guard
            let labelRange = manifest.range(of: "\\b\(NSRegularExpression.escapedPattern(for: name))\\s*:", options: .regularExpression),
            let openBracket = manifest[labelRange.upperBound...].firstIndex(of: "["),
            let closeBracket = closingDelimiterIndex(open: "[", close: "]", start: openBracket, in: manifest)
        else {
            return nil
        }
        return manifest.index(after: openBracket)..<closeBracket
    }

    private static func dependencyIdentity(in body: Substring) -> String? {
        if let name = stringArgument(named: "name", in: body) {
            return name
        }
        if let url = stringArgument(named: "url", in: body) {
            let withoutTrailingSlash = url.hasSuffix("/") ? String(url.dropLast()) : url
            return URL(string: withoutTrailingSlash)?.deletingPathExtension().lastPathComponent
        }
        if let path = stringArgument(named: "path", in: body) {
            return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
        return nil
    }

    private static func packageIdentity(inProductDependency body: Substring) -> String? {
        stringArgument(named: "package", in: body)
    }

    private static func stringArgument(named name: String, in body: Substring) -> String? {
        let pattern = #"\b\#(NSRegularExpression.escapedPattern(for: name))\s*:\s*"([^"]+)""#
        guard let match = body.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        let matched = body[match]
        guard
            let firstQuote = matched.firstIndex(of: "\""),
            let lastQuote = matched.lastIndex(of: "\""),
            firstQuote != lastQuote
        else {
            return nil
        }
        return String(matched[matched.index(after: firstQuote)..<lastQuote])
    }

    private static func normalizedPackageIdentity(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\.git$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "_", with: "-")
    }

    private static func removeArrayElement(containing range: Range<String.Index>, from text: inout String) {
        var lowerBound = range.lowerBound
        var upperBound = range.upperBound

        while upperBound < text.endIndex, text[upperBound].isWhitespace {
            upperBound = text.index(after: upperBound)
        }
        if upperBound < text.endIndex, text[upperBound] == "," {
            upperBound = text.index(after: upperBound)
            if upperBound < text.endIndex, text[upperBound] == " " {
                upperBound = text.index(after: upperBound)
            }
        } else {
            while lowerBound > text.startIndex {
                let previous = text.index(before: lowerBound)
                if text[previous].isWhitespace {
                    lowerBound = previous
                } else if text[previous] == "," {
                    lowerBound = previous
                    break
                } else {
                    break
                }
            }
        }
        text.removeSubrange(lowerBound..<upperBound)
    }

    private static func targetBodyByAppendingToArrayArgument(_ entry: String, label: String, in body: String) throws -> String {
        if let contentsRange = arrayArgumentContentsRange(label: label, in: body) {
            let prefix = body[..<contentsRange.upperBound]
            let insertionIndex = contentsRange.upperBound
            let existing = body[contentsRange].trimmingCharacters(in: .whitespacesAndNewlines)
            let separator = existing.isEmpty ? "" : ", "
            return String(prefix) + separator + entry + String(body[insertionIndex...])
        }
        return try targetBodyByAppendingArgument("\(label): [\(entry)]", to: body)
    }

    private static func targetBodyBySettingArrayArgument(_ label: String, values: [String], in body: String) throws -> String {
        if let argumentRange = arrayArgumentRange(label: label, in: body) {
            if values.isEmpty {
                var editedBody = body
                removeArrayElement(containing: argumentRange, from: &editedBody)
                return editedBody
            }
            var editedBody = body
            editedBody.replaceSubrange(argumentRange, with: "\(label): [\(values.joined(separator: ", "))]")
            return editedBody
        }

        guard !values.isEmpty else {
            return body
        }
        return try targetBodyByAppendingOrderedArgument("\(label): [\(values.joined(separator: ", "))]", label: label, to: body)
    }

    private static func targetBodyBySettingPath(_ path: String, in body: String) throws -> String {
        let pattern = #"\bpath\s*:\s*"[^"]*""#
        if let range = body.range(of: pattern, options: .regularExpression) {
            var editedBody = body
            editedBody.replaceSubrange(range, with: #"path: "\#(escaped(path))""#)
            return editedBody
        }
        return try targetBodyByAppendingOrderedArgument(#"path: "\#(escaped(path))""#, label: "path", to: body)
    }

    private static func targetBodyByAppendingOrderedArgument(_ argument: String, label: String, to body: String) throws -> String {
        let trailingLabels = ["publicHeadersPath", "packageAccess", "cSettings", "cxxSettings", "swiftSettings", "linkerSettings", "plugins"]
        let laterLabels: [String] =
            switch label {
            case "path": ["exclude", "sources", "resources"] + trailingLabels
            case "exclude": ["sources", "resources"] + trailingLabels
            case "sources": ["resources"] + trailingLabels
            default: trailingLabels
            }
        let laterRanges = laterLabels.compactMap { label in
            body.range(of: #"\b\#(NSRegularExpression.escapedPattern(for: label))\s*:"#, options: .regularExpression)
        }
        guard let insertionRange = laterRanges.min(by: { $0.lowerBound < $1.lowerBound }) else {
            return try targetBodyByAppendingArgument(argument, to: body)
        }

        let insertionIndex = insertionRange.lowerBound
        let lineStart = body[..<insertionIndex].lastIndex(of: "\n").map { body.index(after: $0) } ?? body.startIndex
        let indentation = String(body[lineStart..<insertionIndex].prefix { $0 == " " || $0 == "\t" })
        let isMultiline = lineStart != body.startIndex
        let separator = isMultiline ? "\(argument),\n\(indentation)" : "\(argument), "
        return String(body[..<insertionIndex]) + separator + String(body[insertionIndex...])
    }

    private static func arrayArgumentRange(label: String, in body: String) -> Range<String.Index>? {
        let pattern = #"\b\#(NSRegularExpression.escapedPattern(for: label))\s*:"#
        guard
            let labelRange = body.range(of: pattern, options: .regularExpression),
            let openBracket = body[labelRange.upperBound...].firstIndex(of: "["),
            let closeBracket = closingDelimiterIndex(open: "[", close: "]", start: openBracket, in: body)
        else {
            return nil
        }
        return labelRange.lowerBound..<body.index(after: closeBracket)
    }

    private static func arrayArgumentContentsRange(label: String, in body: String) -> Range<String.Index>? {
        guard
            let argumentRange = arrayArgumentRange(label: label, in: body),
            let openBracket = body[argumentRange].firstIndex(of: "[")
        else {
            return nil
        }
        let closeBracket = body.index(before: argumentRange.upperBound)
        return body.index(after: openBracket)..<closeBracket
    }

    private static func insertProduct(_ manifest: String, entry: String) throws -> PackageManifestEditResult {
        try insert(entry: entry, intoArrayNamed: "products", manifest: manifest)
    }

    private static func insertDependency(_ manifest: String, entry: String) throws -> PackageManifestEditResult {
        try insert(entry: entry, intoArrayNamed: "dependencies", manifest: manifest)
    }

    private static func insertTarget(_ manifest: String, entry: String) throws -> PackageManifestEditResult {
        try insert(entry: entry, intoArrayNamed: "targets", manifest: manifest)
    }

    private static func insert(entry: String, intoArrayNamed arrayName: String, manifest: String) throws -> PackageManifestEditResult {
        guard !manifest.contains(entry) else {
            return PackageManifestEditResult(manifest: manifest, changed: false)
        }

        guard let insertionIndex = closingBracketIndex(forArrayNamed: arrayName, in: manifest) else {
            throw PackageManifestEditError.unsupportedManifestShape(
                reason: "Could not find a static \(arrayName): [...] array in Package.swift.",
                suggestedPatch: entry
            )
        }

        let prefix = manifest[..<insertionIndex]
        let suffix = manifest[insertionIndex...]
        let needsComma = prefix.last(where: { !$0.isWhitespace }).map { $0 != "[" && $0 != "," } ?? false
        let separator = needsComma ? "," : ""
        let indentation = indentationBeforeClosingBracket(at: insertionIndex, in: manifest) + "    "
        let inserted = "\(separator)\n\(indentation)\(entry)\n"

        return PackageManifestEditResult(
            manifest: String(prefix) + inserted + String(suffix),
            changed: true
        )
    }

    private static func closingBracketIndex(forArrayNamed name: String, in manifest: String) -> String.Index? {
        guard
            let labelRange = manifest.range(of: "\n    \(name):"),
            let openBracket = manifest[labelRange.upperBound...].firstIndex(of: "[")
        else {
            return nil
        }

        var depth = 0
        var index = openBracket
        while index < manifest.endIndex {
            let character = manifest[index]
            if character == "[" {
                depth += 1
            } else if character == "]" {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
            index = manifest.index(after: index)
        }

        return nil
    }

    private static func closingDelimiterIndex(open: Character, close: Character, start: String.Index, in text: String) -> String.Index? {
        var depth = 0
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if character == open {
                depth += 1
            } else if character == close {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
            index = text.index(after: index)
        }

        return nil
    }

    private static func indentationBeforeClosingBracket(at index: String.Index, in manifest: String) -> String {
        let lineStart = manifest[..<index].lastIndex(of: "\n").map { manifest.index(after: $0) } ?? manifest.startIndex
        return String(manifest[lineStart..<index].prefix { $0 == " " || $0 == "\t" })
    }

    private static func productEntry(kind: String, name: String) -> String {
        ".\(kind)(name: \"\(name)\", targets: [\"\(name)\"])"
    }

    private static func pluginProductEntry(name: String) -> String {
        ".plugin(name: \"\(name)\", targets: [\"\(name)\"])"
    }

    private static func dependencyEntry(url: String, requirement: String) -> String {
        ".package(url: \"\(escaped(url))\", \(requirement))"
    }

    private static func localDependencyEntry(name: String?, path: String) -> String {
        let nameArgument = name.map { "name: \"\(escaped($0))\", " } ?? ""
        return ".package(\(nameArgument)path: \"\(escaped(path))\")"
    }

    private static func targetEntry(kind: String, name: String, dependencies: [String]) -> String {
        let dependencyList = dependencies.map { "\"\($0)\"" }.joined(separator: ", ")
        return ".\(kind)(name: \"\(name)\", dependencies: [\(dependencyList)])"
    }

    private static func pluginTargetEntry(name: String, capability: String) -> String {
        ".plugin(name: \"\(name)\", capability: \(capability), dependencies: [])"
    }

    private static func quoted(_ value: String) -> String {
        "\"\(escaped(value))\""
    }

    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
