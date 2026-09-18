import AdaEngine
import Foundation

/// Reads, validates, and creates Ada project metadata stored at `.ada/project.json`.
public enum ProjectSystem {
    public static let metadataDirectoryName = ".ada"
    public static let metadataFileName = "project.json"
    public static let currentSchemaVersion = 3
    public static let supportedSchemaVersions: Set<Int> = [1, 2, currentSchemaVersion]
    public static let knownBuildSystems: Set<String> = ["adascript", "swiftpm"]

    public static func metadataURL(forProjectAt projectURL: URL) -> URL {
        projectURL
            .appendingPathComponent(metadataDirectoryName, isDirectory: true)
            .appendingPathComponent(metadataFileName, isDirectory: false)
    }

    public static func isAdaProject(at projectURL: URL, fileManager: FileManager = .default) -> Bool {
        (try? validateProjectLayout(at: projectURL, fileManager: fileManager)) != nil
    }

    /// Validates that a folder contains an Ada project supported by its declared build system.
    @discardableResult
    public static func validateProjectLayout(at projectURL: URL, fileManager: FileManager = .default) throws(ProjectSystemError) -> AdaProject {
        let project = try loadProject(at: projectURL, fileManager: fileManager)
        if project.build.system == .swiftpm {
            let manifestURL = projectURL.appendingPathComponent("Package.swift", isDirectory: false)
            guard fileManager.fileExists(atPath: manifestURL.path) else {
                throw .swiftPackageManifestMissing(path: "Package.swift")
            }
        } else if project.build.system == .adaScript {
            let sourcePath = project.paths.sources ?? "Sources"
            var isDirectory: ObjCBool = false
            let sourceURL = projectURL.appendingPathComponent(sourcePath, isDirectory: true)
            guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw .sourceDirectoryMissing(path: sourcePath)
            }
        }
        return project
    }

    public static func loadProject(at projectURL: URL, fileManager: FileManager = .default) throws(ProjectSystemError) -> AdaProject {
        let metadataURL = metadataURL(forProjectAt: projectURL)

        guard fileManager.fileExists(atPath: metadataURL.path) else {
            throw .metadataFileMissing(path: ProjectSystemPath.metadataFile)
        }

        let data: Data
        do {
            data = try Data(contentsOf: metadataURL)
        } catch {
            throw .fileReadFailed(path: ProjectSystemPath.metadataFile, message: error.localizedDescription)
        }

        return try loadProject(from: data, sourcePath: ProjectSystemPath.metadataFile)
    }

    public static func loadProject(from data: Data, sourcePath: String = ProjectSystemPath.metadataFile) throws(ProjectSystemError) -> AdaProject {
        let decoder = JSONDecoder()
        let project: AdaProject

        do {
            project = try decoder.decode(AdaProject.self, from: data)
        } catch let error as DecodingError {
            throw decodeError(from: error, sourcePath: sourcePath)
        } catch {
            throw .invalidJSON(path: sourcePath, message: error.localizedDescription)
        }

        return try migrateAndValidate(project, sourcePath: sourcePath)
    }

    @discardableResult
    public static func createDefaultProject(
        at projectURL: URL,
        buildSystem: AdaProjectBuildSystem = .swiftpm,
        fileManager: FileManager = .default
    ) throws(ProjectSystemError) -> AdaProject {
        if buildSystem == .swiftpm {
            let packageURL = projectURL.appendingPathComponent("Package.swift", isDirectory: false)
            guard fileManager.fileExists(atPath: packageURL.path) else {
                throw .swiftPackageManifestMissing(path: "Package.swift")
            }
        }

        let inferredProjectName =
            projectURL.pathExtension.lowercased() == "adaproject"
            ? projectURL.deletingPathExtension().lastPathComponent
            : projectURL.lastPathComponent
        let project = defaultProject(projectName: inferredProjectName, buildSystem: buildSystem)
        let metadataDirectory = projectURL.appendingPathComponent(metadataDirectoryName, isDirectory: true)
        let metadataURL = metadataURL(forProjectAt: projectURL)

        do {
            try fileManager.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
            let data = try encode(project)
            try data.write(to: metadataURL, options: [.atomic])
        } catch let error as EncodingError {
            throw .encodingFailed(message: error.localizedDescription)
        } catch {
            throw .fileWriteFailed(path: ProjectSystemPath.metadataFile, message: error.localizedDescription)
        }

        return project
    }

    /// Persists validated project settings without exposing callers to the on-disk JSON format.
    public static func saveProject(_ project: AdaProject, at projectURL: URL, fileManager: FileManager = .default) throws(ProjectSystemError) {
        var project = project
        project.schemaVersion = currentSchemaVersion
        try validate(project)

        let metadataDirectory = projectURL.appendingPathComponent(metadataDirectoryName, isDirectory: true)
        let metadataURL = metadataURL(forProjectAt: projectURL)
        do {
            try fileManager.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
            try encode(project).write(to: metadataURL, options: [.atomic])
        } catch let error as EncodingError {
            throw .encodingFailed(message: error.localizedDescription)
        } catch {
            throw .fileWriteFailed(path: ProjectSystemPath.metadataFile, message: error.localizedDescription)
        }
    }

    public static func defaultProject(
        projectName: String = "AdaEngineProject",
        buildSystem: AdaProjectBuildSystem = .swiftpm
    ) -> AdaProject {
        AdaProject(
            schemaVersion: currentSchemaVersion,
            project: .init(name: projectName),
            engine: .init(package: "AdaEngine"),
            paths: .init(
                sources: "Sources",
                assets: "Assets",
                build: buildSystem == .swiftpm ? ".build" : nil,
                generated: nil,
                resourceRoots: ["Assets"],
                run: .init(workingDirectory: ".")
            ),
            build: .init(system: buildSystem),
            run: .init(destination: .macOS, executable: nil, arguments: [], environment: [:], workingDirectory: "."),
            runtime: buildSystem.isAdaScript
                ? .init(
                    moduleName: projectName,
                    entry: .init(scene: SceneDocumentFormat.defaultScenePath, view: "game.main")
                )
                : .init(),
            editor: .init(startupScene: SceneDocumentFormat.defaultScenePath),
            ai: .init(mcp: .init(enabled: true))
        )
    }

    public static func defaultProjectJSON() throws(ProjectSystemError) -> String {
        do {
            return String(bytes: try encode(defaultProject()), encoding: .utf8) ?? ""
        } catch let error as EncodingError {
            throw .encodingFailed(message: error.localizedDescription)
        } catch {
            throw .encodingFailed(message: error.localizedDescription)
        }
    }

    public static func validate(_ project: AdaProject, sourcePath: String = ProjectSystemPath.metadataFile) throws(ProjectSystemError) {
        _ = try migrateAndValidate(project, sourcePath: sourcePath)
    }

    /// Validates supported schema versions without rewriting older project metadata.
    public static func migrateAndValidate(_ project: AdaProject, sourcePath _: String = ProjectSystemPath.metadataFile) throws(ProjectSystemError) -> AdaProject {
        guard supportedSchemaVersions.contains(project.schemaVersion) else {
            throw .unsupportedSchemaVersion(path: "schemaVersion", version: project.schemaVersion, supportedVersions: supportedSchemaVersions.sorted())
        }

        guard knownBuildSystems.contains(project.build.system.rawValue) || project.build.system == .legacyGravity else {
            throw .unknownBuildSystem(path: "build.system", value: project.build.system.rawValue, supportedValues: knownBuildSystems.sorted())
        }
        var project = project
        if project.build.system == .legacyGravity {
            project.build.system = .adaScript
        }

        do {
            try InputAction.validate(project.inputActions)
        } catch {
            throw .invalidField(path: "inputActions", message: error.localizedDescription)
        }
        try validateRelativePath(project.paths.sources, keyPath: "paths.sources")
        try validateRelativePath(project.paths.assets, keyPath: "paths.assets")
        try validateRelativePath(project.paths.build, keyPath: "paths.build")
        try validateRelativePath(project.paths.generated, keyPath: "paths.generated")
        try validatePathArray(project.paths.resourceRoots, keyPath: "paths.resourceRoots")
        try validateRelativePath(project.paths.run.workingDirectory, keyPath: "paths.run.workingDirectory")
        try validateRelativePath(project.run.workingDirectory, keyPath: "run.workingDirectory")
        try validateRelativePath(project.run.executable, keyPath: "run.executable")
        try validateRelativePath(project.runtime.entry.scene, keyPath: "runtime.entry.scene")
        try validateRelativePath(project.editor.startupScene, keyPath: "editor.startupScene")
        try validatePathArray(project.build.targets, keyPath: "build.targets")
        try validatePathArray(project.build.includedFiles, keyPath: "build.includedFiles")
        try validatePathArray(project.build.excludedFiles, keyPath: "build.excludedFiles")
        try validatePathArray(project.ai.mcp.allowedResourceRoots, keyPath: "ai.mcp.allowedResourceRoots")
        try validateRelativePath(project.ai.agent.target.cwd, keyPath: "ai.agent.target.cwd")
        try validatePathArray(project.ai.agent.skillsDirectories, keyPath: "ai.agent.skillsDirectories")

        if project.build.system == .adaScript {
            guard project.runtime.moduleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw .invalidField(path: "runtime.moduleName", message: "AdaScript projects require a module name.")
            }
            let entry = project.runtime.entry
            let hasEntry = [entry.scene, entry.startupSystem, entry.view]
                .contains { value in
                    value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                }
            guard hasEntry else {
                throw .invalidField(
                    path: "runtime.entry",
                    message: "AdaScript projects require a startup scene, root view, or startup system."
                )
            }
            try validateRuntimePlugins(project.runtime.plugins)
            do {
                _ = try EditorAdaScriptRuntimePluginResolver.resolve(project.runtime.plugins)
            } catch {
                throw .invalidField(path: "runtime.plugins", message: error.localizedDescription)
            }
            try validateRuntimeWindow(project.runtime.window)
        }

        return project
    }

    /// Validates whether a project can execute on a destination without invoking a platform toolchain.
    public static func validateRunCompatibility(
        of project: AdaProject,
        at projectURL: URL,
        destination: AdaProjectRunDestination,
        fileManager: FileManager = .default
    ) throws(ProjectSystemError) {
        if destination == .iPadOS, !project.build.system.isAdaScript {
            throw .unsupportedBuildSystemForPlatform(
                platform: destination.rawValue,
                buildSystem: project.build.system.rawValue
            )
        }
        guard project.build.system.isAdaScript else {
            return
        }

        let sourceRoot = project.paths.sources ?? "Sources"
        let sourceURL = projectURL.appendingPathComponent(sourceRoot, isDirectory: true)
        guard
            let enumerator = fileManager.enumerator(
                at: sourceURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            throw .sourceDirectoryMissing(path: sourceRoot)
        }
        for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "swift" {
            let rootPath = projectURL.standardizedFileURL.path
            let filePath = fileURL.standardizedFileURL.path
            let relativePath =
                filePath.hasPrefix(rootPath + "/")
                ? String(filePath.dropFirst(rootPath.count + 1))
                : fileURL.lastPathComponent
            throw .unsupportedSourceLanguage(platform: destination.rawValue, path: relativePath)
        }
    }

    private static func encode(_ project: AdaProject) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(project)
    }

    private static func decodeError(from error: DecodingError, sourcePath: String) -> ProjectSystemError {
        switch error {
        case let .keyNotFound(key, context) where key.stringValue == "schemaVersion":
            .missingSchemaVersion(path: codingPathString(context.codingPath + [key]))
        case let .dataCorrupted(context):
            .invalidJSON(path: sourcePath, message: context.debugDescription)
        case let .keyNotFound(key, context):
            .missingRequiredField(path: codingPathString(context.codingPath + [key]), message: context.debugDescription)
        case let .typeMismatch(_, context),
            let .valueNotFound(_, context):
            .invalidField(path: codingPathString(context.codingPath), message: context.debugDescription)
        @unknown default:
            .invalidJSON(path: sourcePath, message: error.localizedDescription)
        }
    }

    private static func codingPathString(_ codingPath: [CodingKey]) -> String {
        let path = codingPath.map(\.stringValue).joined(separator: ".")
        return path.isEmpty ? ProjectSystemPath.metadataFile : path
    }

    private static func validatePathArray(_ paths: [String], keyPath: String) throws(ProjectSystemError) {
        for (index, path) in paths.enumerated() {
            try validateRelativePath(path, keyPath: "\(keyPath).\(index)")
        }
    }

    private static func validateRelativePath(_ path: String?, keyPath: String) throws(ProjectSystemError) {
        guard let path else {
            return
        }

        guard !path.isEmpty else {
            throw .invalidPath(path: keyPath, value: path, reason: "Path must not be empty.")
        }

        if path.hasPrefix("/") || path.hasPrefix("~") || isWindowsAbsolutePath(path) || path.hasPrefix("\\\\") {
            throw .absolutePathNotAllowed(path: keyPath, value: path)
        }

        if path.contains("\\") {
            throw .invalidPath(path: keyPath, value: path, reason: "Use POSIX-style '/' separators.")
        }

        if path.unicodeScalars.contains(where: { $0.value == 0 }) {
            throw .invalidPath(path: keyPath, value: path, reason: "NUL bytes are not allowed.")
        }

        if path.contains("://") {
            throw .invalidPath(path: keyPath, value: path, reason: "URLs are not allowed.")
        }

        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if segments.contains(where: \.isEmpty) {
            throw .invalidPath(path: keyPath, value: path, reason: "Empty path segments are not allowed.")
        }

        if segments.contains("..") {
            throw .pathTraversalNotAllowed(path: keyPath, value: path)
        }
    }

    private static func isWindowsAbsolutePath(_ path: String) -> Bool {
        guard path.count >= 3 else {
            return false
        }

        let scalars = Array(path.unicodeScalars)
        return CharacterSet.letters.contains(scalars[0])
            && scalars[1] == ":"
            && (scalars[2] == "\\" || scalars[2] == "/")
    }
}

public enum ProjectSystemPath {
    public static let metadataFile = ".ada/project.json"
}

public struct AdaProject: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var project: AdaProjectMetadata
    public var engine: AdaProjectEngine
    public var paths: AdaProjectPaths
    public var build: AdaProjectBuild
    public var run: AdaProjectRun
    public var inputActions: [InputAction]
    public var runtime: AdaProjectRuntime
    public var editor: AdaProjectEditor
    public var ai: AdaProjectAI

    public init(
        schemaVersion: Int,
        project: AdaProjectMetadata = AdaProjectMetadata(),
        engine: AdaProjectEngine = AdaProjectEngine(),
        paths: AdaProjectPaths = AdaProjectPaths(),
        build: AdaProjectBuild = AdaProjectBuild(),
        run: AdaProjectRun = AdaProjectRun(),
        inputActions: [InputAction] = [],
        runtime: AdaProjectRuntime = AdaProjectRuntime(),
        editor: AdaProjectEditor = AdaProjectEditor(),
        ai: AdaProjectAI = AdaProjectAI()
    ) {
        self.schemaVersion = schemaVersion
        self.project = project
        self.engine = engine
        self.paths = paths
        self.build = build
        self.run = run
        self.inputActions = inputActions
        self.runtime = runtime
        self.editor = editor
        self.ai = ai
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, project, engine, paths, build, run, runtime, editor, ai, inputActions
        case legacyBuildSystem = "buildSystem"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        project = try container.decodeIfPresent(AdaProjectMetadata.self, forKey: .project) ?? AdaProjectMetadata()
        engine = try container.decodeIfPresent(AdaProjectEngine.self, forKey: .engine) ?? AdaProjectEngine()
        paths = try container.decodeIfPresent(AdaProjectPaths.self, forKey: .paths) ?? AdaProjectPaths()
        if let build = try container.decodeIfPresent(AdaProjectBuild.self, forKey: .build) {
            self.build = build
        } else if let legacyBuildSystem = try container.decodeIfPresent(AdaProjectBuildSystem.self, forKey: .legacyBuildSystem) {
            self.build = AdaProjectBuild(system: legacyBuildSystem)
        } else {
            self.build = AdaProjectBuild()
        }
        run = try container.decodeIfPresent(AdaProjectRun.self, forKey: .run) ?? AdaProjectRun()
        inputActions = try container.decodeIfPresent([InputAction].self, forKey: .inputActions) ?? []
        runtime = try container.decodeIfPresent(AdaProjectRuntime.self, forKey: .runtime) ?? AdaProjectRuntime()
        editor = try container.decodeIfPresent(AdaProjectEditor.self, forKey: .editor) ?? AdaProjectEditor()
        ai = try container.decodeIfPresent(AdaProjectAI.self, forKey: .ai) ?? AdaProjectAI()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(project, forKey: .project)
        try container.encode(engine, forKey: .engine)
        try container.encode(paths, forKey: .paths)
        try container.encode(build, forKey: .build)
        try container.encode(run, forKey: .run)
        if !inputActions.isEmpty {
            try container.encode(inputActions, forKey: .inputActions)
        }
        if runtime != AdaProjectRuntime() {
            try container.encode(runtime, forKey: .runtime)
        }
        try container.encode(editor, forKey: .editor)
        try container.encode(ai, forKey: .ai)
    }

    /// Compatibility accessor for project.json drafts that used a top-level `buildSystem` field.
    public var buildSystem: AdaProjectBuildSystem {
        get { build.system }
        set { build.system = newValue }
    }
}

public struct AdaProjectMetadata: Codable, Equatable, Sendable {
    public var id: String?
    public var name: String?
    public var displayName: String?
    public var bundleIdentifier: String?

    public init(id: String? = nil, name: String? = nil, displayName: String? = nil, bundleIdentifier: String? = nil) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct AdaProjectEngine: Codable, Equatable, Sendable {
    public var minimumVersion: String?
    public var package: String?

    public init(minimumVersion: String? = nil, package: String? = nil) {
        self.minimumVersion = minimumVersion
        self.package = package
    }
}

public struct AdaProjectPaths: Codable, Equatable, Sendable {
    public var sources: String?
    public var assets: String?
    public var build: String?
    public var generated: String?
    /// Project-relative folders that the editor searches for importable runtime resources.
    public var resourceRoots: [String]
    public var run: AdaProjectRunPaths

    public init(
        sources: String? = nil,
        assets: String? = nil,
        build: String? = nil,
        generated: String? = nil,
        resourceRoots: [String] = [],
        run: AdaProjectRunPaths = AdaProjectRunPaths()
    ) {
        self.sources = sources
        self.assets = assets
        self.build = build
        self.generated = generated
        self.resourceRoots = resourceRoots
        self.run = run
    }

    private enum CodingKeys: String, CodingKey { case sources, assets, build, generated, resourceRoots, run }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sources = try container.decodeIfPresent(String.self, forKey: .sources)
        assets = try container.decodeIfPresent(String.self, forKey: .assets)
        build = try container.decodeIfPresent(String.self, forKey: .build)
        generated = try container.decodeIfPresent(String.self, forKey: .generated)
        resourceRoots = try container.decodeIfPresent([String].self, forKey: .resourceRoots) ?? []
        run = try container.decodeIfPresent(AdaProjectRunPaths.self, forKey: .run) ?? AdaProjectRunPaths()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(sources, forKey: .sources)
        try container.encodeIfPresent(assets, forKey: .assets)
        try container.encodeIfPresent(build, forKey: .build)
        try container.encodeIfPresent(generated, forKey: .generated)
        try container.encode(resourceRoots, forKey: .resourceRoots)
        try container.encode(run, forKey: .run)
    }
}

public struct AdaProjectRunPaths: Codable, Equatable, Sendable {
    public var workingDirectory: String?

    public init(workingDirectory: String? = nil) {
        self.workingDirectory = workingDirectory
    }
}

public struct AdaProjectBuild: Codable, Equatable, Sendable {
    public var system: AdaProjectBuildSystem
    public var configuration: String?
    public var targets: [String]
    /// Project-relative files or directories explicitly included in the selected SwiftPM target.
    public var includedFiles: [String]
    /// Project-relative files or directories excluded from the selected SwiftPM target.
    public var excludedFiles: [String]

    public init(
        system: AdaProjectBuildSystem = .swiftpm,
        configuration: String? = nil,
        targets: [String] = [],
        includedFiles: [String] = [],
        excludedFiles: [String] = []
    ) {
        self.system = system
        self.configuration = configuration
        self.targets = targets
        self.includedFiles = includedFiles
        self.excludedFiles = excludedFiles
    }

    private enum CodingKeys: String, CodingKey { case system, configuration, targets, includedFiles, excludedFiles }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        system = try container.decodeIfPresent(AdaProjectBuildSystem.self, forKey: .system) ?? .swiftpm
        configuration = try container.decodeIfPresent(String.self, forKey: .configuration)
        targets = try container.decodeIfPresent([String].self, forKey: .targets) ?? []
        includedFiles = try container.decodeIfPresent([String].self, forKey: .includedFiles) ?? []
        excludedFiles = try container.decodeIfPresent([String].self, forKey: .excludedFiles) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(system, forKey: .system)
        try container.encodeIfPresent(configuration, forKey: .configuration)
        try container.encode(targets, forKey: .targets)
        try container.encode(includedFiles, forKey: .includedFiles)
        try container.encode(excludedFiles, forKey: .excludedFiles)
    }
}

public struct AdaProjectRun: Codable, Equatable, Sendable {
    public var destination: AdaProjectRunDestination
    public var executable: String?
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?

    public init(
        destination: AdaProjectRunDestination = .macOS,
        executable: String? = nil,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String? = nil
    ) {
        self.destination = destination
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    private enum CodingKeys: String, CodingKey { case destination, executable, arguments, environment, workingDirectory }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        destination = try container.decodeIfPresent(AdaProjectRunDestination.self, forKey: .destination) ?? .macOS
        executable = try container.decodeIfPresent(String.self, forKey: .executable)
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(destination, forKey: .destination)
        try container.encodeIfPresent(executable, forKey: .executable)
        try container.encode(arguments, forKey: .arguments)
        try container.encode(environment, forKey: .environment)
        try container.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
    }
}

public enum AdaProjectRunDestination: String, Codable, CaseIterable, Equatable, Sendable {
    case macOS = "macos"
    case iPadOS = "ipados"
    case web
}

public struct AdaProjectEditor: Codable, Equatable, Sendable {
    public var displayPreview: EditorDisplayPreviewSettings?
    public var startupScene: String?

    public init(startupScene: String? = nil) {
        self.startupScene = startupScene
    }
}

public struct AdaProjectAI: Codable, Equatable, Sendable {
    public var mcp: AdaProjectMCP
    public var agent: AdaProjectAgent
    public var imageGeneration: AdaProjectImageGeneration

    public init(
        mcp: AdaProjectMCP = AdaProjectMCP(),
        agent: AdaProjectAgent = AdaProjectAgent(),
        imageGeneration: AdaProjectImageGeneration = AdaProjectImageGeneration()
    ) {
        self.mcp = mcp
        self.agent = agent
        self.imageGeneration = imageGeneration
    }

    private enum CodingKeys: String, CodingKey { case mcp, agent, imageGeneration }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mcp = try container.decodeIfPresent(AdaProjectMCP.self, forKey: .mcp) ?? AdaProjectMCP()
        agent = try container.decodeIfPresent(AdaProjectAgent.self, forKey: .agent) ?? AdaProjectAgent()
        imageGeneration = try container.decodeIfPresent(AdaProjectImageGeneration.self, forKey: .imageGeneration) ?? AdaProjectImageGeneration()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mcp, forKey: .mcp)
        if agent != AdaProjectAgent() {
            try container.encode(agent, forKey: .agent)
        }
        if imageGeneration != AdaProjectImageGeneration() {
            try container.encode(imageGeneration, forKey: .imageGeneration)
        }
    }
}

public struct AdaProjectImageGeneration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var provider: String
    public var model: String
    public var size: String
    public var quality: String
    public var background: String
    public var outputFormat: String

    public init(
        enabled: Bool = false,
        provider: String = "openai",
        model: String = "gpt-image-2",
        size: String = "1024x1024",
        quality: String = "medium",
        background: String = "transparent",
        outputFormat: String = "png"
    ) {
        self.enabled = enabled
        self.provider = provider
        self.model = model
        self.size = size
        self.quality = quality
        self.background = background
        self.outputFormat = outputFormat
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, provider, model, size, quality, background, outputFormat
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? "openai"
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? "gpt-image-2"
        size = try container.decodeIfPresent(String.self, forKey: .size) ?? "1024x1024"
        quality = try container.decodeIfPresent(String.self, forKey: .quality) ?? "medium"
        background = try container.decodeIfPresent(String.self, forKey: .background) ?? "transparent"
        outputFormat = try container.decodeIfPresent(String.self, forKey: .outputFormat) ?? "png"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(provider, forKey: .provider)
        try container.encode(model, forKey: .model)
        try container.encode(size, forKey: .size)
        try container.encode(quality, forKey: .quality)
        try container.encode(background, forKey: .background)
        try container.encode(outputFormat, forKey: .outputFormat)
    }
}

public struct AdaProjectMCP: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var allowedResourceRoots: [String]

    public init(enabled: Bool = true, allowedResourceRoots: [String] = []) {
        self.enabled = enabled
        self.allowedResourceRoots = allowedResourceRoots
    }

    private enum CodingKeys: String, CodingKey { case enabled, allowedResourceRoots }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        allowedResourceRoots = try container.decodeIfPresent([String].self, forKey: .allowedResourceRoots) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(allowedResourceRoots, forKey: .allowedResourceRoots)
    }
}

public struct AdaProjectAgent: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var target: AdaProjectAgentTarget
    public var permissionMode: AdaProjectAgentPermissionMode
    public var skillsDirectories: [String]

    public init(
        enabled: Bool = false,
        target: AdaProjectAgentTarget = AdaProjectAgentTarget(),
        permissionMode: AdaProjectAgentPermissionMode = .allowOnce,
        skillsDirectories: [String] = [".skills", ".codex/skills"]
    ) {
        self.enabled = enabled
        self.target = target
        self.permissionMode = permissionMode
        self.skillsDirectories = skillsDirectories
    }

    private enum CodingKeys: String, CodingKey { case enabled, target, permissionMode, skillsDirectories }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        target = try container.decodeIfPresent(AdaProjectAgentTarget.self, forKey: .target) ?? AdaProjectAgentTarget()
        permissionMode = try container.decodeIfPresent(AdaProjectAgentPermissionMode.self, forKey: .permissionMode) ?? .allowOnce
        skillsDirectories = try container.decodeIfPresent([String].self, forKey: .skillsDirectories) ?? [".skills", ".codex/skills"]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(target, forKey: .target)
        try container.encode(permissionMode, forKey: .permissionMode)
        try container.encode(skillsDirectories, forKey: .skillsDirectories)
    }
}

public struct AdaProjectAgentTarget: Codable, Equatable, Sendable {
    public var command: String?
    public var arguments: [String]
    public var environment: [String: String]
    public var cwd: String?

    public init(command: String? = nil, arguments: [String] = [], environment: [String: String] = [:], cwd: String? = nil) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.cwd = cwd
    }

    private enum CodingKeys: String, CodingKey { case command, arguments, environment, cwd }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(command, forKey: .command)
        try container.encode(arguments, forKey: .arguments)
        try container.encode(environment, forKey: .environment)
        try container.encodeIfPresent(cwd, forKey: .cwd)
    }
}

public enum AdaProjectAgentPermissionMode: String, Codable, Equatable, Sendable {
    case allowOnce
    case deny
}

public struct AdaProjectBuildSystem: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let swiftpm = Self(rawValue: "swiftpm")
    public static let adaScript = Self(rawValue: "adascript")
    static let legacyGravity = Self(rawValue: "gravity")
    @available(*, deprecated, renamed: "adaScript")
    public static let gravity = legacyGravity

    public var isAdaScript: Bool {
        self == .adaScript || self == .legacyGravity
    }
}

public enum ProjectSystemError: Error, Equatable, Sendable {
    case metadataFileMissing(path: String)
    case swiftPackageManifestMissing(path: String)
    case sourceDirectoryMissing(path: String)
    case fileReadFailed(path: String, message: String)
    case fileWriteFailed(path: String, message: String)
    case invalidJSON(path: String, message: String)
    case missingSchemaVersion(path: String)
    case unsupportedSchemaVersion(path: String, version: Int, supportedVersions: [Int])
    case missingRequiredField(path: String, message: String)
    case invalidField(path: String, message: String)
    case unknownBuildSystem(path: String, value: String, supportedValues: [String])
    case unsupportedBuildSystemForPlatform(platform: String, buildSystem: String)
    case unsupportedSourceLanguage(platform: String, path: String)
    case absolutePathNotAllowed(path: String, value: String)
    case pathTraversalNotAllowed(path: String, value: String)
    case invalidPath(path: String, value: String, reason: String)
    case encodingFailed(message: String)

    public var code: String {
        switch self {
        case .metadataFileMissing: "project.metadataFileMissing"
        case .swiftPackageManifestMissing: "project.swiftPackageManifestMissing"
        case .sourceDirectoryMissing: "project.sourceDirectoryMissing"
        case .fileReadFailed: "project.fileReadFailed"
        case .fileWriteFailed: "project.fileWriteFailed"
        case .invalidJSON: "project.invalidJSON"
        case .missingSchemaVersion: "project.missingSchemaVersion"
        case .unsupportedSchemaVersion: "project.unsupportedSchemaVersion"
        case .missingRequiredField: "project.missingRequiredField"
        case .invalidField: "project.invalidField"
        case .unknownBuildSystem: "project.unknownBuildSystem"
        case .unsupportedBuildSystemForPlatform: "project.unsupportedBuildSystemForPlatform"
        case .unsupportedSourceLanguage: "project.unsupportedSourceLanguage"
        case .absolutePathNotAllowed: "project.absolutePathNotAllowed"
        case .pathTraversalNotAllowed: "project.pathTraversalNotAllowed"
        case .invalidPath: "project.invalidPath"
        case .encodingFailed: "project.encodingFailed"
        }
    }

    public var message: String {
        switch self {
        case let .metadataFileMissing(path): "Ada project metadata file is missing at \(path)."
        case let .swiftPackageManifestMissing(path): "SwiftPM manifest is missing at \(path)."
        case let .sourceDirectoryMissing(path): "Project source directory is missing at \(path)."
        case let .fileReadFailed(path, message): "Failed to read \(path): \(message)"
        case let .fileWriteFailed(path, message): "Failed to write \(path): \(message)"
        case let .invalidJSON(path, message): "Invalid JSON in \(path): \(message)"
        case let .missingSchemaVersion(path): "Missing required schemaVersion at \(path)."
        case let .unsupportedSchemaVersion(_, version, supportedVersions):
            "Unsupported Ada project schemaVersion \(version). Supported versions: \(supportedVersions.map(String.init).joined(separator: ", "))."
        case let .missingRequiredField(path, message): "Missing required field at \(path): \(message)"
        case let .invalidField(path, message): "Invalid field at \(path): \(message)"
        case let .unknownBuildSystem(_, value, supportedValues):
            "Unknown build system '\(value)'. Supported values: \(supportedValues.joined(separator: ", "))."
        case let .unsupportedBuildSystemForPlatform(platform, buildSystem):
            "Projects using '\(buildSystem)' cannot run on \(platform). iPadOS runs AdaScript-only projects."
        case let .unsupportedSourceLanguage(platform, path):
            "Swift source '\(path)' cannot run on \(platform). AdaScript projects must contain only AdaScript gameplay code."
        case let .absolutePathNotAllowed(path, value): "Absolute path is not allowed at \(path): \(value)"
        case let .pathTraversalNotAllowed(path, value): "Path traversal is not allowed at \(path): \(value)"
        case let .invalidPath(path, value, reason): "Invalid path at \(path): \(value). \(reason)"
        case let .encodingFailed(message): "Failed to encode Ada project metadata: \(message)"
        }
    }

    public var recoverySuggestion: String {
        switch self {
        case .metadataFileMissing:
            "Create the project with AdaEditor New Project, or add .ada/project.json using the Ada project schema."
        case .swiftPackageManifestMissing:
            "Choose a folder that contains Package.swift, or create a new Ada project from the start screen."
        case .sourceDirectoryMissing:
            "Create the source directory declared by paths.sources and add at least one .ada file."
        case .fileReadFailed:
            "Check file permissions and make sure the project metadata is readable."
        case .fileWriteFailed:
            "Check folder permissions and available disk space, then try again."
        case .invalidJSON:
            "Fix the JSON syntax in .ada/project.json and try opening the project again."
        case .missingSchemaVersion:
            "Add schemaVersion: \(ProjectSystem.currentSchemaVersion) to .ada/project.json."
        case .unsupportedSchemaVersion:
            "Open the project with a compatible AdaEditor version, or migrate .ada/project.json to schemaVersion \(ProjectSystem.currentSchemaVersion)."
        case .missingRequiredField:
            "Add the required field to .ada/project.json."
        case .invalidField:
            "Update the field value in .ada/project.json to match the expected type."
        case .unknownBuildSystem:
            "Set build.system to adascript or swiftpm in .ada/project.json."
        case .unsupportedBuildSystemForPlatform,
            .unsupportedSourceLanguage:
            "Open this project on macOS, or convert it to an AdaScript project without Swift sources."
        case .absolutePathNotAllowed,
            .pathTraversalNotAllowed,
            .invalidPath:
            "Use project-relative POSIX paths such as Sources or Assets/Scenes/Main.ascn."
        case .encodingFailed:
            "Try creating the project again. If the problem persists, report this AdaEditor error."
        }
    }

    public var fieldPath: String? {
        switch self {
        case let .metadataFileMissing(path),
            let .swiftPackageManifestMissing(path),
            let .sourceDirectoryMissing(path),
            let .fileReadFailed(path, _),
            let .fileWriteFailed(path, _),
            let .invalidJSON(path, _),
            let .missingSchemaVersion(path),
            let .unsupportedSchemaVersion(path, _, _),
            let .missingRequiredField(path, _),
            let .invalidField(path, _),
            let .unknownBuildSystem(path, _, _),
            let .absolutePathNotAllowed(path, _),
            let .pathTraversalNotAllowed(path, _),
            let .invalidPath(path, _, _):
            path
        case .unsupportedBuildSystemForPlatform:
            "build.system"
        case let .unsupportedSourceLanguage(_, path):
            path
        case .encodingFailed:
            nil
        }
    }
}
