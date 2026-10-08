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
    func build(_ request: EditorAdaScriptPreviewBuildRequest) throws -> EditorAdaScriptPreviewArtifact {
        _ = request
        throw EditorPreviewBuildFailure(message: "AdaUI views in AdaScript are temporarily unavailable.")
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

}
