#if os(Windows)
import AdaEngine
import Crypto
import Foundation
import MCP

/// Persists the approved import target before publishing the asset so interrupted calls can be retried.
struct EditorBlenderSceneJob: Codable {
    let projectPath: String
    let id: String
    let name: String
    let digest: Data
    var scene: String?
    var destination: String?
    var assetPath: String?

    var entityID: String { "blender-\(id)" }

    static func recordExport(_ bytes: Data, project: URL, id: String, name: String) throws {
        let job = Self(projectPath: project.path, id: id, name: name, digest: Data(SHA256.hash(data: bytes)))
        try job.save(in: project)
    }

    static func load(_ id: String, in project: URL) throws -> Self {
        let receipt = try directory(id, in: project).appendingPathComponent("Job.json")
        guard EditorBlenderMCPExport.isDirect(receipt, directory: false) else { throw Failure.missingExport }
        let file = try FileHandle(forReadingFrom: receipt)
        defer { try? file.close() }
        guard let bytes = try file.read(upToCount: 16_385), (1...16_384).contains(bytes.count),
              let job = try? JSONDecoder().decode(Self.self, from: bytes),
              job.id == id, job.projectPath == project.path else { throw Failure.missingExport }
        return job
    }

    func save(in project: URL) throws {
        let path = try Self.directory(id, in: project).appendingPathComponent("Job.json")
        try JSONEncoder().encode(self).write(to: path, options: .atomic)
    }

    static func hasExports(in project: URL) -> Bool {
        [project.appendingPathComponent("Downloads"), project.appendingPathComponent("Downloads/Blender")].allSatisfy {
            EditorBlenderMCPExport.isDirect($0, directory: true)
        }
    }

    private static func directory(_ id: String, in project: URL) throws -> URL {
        guard Foundation.UUID(uuidString: id)?.uuidString.lowercased() == id, hasExports(in: project) else { throw Failure.missingExport }
        let directory = project.appendingPathComponent("Downloads/Blender/\(id)", isDirectory: true)
        guard EditorBlenderMCPExport.isDirect(directory, directory: true) else { throw Failure.missingExport }
        return directory
    }

    func exportURL(in project: URL) throws -> URL { try Self.directory(id, in: project).appendingPathComponent("Model.glb") }

    func matches(_ bytes: Data) -> Bool { Data(SHA256.hash(data: bytes)) == digest }

    enum Failure: LocalizedError {
        case parameters, missingExport, binding, assetChanged, invalidScene, placeFirst, playBusy, playChanged, modelNotLoaded

        var errorDescription: String? {
            switch self {
            case .parameters: "Give a Blender job ID and valid project-relative scene and destination paths."
            case .missingExport: "This Blender export job is missing from the current project."
            case .binding: "This Blender job is already assigned to a different scene or asset destination."
            case .assetChanged: "The Blender export or its imported asset has changed. Start a new export."
            case .invalidScene: "Could not read the target scene."
            case .placeFirst: "Place the imported Blender model in the target scene first."
            case .playBusy: "Stop the current Play run before verifying this Blender model."
            case .playChanged: "The target Play run stopped, changed scene, or was replaced."
            case .modelNotLoaded: "The Blender model did not finish loading in the target Play run."
            }
        }
    }
}

enum EditorBlenderSceneAction {
    case importModel(job: String, scene: String, destination: String)
    case place(job: String, scene: String, revision: String, position: [Double])
    case verify(job: String, scene: String)

    static let definitions: [EditorCloudValue] = [
        definition("blender.import_glb", "Import the GLB for a Blender job into the chosen project Assets folder and bind the job to an open scene.", ["destination": pathSchema], ["destination"]),
        definition("blender.place_model", "Place the imported Blender job in the bound scene with its current revision. A completed placement can be retried safely.", [
            "expectedRevision": pathSchema,
            "position": ["type": "array", "minItems": 3, "maxItems": 3, "items": ["type": "number"]]
        ], ["expectedRevision"]),
        definition("blender.verify_play", "Start or reuse scene Play for this job, verify the instantiated model and capture a fresh frame. Report the PNG for human visual confirmation.", [:], [])
    ]

    private static var pathSchema: EditorCloudValue { ["type": "string", "minLength": 1, "maxLength": 512] }

    private static func definition(_ name: String, _ description: String, _ fields: [String: EditorCloudValue], _ required: [String]) -> EditorCloudValue {
        var properties = fields
        properties["job"] = ["type": "string", "minLength": 36, "maxLength": 36]
        properties["scene"] = pathSchema
        return [
            "tool": .string(name), "description": .string(description),
            "inputSchema": ["type": "object", "additionalProperties": false,
                            "required": .array((["job", "scene"] + required).map(EditorCloudValue.string)), "properties": .object(properties)]
        ]
    }

    init(_ arguments: EditorCloudValue) throws {
        let input = arguments["input"]
        guard let job = input["job"].string, Foundation.UUID(uuidString: job)?.uuidString.lowercased() == job,
              let scene = input["scene"].string, Self.relativeComponents(scene) != nil,
              SceneDocumentFormat.isSceneFile(URL(fileURLWithPath: scene)) else { throw EditorBlenderSceneJob.Failure.parameters }
        let keys = Set(input.object.keys)
        switch arguments["tool"].string {
        case "blender.import_glb":
            guard keys == ["job", "scene", "destination"], let destination = input["destination"].string,
                  Self.relativeComponents(destination) != nil else { throw EditorBlenderSceneJob.Failure.parameters }
            self = .importModel(job: job, scene: scene, destination: destination)
        case "blender.place_model":
            guard keys.isSubset(of: ["job", "scene", "expectedRevision", "position"]),
                  let revision = input["expectedRevision"].string, (1...128).contains(revision.utf8.count) else { throw EditorBlenderSceneJob.Failure.parameters }
            let position: [Double]
            if let raw = input.object["position"] {
                guard raw.array.count == 3 else { throw EditorBlenderSceneJob.Failure.parameters }
                position = try raw.array.map {
                    switch $0 {
                    case .number, .integer:
                        guard (-10_000...10_000).contains($0.seconds) else { throw EditorBlenderSceneJob.Failure.parameters }
                        return $0.seconds
                    default: throw EditorBlenderSceneJob.Failure.parameters
                    }
                }
            } else {
                position = [0, 0, 0]
            }
            self = .place(job: job, scene: scene, revision: revision, position: position)
        case "blender.verify_play":
            guard keys == ["job", "scene"] else { throw EditorBlenderSceneJob.Failure.parameters }
            self = .verify(job: job, scene: scene)
        default: throw EditorBlenderSceneJob.Failure.parameters
        }
    }

    static func relativeComponents(_ path: String) -> [String]? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (1...512).contains(path.utf8.count), components.count <= 24, components.allSatisfy({ part in
            (1...255).contains(part.utf8.count) && !part.hasSuffix(".") && !part.hasSuffix(" ") &&
                part.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && !#"\:<>\"|?*"#.contains(String($0)) }
        }) else { return nil }
        return components
    }

    @MainActor func run(project: URL) async throws -> EditorCloudValue {
        try Task.checkCancellation()
        let root = project.resolvingSymlinksInPath().standardizedFileURL
        guard let editor = EditorAgentMCPTools.shared.activeViewModel,
              editor.projectURL?.resolvingSymlinksInPath().standardizedFileURL.path == root.path,
              editor.agent.agentPermissionMode != .deny else { throw EditorBlenderMCPExport.Failure.authorization }
        switch self {
        case let .importModel(id, scene, destination):
            _ = try Self.document(scene, in: editor)
            var job = try EditorBlenderSceneJob.load(id, in: root)
            if let boundScene = job.scene, boundScene != scene || job.destination != destination { throw EditorBlenderSceneJob.Failure.binding }
            return try EditorAgentModelToolService(projectURL: root).importBlenderJob(&job, scene: scene, destination: destination)
        case let .place(id, scene, revision, position):
            let job = try EditorBlenderSceneJob.load(id, in: root)
            let document = try Self.document(scene, in: editor)
            let asset = try Self.requireImported(job, scene: scene, root: root)
            if try Self.containsModel(job, reference: asset.reference, in: document) {
                return Self.placement(job, document: document, reference: asset.reference)
            }
            var transform = EditorComponentRegistry.defaultPayload(for: EditorBuiltInComponentType.transform)
            transform["position"] = .array(position.map(EditorSceneValue.double))
            var model = EditorComponentRegistry.defaultPayload(for: EditorBuiltInComponentType.model3DSource)
            model["source"] = .string(asset.reference)
            let updated = try EditorAgentMCPTools.shared.applySceneOperations(
                [.createEntity(id: job.entityID, name: job.name, parentID: nil, components: [
                    EditorBuiltInComponentType.model3DSource: model,
                    EditorBuiltInComponentType.transform: transform
                ])], expectedRevision: revision, document: document, viewModel: editor)
            return Self.placement(job, document: updated, reference: asset.reference)
        case let .verify(id, scene):
            let job = try EditorBlenderSceneJob.load(id, in: root)
            let document = try Self.document(scene, in: editor)
            let asset = try Self.requireImported(job, scene: scene, root: root)
            guard try Self.containsModel(job, reference: asset.reference, in: document) else { throw EditorBlenderSceneJob.Failure.placeFirst }
            // The scene loader resolves the portable reference before installing Model3DSource.
            let modelPath = root.appendingPathComponent(asset.path).resolvingSymlinksInPath().standardizedFileURL.path
            var result = Self.placement(job, document: document, reference: asset.reference)
            do {
                let run = try await EditorAgentWorkspaceMCPTools.shared.startTrackedPlay(document: document, entityID: job.entityID, editor: editor)
                let runningContent = editor.workbench.activeSceneDocument?.content
                let capture = try await EditorGameFrameCapture.captureTrackedModel(run, modelPath: modelPath, projectURL: root) {
                    EditorAgentMCPTools.shared.activeViewModel === editor && editor.trackedScenePlay == run && editor.playModeState.isPlaying &&
                        editor.agent.agentPermissionMode != .deny && editor.projectURL?.resolvingSymlinksInPath().standardizedFileURL.path == root.path &&
                        editor.workbench.activeSceneDocument?.id == run.sceneDocumentID && editor.workbench.activeSceneDocument?.content == runningContent
                }
                for (key, value) in capture.object { result[key] = value }
                result["stage"] = "captured"
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result["playStatus"] = "failed"
                result["reason"] = .string(L10n.tr(error.localizedDescription))
            }
            return result
        }
    }

    @MainActor private static func document(_ path: String, in editor: EditorViewModel) throws -> EditorSceneDocument {
        try EditorAgentMCPTools.shared.sceneDocument(path: path, in: editor)
    }

    @MainActor private static func requireImported(_ job: EditorBlenderSceneJob, scene: String, root: URL) throws -> (path: String, reference: String) {
        guard job.scene == scene else { throw EditorBlenderSceneJob.Failure.binding }
        return try EditorAgentModelToolService(projectURL: root).importedBlenderAsset(job)
    }

    private static func containsModel(_ job: EditorBlenderSceneJob, reference: String, in document: EditorSceneDocument) throws -> Bool {
        guard let model = document.sceneModel ?? EditorSceneFileLoader.model(from: document.content) else {
            throw EditorBlenderSceneJob.Failure.invalidScene
        }
        guard let entity = model.entities.first(where: { $0.id == job.entityID }) else { return false }
        guard entity.enabled, entity.components[EditorBuiltInComponentType.model3DSource]?["source"]?.stringValue == reference else {
            throw EditorBlenderSceneJob.Failure.placeFirst
        }
        return true
    }

    private static func placement(_ job: EditorBlenderSceneJob, document: EditorSceneDocument, reference: String) -> EditorCloudValue {
        ["job": .string(job.id), "stage": "placed", "scene": .string(document.relativePath), "entityID": .string(job.entityID),
         "assetReference": .string(reference), "revision": .string(EditorAgentSceneToolService.revision(for: document.content))]
    }
}
#endif
