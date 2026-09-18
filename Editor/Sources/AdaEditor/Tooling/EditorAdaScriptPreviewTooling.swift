@_spi(AdaEngine) import AdaEngine
import AdaScriptCompilerCore
import Foundation

struct EditorAdaScriptPreviewArtifact: Sendable {
    var identifier: String
    var sources: [AdaScriptSource]
}

struct EditorAdaScriptPreviewBuildRequest: Equatable, Sendable {
    var projectURL: URL
    var document: EditorTextDocument
    var packageModel: SwiftPackageModel?
    var declaration: EditorPreviewDeclaration
}

actor EditorAdaScriptPreviewBuilder {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func build(_ request: EditorAdaScriptPreviewBuildRequest) throws -> EditorAdaScriptPreviewArtifact {
        guard request.declaration.kind == .adaScript else {
            throw EditorPreviewBuildFailure(message: "Expected an AdaScript preview declaration.")
        }
        let sourceRoot: URL
        let sourceGroupName: String
        if let packageModel = request.packageModel {
            guard let target = packageModel.target(containing: request.document, projectURL: request.projectURL) else {
                throw EditorPreviewBuildFailure(message: "Could not resolve the SwiftPM target for \(request.document.relativePath).")
            }
            sourceRoot =
                URL(
                    fileURLWithPath: target.path ?? "Sources/\(target.name)",
                    relativeTo: request.projectURL
                )
                .standardizedFileURL
            sourceGroupName = target.name
        } else {
            let project = try ProjectSystem.loadProject(at: request.projectURL, fileManager: fileManager)
            guard project.build.system == .adaScript else {
                throw EditorPreviewBuildFailure(message: "AdaScript previews require an AdaScript or SwiftPM project.")
            }
            let sourcePath = project.paths.sources ?? "Sources"
            sourceRoot = request.projectURL.appendingPathComponent(sourcePath, isDirectory: true).standardizedFileURL
            sourceGroupName = project.runtime.moduleName
        }
        guard
            let enumerator = fileManager.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            throw EditorPreviewBuildFailure(message: "Could not enumerate AdaScript sources in \(sourceGroupName).")
        }

        let activeURL = request.document.absolutePath.map {
            URL(fileURLWithPath: $0, isDirectory: false).standardizedFileURL
        }
        var sources: [AdaScriptSource] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "ada" {
            let standardizedURL = url.standardizedFileURL
            let source: String
            if standardizedURL == activeURL {
                source = request.document.content
            } else {
                source = try String(contentsOf: standardizedURL, encoding: .utf8)
            }
            sources.append(
                AdaScriptSource(
                    path: relativePath(from: sourceRoot, to: standardizedURL),
                    source: source
                )
            )
        }
        sources += try AdaScriptLibraryLock.load(at: request.projectURL).loadSources(at: request.projectURL)
        sources.sort { $0.path < $1.path }
        guard !sources.isEmpty else {
            throw EditorPreviewBuildFailure(message: "\(sourceGroupName) contains no .ada sources.")
        }
        return EditorAdaScriptPreviewArtifact(identifier: request.declaration.id, sources: sources)
    }

    func build(_ request: EditorPreviewBuildRequest) throws -> EditorAdaScriptPreviewArtifact {
        try build(
            EditorAdaScriptPreviewBuildRequest(
                projectURL: request.projectURL,
                document: request.document,
                packageModel: request.packageModel,
                declaration: request.declaration
            )
        )
    }

    private func relativePath(from root: URL, to file: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else {
            return file.lastPathComponent
        }
        return String(filePath.dropFirst(rootPath.count + 1))
    }
}
