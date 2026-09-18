import AdaPackageManifestTool
import Foundation

/// The source-language starter used when AdaEditor creates a project.
public enum EditorProjectTemplate: String, CaseIterable, Equatable, Sendable {
    /// Gameplay and application entry points are loaded directly from Ada Script project metadata.
    case adaScript
    /// Gameplay can be implemented in both Ada Script and Swift from the start.
    case adaScriptWithSwift

    public var displayName: String {
        switch self {
        case .adaScript:
            "AdaScript"
        case .adaScriptWithSwift:
            "AdaScript + Swift"
        }
    }

    public var summary: String {
        switch self {
        case .adaScript:
            "Portable AdaScript project without Swift or Package.swift"
        case .adaScriptWithSwift:
            "Hybrid project with editable Swift and AdaScript sources"
        }
    }
}

private enum EditorProjectTemplateSourceFactory {
    static func manifest(projectName: String, targetName: String, adaEnginePackageURL: URL) -> String {
        """
        // swift-tools-version: 6.2
        import PackageDescription

        let package = Package(
            name: "\(projectName)",
            platforms: [
                .iOS(.v18),
                .tvOS(.v18),
                .visionOS(.v2),
                .macOS(.v15)
            ],
            products: [
                .executable(name: "\(projectName)", targets: ["\(targetName)"])
            ],
            dependencies: [
                .package(name: "AdaEngine", path: "\(escapedManifestString(adaEnginePackageURL.path))")
            ],
            targets: [
                .executableTarget(
                    name: "\(targetName)",
                    dependencies: [.product(name: "AdaEngine", package: "AdaEngine")],
                    resources: [.copy("../../Assets")],
                    plugins: [.plugin(name: "AdaScriptBuildPlugin", package: "AdaEngine")]
                )
            ]
        )
        """
    }

    static func swiftBootstrap(for template: EditorProjectTemplate) -> String {
        let appDeclaration = """
                struct Game: App {
                    var body: some AppScene {
                        WindowGroup(
                            content: {
                                AdaScriptViewsGenerated.mainView
                            },
                            assetBundle: .module
                        )
                        .addPlugins(AdaScriptPluginsGenerated())
                    }
                }
            """

        switch template {
        case .adaScript:
            return """
                import AdaEngine

                @main
                \(appDeclaration)

                """
        case .adaScriptWithSwift:
            return """
                import AdaEngine
                import Foundation

                try await Game.main()

                \(appDeclaration)

                """
        }
    }

    static let adaScript = """
        @previewable
        @view(id: "game.main")
        class MainView {
            func body() {
                VStack(spacing: 12) {
                    Text("Hello, Ada!").fontSize(28);
                    Text("Edit Main.ada to build your interface.");
                }.padding(24);
            }
        }

        @system(scheduler: "update", id: "game.main")
        class MainSystem {
            func update(context: AdaSystemContext) {
                // Add gameplay here. This system runs once per frame.
            }
        }

        """

    private static func escapedManifestString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// A recently created or opened AdaEditor project persisted in the editor application data.
public struct EditorProjectReference: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var path: String
    public var lastOpenedAt: Date
    public var bookmarkData: Data?
    public var documentsRelativePath: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        path: String,
        lastOpenedAt: Date = Date(),
        bookmarkData: Data? = nil,
        documentsRelativePath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.lastOpenedAt = lastOpenedAt
        self.bookmarkData = bookmarkData
        self.documentsRelativePath = documentsRelativePath
    }
}

/// Persists AdaEditor project references in `Application Support/AdaEditor/projects.json`.
public struct EditorProjectStore {
    public static let maximumRecentProjectCount = 50

    /// iPad projects are portable packages; desktop projects start as ordinary directories.
    public static var defaultUsesProjectPackage: Bool {
        #if os(iOS)
            true
        #else
            false
        #endif
    }

    public let distribution: EditorDistribution
    public let storageURL: URL
    public let fileManager: FileManager
    public let adaEnginePackageURL: URL
    public let documentsDirectoryURL: URL?

    public init(
        storageURL: URL? = nil,
        fileManager: FileManager = .default,
        adaEnginePackageURL: URL? = nil,
        documentsDirectoryURL: URL? = nil,
        distribution: EditorDistribution = .current
    ) {
        self.distribution = distribution
        self.fileManager = fileManager
        self.storageURL = storageURL ?? Self.defaultStorageURL(fileManager: fileManager)
        self.adaEnginePackageURL = (adaEnginePackageURL ?? Self.defaultAdaEnginePackageURL()).standardizedFileURL
        self.documentsDirectoryURL = (documentsDirectoryURL ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first)?.standardizedFileURL
    }

    @discardableResult
    public func createProject(
        named name: String,
        at parentDirectory: URL,
        template: EditorProjectTemplate = .adaScriptWithSwift,
        asPackage: Bool = Self.defaultUsesProjectPackage,
        openedAt: Date = Date()
    ) throws -> EditorProjectReference {
        try distribution.validate(buildSystem: template == .adaScript ? .adaScript : .swiftpm)
        let projectName = try normalizedProjectName(name)
        let directoryName = asPackage ? "\(projectName).adaproject" : projectName
        let projectURL = parentDirectory.appendingPathComponent(directoryName, isDirectory: true)

        try validateCreationDestination(projectURL)
        try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try createInitialProjectFiles(named: projectName, at: projectURL, template: template)
        let buildSystem: AdaProjectBuildSystem = template == .adaScript ? .adaScript : .swiftpm
        _ = try ProjectSystem.createDefaultProject(at: projectURL, buildSystem: buildSystem, fileManager: fileManager)
        if buildSystem == .swiftpm {
            _ = try ensureAdaEngineDependency(at: projectURL)
        }

        return try rememberProject(at: projectURL, name: projectName, openedAt: openedAt)
    }

    @discardableResult
    public func openProject(at projectURL: URL, openedAt: Date = Date()) throws -> EditorProjectReference {
        let project = try ProjectSystem.validateProjectLayout(at: projectURL, fileManager: fileManager)
        try distribution.validate(buildSystem: project.build.system)
        if project.build.system == .swiftpm {
            _ = try ensureAdaEngineDependency(at: projectURL)
        }
        let displayName = project.project.displayName ?? project.project.name ?? projectURL.lastPathComponent

        return try rememberProject(at: projectURL, name: displayName, openedAt: openedAt)
    }

    @discardableResult
    public func rememberProject(at projectURL: URL, name: String? = nil, openedAt: Date = Date()) throws -> EditorProjectReference {
        var projects = try loadProjects()
        let standardizedPath = projectURL.standardizedFileURL.path
        let displayName = name ?? projectURL.lastPathComponent
        let existingID = projects.first(where: { $0.path == standardizedPath })?.id
        let existingBookmark = projects.first(where: { $0.path == standardizedPath })?.bookmarkData
        let reference = EditorProjectReference(
            id: existingID ?? UUID().uuidString,
            name: displayName,
            path: standardizedPath,
            lastOpenedAt: openedAt,
            bookmarkData: makeBookmarkData(for: projectURL) ?? existingBookmark,
            documentsRelativePath: documentsRelativePath(for: projectURL)
        )

        projects.removeAll { $0.path == standardizedPath }
        projects.insert(reference, at: 0)
        try saveProjects(projects)
        return reference
    }

    /// Adds a remote SwiftPM dependency to the project's real Package.swift.
    @discardableResult
    public func addDependency(to projectURL: URL, url: String, requirement: String) throws -> Bool {
        try editManifest(at: projectURL, command: .addDependency(url: url, requirement: requirement))
    }

    /// Adds a filesystem SwiftPM dependency to the project's real Package.swift.
    @discardableResult
    public func addLocalDependency(to projectURL: URL, name: String? = nil, path: String) throws -> Bool {
        try editManifest(at: projectURL, command: .addLocalDependency(name: name, path: path))
    }

    /// Removes both the package declaration and target product references for a dependency.
    @discardableResult
    public func removeDependency(from projectURL: URL, identity: String) throws -> Bool {
        try editManifest(at: projectURL, command: .removeDependency(identity: identity))
    }

    /// Ensures every executable target links the local AdaEngine package.
    @discardableResult
    public func ensureAdaEngineDependency(at projectURL: URL, targetName: String? = nil) throws -> Bool {
        try editManifest(
            at: projectURL,
            command: .ensureAdaEngineDependency(path: adaEnginePackageURL.path, targetName: targetName)
        )
    }

    /// Atomically updates project metadata and synchronizes build file/resource selection into Package.swift.
    public func saveProjectSettings(_ project: AdaProject, at projectURL: URL, targetName: String) throws {
        try distribution.validate(buildSystem: project.build.system)
        try ProjectSystem.validate(project)
        guard project.build.system == .swiftpm else {
            try ProjectSystem.saveProject(project, at: projectURL, fileManager: fileManager)
            return
        }
        let manifestURL = projectURL.appendingPathComponent("Package.swift", isDirectory: false)
        let originalManifest = try String(contentsOf: manifestURL, encoding: .utf8)
        let result = try PackageManifestEditor.edit(
            originalManifest,
            command: .configureTarget(
                name: targetName,
                sources: project.build.includedFiles,
                exclude: project.build.excludedFiles,
                resources: project.paths.resourceRoots
            )
        )

        if result.changed {
            try writeManifest(result.manifest, replacing: originalManifest, at: manifestURL)
        }
        do {
            try ProjectSystem.saveProject(project, at: projectURL, fileManager: fileManager)
        } catch {
            if result.changed {
                try? originalManifest.write(to: manifestURL, atomically: true, encoding: .utf8)
            }
            throw error
        }
    }

    public func setRunDestination(_ destination: AdaProjectRunDestination, at projectURL: URL) throws {
        var project = try ProjectSystem.loadProject(at: projectURL, fileManager: fileManager)
        project.run.destination = destination
        try ProjectSystem.saveProject(project, at: projectURL, fileManager: fileManager)
    }

    private func createInitialProjectFiles(named projectName: String, at projectURL: URL, template: EditorProjectTemplate) throws {
        switch template {
        case .adaScript:
            try createAdaScriptSources(at: projectURL)
        case .adaScriptWithSwift:
            try createSwiftPackage(named: projectName, at: projectURL, template: template)
        }
        try createAssetsDirectory(at: projectURL)
        try createDefaultScene(named: projectName, at: projectURL)
        try createReadme(named: projectName, at: projectURL, template: template)
    }

    private func createAdaScriptSources(at projectURL: URL) throws {
        let sourcesURL = projectURL.appendingPathComponent("Sources", isDirectory: true)
        try fileManager.createDirectory(at: sourcesURL, withIntermediateDirectories: true)
        try EditorProjectTemplateSourceFactory.adaScript.write(
            to: sourcesURL.appendingPathComponent("Main.ada", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
    }

    private func createSwiftPackage(named projectName: String, at projectURL: URL, template: EditorProjectTemplate) throws {
        let manifestURL = projectURL.appendingPathComponent("Package.swift", isDirectory: false)
        guard !fileManager.fileExists(atPath: manifestURL.path) else {
            return
        }

        let safeTargetName = projectName.replacingOccurrences(of: "-", with: "_")
        let manifest = EditorProjectTemplateSourceFactory.manifest(
            projectName: projectName,
            targetName: safeTargetName,
            adaEnginePackageURL: adaEnginePackageURL
        )

        try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
        let sourcesURL =
            projectURL
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent(safeTargetName, isDirectory: true)
        try fileManager.createDirectory(at: sourcesURL, withIntermediateDirectories: true)
        let swiftFileName = template == .adaScript ? "AdaRuntimeBootstrap.swift" : "main.swift"
        try EditorProjectTemplateSourceFactory.swiftBootstrap(for: template)
            .write(
                to: sourcesURL.appendingPathComponent(swiftFileName, isDirectory: false),
                atomically: true,
                encoding: .utf8
            )

        try EditorProjectTemplateSourceFactory.adaScript.write(
            to: sourcesURL.appendingPathComponent("Main.ada", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
    }

    public static func defaultAdaEnginePackageURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL
    }

    private func editManifest(at projectURL: URL, command: PackageManifestCommand) throws -> Bool {
        try distribution.validate(buildSystem: .swiftpm)
        let manifestURL = projectURL.appendingPathComponent("Package.swift", isDirectory: false)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw ProjectSystemError.swiftPackageManifestMissing(path: "Package.swift")
        }

        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
        let result = try PackageManifestEditor.edit(manifest, command: command)
        if result.changed {
            try writeManifest(result.manifest, replacing: manifest, at: manifestURL)
        }
        return result.changed
    }

    private func writeManifest(_ candidate: String, replacing original: String, at manifestURL: URL) throws {
        try PackageManifestEditor.validateManifestSyntax(candidate)
        do {
            try candidate.write(to: manifestURL, atomically: true, encoding: .utf8)
            let persisted = try String(contentsOf: manifestURL, encoding: .utf8)
            guard persisted == candidate else {
                throw EditorProjectStoreError.manifestVerificationFailed(path: manifestURL.path)
            }
            try PackageManifestEditor.validateManifestSyntax(persisted)
        } catch {
            if (try? String(contentsOf: manifestURL, encoding: .utf8)) != original {
                try? original.write(to: manifestURL, atomically: true, encoding: .utf8)
            }
            throw error
        }
    }

    private func validateCreationDestination(_ projectURL: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: projectURL.path, isDirectory: &isDirectory) else {
            return
        }
        guard isDirectory.boolValue else {
            throw EditorProjectStoreError.projectPathIsNotDirectory(path: projectURL.path)
        }
        let contents = try fileManager.contentsOfDirectory(atPath: projectURL.path)
        guard contents.isEmpty else {
            throw EditorProjectStoreError.projectDirectoryNotEmpty(path: projectURL.path)
        }
    }

    private func createAssetsDirectory(at projectURL: URL) throws {
        let assetsURL = projectURL.appendingPathComponent("Assets", isDirectory: true)
        try fileManager.createDirectory(at: assetsURL, withIntermediateDirectories: true)

        let keepURL = assetsURL.appendingPathComponent(".gitkeep", isDirectory: false)
        if !fileManager.fileExists(atPath: keepURL.path) {
            try Data().write(to: keepURL, options: [.atomic])
        }
    }

    private func createDefaultScene(named projectName: String, at projectURL: URL) throws {
        let sceneURL = projectURL.appendingPathComponent(SceneDocumentFormat.defaultScenePath, isDirectory: false)
        let scenesDirectory = sceneURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: scenesDirectory, withIntermediateDirectories: true)

        guard !fileManager.fileExists(atPath: sceneURL.path) else {
            return
        }

        try SceneDocumentFormat.defaultSceneYAML(projectName: projectName)
            .write(
                to: sceneURL,
                atomically: true,
                encoding: .utf8
            )
    }

    private func createReadme(named projectName: String, at projectURL: URL, template: EditorProjectTemplate) throws {
        let readmeURL = projectURL.appendingPathComponent("README.md", isDirectory: false)
        guard !fileManager.fileExists(atPath: readmeURL.path) else {
            return
        }

        let buildDescription =
            template == .adaScript
            ? "`build.system` is `adascript`; AdaEditor loads the project directly without compiling Swift."
            : "`Package.swift` defines the native Swift executable and AdaScript build plugin."
        let packageDescription =
            template == .adaScript
            ? ""
            : "- `Package.swift` — SwiftPM package manifest.\n"
        let readme = """
            # \(projectName)

            Created with AdaEditor.

            \(buildDescription)

            ## Structure

            \(packageDescription)- `.ada/project.json` — AdaEditor project metadata.
            - `Sources/` — game source files.
            - `Assets/` — game assets and scene documents.
            """
        try readme.write(to: readmeURL, atomically: true, encoding: .utf8)
    }

    private func normalizedProjectName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw EditorProjectStoreError.emptyProjectName
        }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let normalizedScalars = trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(normalizedScalars)
    }
}

public enum EditorProjectStoreError: Error, Equatable, Sendable {
    case emptyProjectName
    case projectPathIsNotDirectory(path: String)
    case projectDirectoryNotEmpty(path: String)
    case manifestVerificationFailed(path: String)
}

extension EditorProjectStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyProjectName:
            "Project name must not be empty."
        case let .projectPathIsNotDirectory(path):
            "The project destination is not a directory: \(path)"
        case let .projectDirectoryNotEmpty(path):
            "The project destination already exists and is not empty: \(path)"
        case let .manifestVerificationFailed(path):
            "Package manifest verification failed after writing: \(path)"
        }
    }
}
