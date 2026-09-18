@_spi(AdaEngine) import AdaEngine
import Foundation
import SwiftParser
import SwiftSyntax

#if canImport(Darwin)
    import Darwin.C
#elseif canImport(Glibc)
    import Glibc
#endif

struct EditorPreviewDeclaration: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        case adaScript
        case swift
    }

    var id: String
    var title: String
    var typeName: String
    var line: Int
    var kind: Kind = .swift

    var symbolName: String {
        "ada_editor_preview_make_\(typeName.map { character in character.isLetter || character.isNumber || character == "_" ? character : "_" }.map(String.init).joined())"
    }
}

struct EditorPreviewBuildRequest: Equatable, Sendable {
    var projectURL: URL
    var document: EditorTextDocument
    var packageModel: SwiftPackageModel
    var declaration: EditorPreviewDeclaration
    var uiExportProvider: String?
}

struct EditorPreviewBuildFailure: Error, Equatable, Sendable, CustomStringConvertible {
    var message: String

    var description: String {
        message
    }
}

struct EditorPreviewBuildArtifact: Equatable, Sendable {
    var libraryURL: URL
    var symbolName: String
    var buildOutput: String
}

enum EditorPreviewScanner {
    static func declarations(in source: String, language: EditorSourceLanguage) -> [EditorPreviewDeclaration] {
        switch language {
        case .ada:
            adaScriptDeclarations(in: source)
        case .packageManifest,
            .swift:
            declarations(in: source)
        default:
            []
        }
    }

    static func declarations(in source: String) -> [EditorPreviewDeclaration] {
        let sourceFile = Parser.parse(source: source)
        let locationConverter = SourceLocationConverter(fileName: "", tree: sourceFile)

        return sourceFile.statements.compactMap { item -> EditorPreviewDeclaration? in
            let declaration = item.item.as(DeclSyntax.self)
            guard
                let previewType = PreviewTypeDeclaration(declaration),
                previewType.hasPreviewableAttribute,
                previewType.conformsToView
            else {
                return nil
            }

            let location = locationConverter.location(for: previewType.position)
            return EditorPreviewDeclaration(
                id: previewType.typeName,
                title: previewType.title ?? previewType.typeName,
                typeName: previewType.typeName,
                line: location.line
            )
        }
    }

    private static func adaScriptDeclarations(in source: String) -> [EditorPreviewDeclaration] {
        let metadata = try? AdaScriptViewScanner.declarations(in: [
            AdaScriptSource(path: "Preview.ada", source: source)
        ])
        return metadata?.filter(\.isPreviewable)
            .map {
                EditorPreviewDeclaration(
                    id: $0.identifier,
                    title: $0.title,
                    typeName: $0.className,
                    line: $0.line,
                    kind: .adaScript
                )
            } ?? []
    }
}

private struct PreviewTypeDeclaration {
    let typeName: String
    let attributes: AttributeListSyntax
    let inheritanceClause: InheritanceClauseSyntax?
    let position: AbsolutePosition

    init?(_ declaration: DeclSyntax?) {
        guard let declaration else {
            return nil
        }

        if let structDecl = declaration.as(StructDeclSyntax.self) {
            typeName = structDecl.name.text
            attributes = structDecl.attributes
            inheritanceClause = structDecl.inheritanceClause
            position = structDecl.positionAfterSkippingLeadingTrivia
        } else if let classDecl = declaration.as(ClassDeclSyntax.self) {
            typeName = classDecl.name.text
            attributes = classDecl.attributes
            inheritanceClause = classDecl.inheritanceClause
            position = classDecl.positionAfterSkippingLeadingTrivia
        } else if let enumDecl = declaration.as(EnumDeclSyntax.self) {
            typeName = enumDecl.name.text
            attributes = enumDecl.attributes
            inheritanceClause = enumDecl.inheritanceClause
            position = enumDecl.positionAfterSkippingLeadingTrivia
        } else {
            return nil
        }
    }

    var hasPreviewableAttribute: Bool {
        previewableAttribute != nil
    }

    var title: String? {
        guard
            let attribute = previewableAttribute,
            let arguments = attribute.arguments?.as(LabeledExprListSyntax.self)
        else {
            return nil
        }

        guard
            let expression = (arguments.first { $0.label?.text == "title" } ?? arguments.first)?.expression,
            let segments = expression.as(StringLiteralExprSyntax.self)?.segments,
            segments.count == 1,
            let segment = segments.first?.as(StringSegmentSyntax.self)
        else {
            return nil
        }

        return segment.content.text
    }

    var conformsToView: Bool {
        inheritanceClause?.inheritedTypes
            .contains { inheritedType in
                ["View", "AdaUI.View", "AdaEngine.View"].contains(inheritedType.type.trimmedDescription)
            } == true
    }

    private var previewableAttribute: AttributeSyntax? {
        attributes.compactMap { element -> AttributeSyntax? in
            guard let attribute = element.as(AttributeSyntax.self) else {
                return nil
            }

            let name = attribute.attributeName.trimmedDescription
            return name == "Previewable" || name == "AdaUI.Previewable" || name == "AdaEngine.Previewable" ? attribute : nil
        }
        .first
    }
}

actor EditorPreviewBuilder {
    private struct MirroredPreviewTarget: Equatable, Sendable {
        var name: String
        var path: String
        var targetDependencies: [String]
        var productDependencies: [String]
    }

    private let processRunner: any EditorProcessRunning
    private let fileManager: FileManager

    init(processRunner: any EditorProcessRunning = EditorProcessRunner(), fileManager: FileManager = .default) {
        self.processRunner = processRunner
        self.fileManager = fileManager
    }

    func build(_ request: EditorPreviewBuildRequest, toolchain: SwiftToolchain? = nil) async throws -> EditorPreviewBuildArtifact {
        try EditorDistribution.current.validate(buildSystem: .swiftpm)
        guard let target = request.packageModel.target(containing: request.document, projectURL: request.projectURL) else {
            throw EditorPreviewBuildFailure(message: "Could not resolve the SwiftPM target for \(request.document.relativePath).")
        }

        let resolvedToolchain: SwiftToolchain
        if let toolchain {
            resolvedToolchain = toolchain
        } else {
            resolvedToolchain = await SwiftToolchainLocator.locate()
        }
        let previewDirectory = request.projectURL
            .appendingPathComponent(".build/adaeditor-previews", isDirectory: true)
            .appendingPathComponent(stablePreviewDirectoryName(for: request), isDirectory: true)
        let scratchDirectory =
            previewDirectory
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("build-\(UUID().uuidString)", isDirectory: true)

        try writePreviewPackage(
            at: previewDirectory,
            request: request,
            target: target
        )

        let buildTarget = request.uiExportProvider == nil ? ["--product", Self.productName] : ["--target", target.name]
        let command = EditorProcessCommand(
            executablePath: resolvedToolchain.swiftExecutablePath,
            arguments: ["build"] + buildTarget + ["--scratch-path", scratchDirectory.path, "--jobs", "4"],
            workingDirectory: previewDirectory
        )
        let result = await processRunner.run(command)
        guard result.succeeded else {
            throw EditorPreviewBuildFailure(message: result.combinedOutput.isEmpty ? "Preview build failed." : result.combinedOutput)
        }

        if request.uiExportProvider != nil {
            let libraryURL = try await linkUIExportModule(request: request, target: target, scratchDirectory: scratchDirectory, toolchain: resolvedToolchain)
            return EditorPreviewBuildArtifact(libraryURL: libraryURL, symbolName: request.declaration.symbolName, buildOutput: result.combinedOutput)
        }

        guard let libraryURL = newestDynamicLibrary(in: scratchDirectory) else {
            throw EditorPreviewBuildFailure(message: "Preview build succeeded, but no dynamic library artifact was found.")
        }

        return EditorPreviewBuildArtifact(
            libraryURL: libraryURL,
            symbolName: request.declaration.symbolName,
            buildOutput: result.combinedOutput
        )
    }

    /// Native UI factories must use the engine already loaded by the host. Linking
    /// the complete SwiftPM product embeds a second RenderEngine and its global state.
    private func linkUIExportModule(request: EditorPreviewBuildRequest, target: SwiftPackageTarget, scratchDirectory: URL, toolchain: SwiftToolchain) async throws -> URL {
        var targetNames = Set<String>()
        func collect(_ target: SwiftPackageTarget) {
            guard targetNames.insert(target.name).inserted else {
                return
            }
            for name in target.targetDependencies {
                if let dependency = request.packageModel.target(named: name) {
                    collect(dependency)
                }
            }
        }
        collect(target)
        let objects = compiledUIObjects(in: scratchDirectory, targetNames: targetNames)
        guard !objects.isEmpty else {
            throw EditorPreviewBuildFailure(message: "No compiled object files for UI provider '\(target.name)'.")
        }
        let output = scratchDirectory.appendingPathComponent("libAdaEditorUIExports.dylib")
        let compiler = URL(fileURLWithPath: toolchain.swiftExecutablePath).deletingLastPathComponent().appendingPathComponent("swiftc")
        let result = await processRunner.run(
            EditorProcessCommand(
                executablePath: compiler.path,
                arguments: ["-emit-library", "-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup", "-o", output.path] + objects.sorted(),
                workingDirectory: scratchDirectory
            )
        )
        guard result.succeeded else {
            throw EditorPreviewBuildFailure(message: result.combinedOutput)
        }
        return output
    }

    private func compiledUIObjects(in directory: URL, targetNames: Set<String>) -> [String] {
        var objects: [String] = []
        if let files = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in files where url.pathExtension == "o" {
                let folder = url.deletingLastPathComponent().lastPathComponent
                if folder.hasSuffix(".build"), targetNames.contains(String(folder.dropLast(".build".count))) {
                    objects.append(url.path)
                }
            }
        }
        return objects
    }

    private static let productName = "AdaEditorPreviewBundle"

    private func writePreviewPackage(
        at directory: URL,
        request: EditorPreviewBuildRequest,
        target: SwiftPackageTarget
    ) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try removeGeneratedPreviewPackageContent(at: directory)

        let mirroredTargets = try mirrorTargets(
            rootTarget: target,
            request: request,
            into: directory
        )

        try packageManifest(
            request: request,
            rootTarget: target,
            mirroredTargets: mirroredTargets
        )
        .write(to: directory.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    }

    private func removeGeneratedPreviewPackageContent(at directory: URL) throws {
        for name in ["Package.swift", "Package.resolved", "Sources"] {
            try removeItemIfExists(at: directory.appendingPathComponent(name))
        }
    }

    private func removeItemIfExists(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }

        try fileManager.removeItem(at: url)
    }

    private func packageManifest(
        request: EditorPreviewBuildRequest,
        rootTarget: SwiftPackageTarget,
        mirroredTargets: [MirroredPreviewTarget]
    ) -> String {
        let dependencies = dependencyEntries(for: request.packageModel, projectURL: request.projectURL)
        let targetEntries =
            mirroredTargets
            .sorted { $0.name < $1.name }
            .map { targetEntry($0, packageModel: request.packageModel) }
            .joined(separator: ",\n")

        return """
            // swift-tools-version: 6.2
            import PackageDescription

            let package = Package(
                name: "AdaEditorPreviewHost",
                platforms: [
                    .macOS(.v15),
                    .iOS(.v18),
                ],
                products: [
                    .library(name: "\(Self.productName)", type: .dynamic, targets: ["\(rootTarget.name)"])
                ],
                dependencies: [
                    \(dependencies)
                ],
                targets: [
                    \(targetEntries)
                ]
            )
            """
    }

    private func targetEntry(_ target: MirroredPreviewTarget, packageModel: SwiftPackageModel) -> String {
        let targetDependencies = target.targetDependencies
            .sorted()
            .map { "\"\($0)\"" }
        let productDependencies = target.productDependencies
            .sorted()
            .map { productDependencyEntry(productName: $0, packageModel: packageModel) }
        let dependencies = (targetDependencies + productDependencies).joined(separator: ", ")

        return """
                    .target(
                        name: "\(target.name)",
                        dependencies: [\(dependencies)],
                        path: "\(target.path)",
                        swiftSettings: [
                            .enableUpcomingFeature("MemberImportVisibility"),
                            .strictMemorySafety()
                        ]
                    )
            """
    }

    private func mirrorTargets(
        rootTarget: SwiftPackageTarget,
        request: EditorPreviewBuildRequest,
        into previewDirectory: URL
    ) throws -> [MirroredPreviewTarget] {
        var visitedTargets: Set<String> = []
        var mirroredTargets: [MirroredPreviewTarget] = []

        try mirrorTarget(
            rootTarget,
            request: request,
            previewDirectory: previewDirectory,
            visitedTargets: &visitedTargets,
            mirroredTargets: &mirroredTargets
        )

        return mirroredTargets
    }

    private func mirrorTarget(
        _ target: SwiftPackageTarget,
        request: EditorPreviewBuildRequest,
        previewDirectory: URL,
        visitedTargets: inout Set<String>,
        mirroredTargets: inout [MirroredPreviewTarget]
    ) throws {
        guard !visitedTargets.contains(target.name) else {
            return
        }

        guard target.type == "regular" || target.type == "library" || target.type == "executable" else {
            throw EditorPreviewBuildFailure(message: "Preview target \(target.name) depends on unsupported SwiftPM target type \(target.type).")
        }

        visitedTargets.insert(target.name)
        let localDependencies = target.targetDependencies.compactMap { request.packageModel.target(named: $0) }
        for dependency in localDependencies {
            try mirrorTarget(
                dependency,
                request: request,
                previewDirectory: previewDirectory,
                visitedTargets: &visitedTargets,
                mirroredTargets: &mirroredTargets
            )
        }

        try copySources(
            for: target,
            request: request,
            into: previewDirectory
        )

        mirroredTargets.append(
            MirroredPreviewTarget(
                name: target.name,
                path: "Sources/\(target.name)",
                targetDependencies: localDependencies.map(\.name),
                productDependencies: target.productDependencies
            )
        )
    }

    private func copySources(
        for target: SwiftPackageTarget,
        request: EditorPreviewBuildRequest,
        into previewDirectory: URL
    ) throws {
        let sourceRoot = targetSourceRoot(for: target, projectURL: request.projectURL)
        let destinationRoot =
            previewDirectory
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent(target.name, isDirectory: true)
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        let sourceURLs = try swiftSourceURLs(for: target, sourceRoot: sourceRoot, projectURL: request.projectURL)
        var copiedSourceCount = 0

        for sourceURL in sourceURLs {
            let containsEntrypoint = target.type == "executable" && isExecutableEntrypoint(sourceURL)
            let containsPreview = sourceContainsPreviewableDeclaration(sourceURL)

            if containsEntrypoint && !containsPreview {
                continue
            }

            let relativePath = containsEntrypoint ? previewSafeRelativePath(forEntrypoint: sourceURL, sourceRoot: sourceRoot) : relativePath(from: sourceRoot, to: sourceURL)
            let destinationURL = destinationRoot.appendingPathComponent(relativePath, isDirectory: false)
            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            if containsEntrypoint {
                try sourceWithoutMainAttribute(sourceURL).write(to: destinationURL, atomically: true, encoding: .utf8)
            } else {
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
            }
            copiedSourceCount += 1
        }

        if let provider = request.uiExportProvider,
            target.name == request.packageModel.target(containing: request.document, projectURL: request.projectURL)?.name {
            let bridge = """
                import AdaUI
                @_cdecl("\(request.declaration.symbolName)")
                @MainActor public func __ada_ui_exports() -> UnsafeMutableRawPointer {
                    Unmanaged.passRetained(UIExportLibrary(\(provider).self)).toOpaque()
                }
                """
            try bridge.write(to: destinationRoot.appendingPathComponent("AdaUIExports.generated.swift"), atomically: true, encoding: .utf8)
        }

        guard copiedSourceCount > 0 else {
            throw EditorPreviewBuildFailure(message: "Preview target \(target.name) has no Swift sources after excluding executable entrypoints.")
        }
    }

    private func swiftSourceURLs(
        for target: SwiftPackageTarget,
        sourceRoot: URL,
        projectURL: URL
    ) throws -> [URL] {
        if fileManager.fileExists(atPath: sourceRoot.path),
            let enumerator = fileManager.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
            var urls: [URL] = []
            for case let url as URL in enumerator where url.pathExtension == "swift" && isRegularFile(url) {
                urls.append(url.standardizedFileURL)
            }
            return urls.sorted { $0.path < $1.path }
        }

        return target.sources
            .filter { $0.hasSuffix(".swift") }
            .map { URL(fileURLWithPath: $0, relativeTo: projectURL).standardizedFileURL }
            .filter { fileManager.fileExists(atPath: $0.path) }
    }

    private func sourceContainsMainAttribute(_ sourceURL: URL) -> Bool {
        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            return false
        }

        return source.contains("@main")
    }

    private func isExecutableEntrypoint(_ sourceURL: URL) -> Bool {
        sourceURL.lastPathComponent == "main.swift" || sourceContainsMainAttribute(sourceURL)
    }

    private func sourceContainsPreviewableDeclaration(_ sourceURL: URL) -> Bool {
        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            return false
        }

        return !EditorPreviewScanner.declarations(in: source).isEmpty
    }

    private func sourceWithoutMainAttribute(_ sourceURL: URL) throws -> String {
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        return
            lines
            .filter { $0.trimmingCharacters(in: .whitespacesAndNewlines) != "@main" }
            .joined(separator: "\n")
    }

    private func targetSourceRoot(for target: SwiftPackageTarget, projectURL: URL) -> URL {
        let path = target.path ?? "Sources/\(target.name)"
        return URL(fileURLWithPath: path, relativeTo: projectURL).standardizedFileURL
    }

    private func dependencyEntries(for model: SwiftPackageModel, projectURL: URL) -> String {
        model.dependencies
            .compactMap { packageDependencyEntry($0, projectURL: projectURL) }
            .joined(separator: ",\n")
    }

    private func packageDependencyEntry(_ dependency: SwiftPackageDependency, projectURL: URL) -> String? {
        if let path = dependency.path {
            let absolutePath = URL(fileURLWithPath: path, relativeTo: projectURL).standardizedFileURL.path
            if dependency.identity == "adaengine" && !fileManager.fileExists(atPath: absolutePath) {
                return #".package(name: "AdaEngine", path: "\#(escaped(Self.adaEnginePackageURL().path))")"#
            }

            return #".package(name: "\#(packageName(for: dependency))", path: "\#(escaped(absolutePath))")"#
        }

        guard let url = dependency.url else {
            return nil
        }

        return #".package(name: "\#(packageName(for: dependency))", url: "\#(escaped(url))", \#(normalizedRequirement(dependency.requirement)))"#
    }

    private func productDependencyEntry(productName: String, packageModel: SwiftPackageModel) -> String {
        let packageName = packageName(forProductNamed: productName, packageModel: packageModel)
        return #".product(name: "\#(escaped(productName))", package: "\#(escaped(packageName))")"#
    }

    private func packageName(forProductNamed productName: String, packageModel: SwiftPackageModel) -> String {
        let normalizedProduct = normalizedPackageIdentity(productName)
        if let exactMatch = packageModel.dependencies.first(where: { normalizedPackageIdentity($0.identity) == normalizedProduct }) {
            return packageName(for: exactMatch)
        }

        if let containingMatch = packageModel.dependencies.first(where: { normalizedPackageIdentity($0.identity).contains(normalizedProduct) }) {
            return packageName(for: containingMatch)
        }

        return productName
    }

    private func packageName(for dependency: SwiftPackageDependency) -> String {
        if dependency.identity == "adaengine" {
            return "AdaEngine"
        }

        return dependency.identity
    }

    private func normalizedPackageIdentity(_ value: String) -> String {
        value
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private func stablePreviewDirectoryName(for request: EditorPreviewBuildRequest) -> String {
        let value = "\(request.document.relativePath)-\(request.declaration.id)"
        let scalarSum = value.unicodeScalars.reduce(UInt64(5381)) { partial, scalar in
            ((partial << 5) &+ partial) &+ UInt64(scalar.value)
        }
        return "\(request.declaration.id)-\(String(scalarSum, radix: 16))"
    }

    private func newestDynamicLibrary(in directory: URL) -> URL? {
        guard
            let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return nil
        }

        var candidates: [URL] = []
        for case let url as URL in enumerator {
            guard
                !url.pathComponents.contains(where: { $0.hasSuffix(".dSYM") }),
                ["dylib", "so", "dll"].contains(url.pathExtension.lowercased()),
                url.deletingPathExtension().lastPathComponent.contains(Self.productName),
                (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else {
                continue
            }
            candidates.append(url)
        }

        return candidates.max { lhs, rhs in
            let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return leftDate < rightDate
        }
    }

    private func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private func relativePath(from root: URL, to url: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let urlPath = url.standardizedFileURL.path
        guard urlPath.hasPrefix(rootPath + "/") else {
            return url.lastPathComponent
        }

        return String(urlPath.dropFirst(rootPath.count + 1))
    }

    private func previewSafeRelativePath(forEntrypoint sourceURL: URL, sourceRoot: URL) -> String {
        let path = relativePath(from: sourceRoot, to: sourceURL)
        guard path == "main.swift" || path.hasSuffix("/main.swift") else {
            return path
        }

        let directory = String(path.dropLast("main.swift".count))
        return "\(directory)AdaEditorPreviewMain.swift"
    }

    private func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func normalizedRequirement(_ requirement: String?) -> String {
        guard let requirement, !requirement.isEmpty else {
            return #".branch("main")"#
        }

        if requirement.contains(#"from:"#) || requirement.contains(#"exact:"#) || requirement.contains(#"branch:"#) || requirement.contains(#"revision:"#) {
            let parts = requirement.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                return requirement
            }

            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            switch parts[0] {
            case "from":
                return #"from: "\#(escaped(value))""#
            case "exact":
                return #".exact("\#(escaped(value))")"#
            case "branch":
                return #".branch("\#(escaped(value))")"#
            case "revision":
                return #".revision("\#(escaped(value))")"#
            default:
                return requirement
            }
        }

        return requirement
    }

    private static func adaEnginePackageURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL
    }
}

@MainActor
final class EditorPreviewDynamicLibrary {
    typealias MakeViewFunction = @convention(c) () -> UnsafeMutableRawPointer

    private var handle: UnsafeMutableRawPointer?
    private var retainedHandles: [UnsafeMutableRawPointer] = []
    private var makeViewFunction: MakeViewFunction?

    func load(artifact: EditorPreviewBuildArtifact) throws -> UIView {
        retainActiveHandle()

        #if canImport(Darwin) || canImport(Glibc)
            guard let handle = dlopen(artifact.libraryURL.path, RTLD_NOW | RTLD_LOCAL) else {
                throw EditorPreviewBuildFailure(message: Self.lastDynamicLibraryError())
            }

            guard let symbol = dlsym(handle, artifact.symbolName) else {
                dlclose(handle)
                throw EditorPreviewBuildFailure(message: "Preview symbol \(artifact.symbolName) was not found.")
            }

            let function = unsafeBitCast(symbol, to: MakeViewFunction.self)
            let rawView = function()

            self.handle = handle
            self.makeViewFunction = function
            return Unmanaged<UIView>.fromOpaque(rawView).takeRetainedValue()
        #else
            throw EditorPreviewBuildFailure(message: "AdaEditor previews are supported only on platforms with dynamic library loading.")
        #endif
    }

    private func retainActiveHandle() {
        if let handle {
            retainedHandles.append(handle)
        }
        handle = nil
        makeViewFunction = nil
    }

    private static func lastDynamicLibraryError() -> String {
        #if canImport(Darwin) || canImport(Glibc)
            if let error = dlerror() {
                return String(cString: error)
            }
        #endif
        return "Unknown dynamic library error."
    }
}

extension SwiftPackageModel {
    func target(containing document: EditorTextDocument, projectURL: URL) -> SwiftPackageTarget? {
        guard let absolutePath = document.absolutePath else {
            return nil
        }

        let fileURL = URL(fileURLWithPath: absolutePath, isDirectory: false).resolvingSymlinksInPath().standardizedFileURL
        let relativePath = fileURL.path.replacingOccurrences(of: projectURL.resolvingSymlinksInPath().standardizedFileURL.path + "/", with: "")

        return targets.first { target in
            guard target.type == "regular" || target.type == "library" || target.type == "executable" else {
                return false
            }

            let targetPath = target.path ?? "Sources/\(target.name)"
            guard relativePath == targetPath || relativePath.hasPrefix(targetPath + "/") else {
                return false
            }

            guard !target.sources.isEmpty else {
                return true
            }

            return target.sources.contains { source in
                relativePath == source || relativePath.hasSuffix("/" + source)
            }
        }
    }

    func target(named name: String) -> SwiftPackageTarget? {
        targets.first { $0.name == name }
    }
}
