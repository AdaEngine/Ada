#if os(Windows)
import AdaEngine
import Foundation
import WinSDK

enum EditorBlenderMCPExport {
    static let alias = "blender.create_and_export_glb"
    static let remoteTool = "execute_blender_code"
    private static let byteLimit = 128 * 1_024 * 1_024

    static let toolDefinition: EditorCloudValue = [
        "tool": .string(alias),
        "description": "Create a static model in the local Blender and export a self-contained GLB to project Downloads.",
        "inputSchema": [
            "type": "object", "required": ["name", "parts"], "additionalProperties": false, "properties": [
                "name": ["type": "string", "minLength": 1, "maxLength": 64],
                "parts": [
                    "type": "array", "minItems": 1, "maxItems": 24, "items": [
                        "type": "object", "additionalProperties": false, "required": ["shape", "size", "position", "color"], "properties": [
                            "shape": ["enum": ["box", "cylinder", "cone", "sphere"]],
                            "size": vectorSchema(min: .number(0.001), max: 100, description: "Dimensions in meters along Blender X, Y, and Z."),
                            "position": vectorSchema(min: -100, max: 100, description: "Center in meters, with Blender Z up."),
                            "rotation": vectorSchema(min: -360, max: 360, description: "Optional XYZ Euler angles in degrees."),
                            "color": vectorSchema(min: 0, max: 1, description: "Linear RGB values.")
                        ]
                    ]
                ]
            ]
        ]
    ]

    private static func vectorSchema(min: EditorCloudValue, max: EditorCloudValue, description: String) -> EditorCloudValue {
        [
            "type": "array", "minItems": 3, "maxItems": 3, "description": .string(description),
            "items": ["type": "number", "minimum": min, "maximum": max]
        ]
    }

    static func recipe(from arguments: EditorCloudValue) throws -> Recipe {
        guard arguments["tool"].string == alias else { throw Failure.recipe }
        return try Recipe(arguments["input"])
    }

    struct Recipe: Encodable, Sendable {
        let name: String
        let parts: [Part]

        struct Part: Encodable, Sendable {
            let shape: String
            let size: [Double]
            let position: [Double]
            let rotation: [Double]
            let color: [Double]

            init(_ value: EditorCloudValue) throws {
                guard Set(value.object.keys).isSubset(of: ["shape", "size", "position", "rotation", "color"]),
                      let shape = value["shape"].string, ["box", "cylinder", "cone", "sphere"].contains(shape) else { throw Failure.recipe }
                self.shape = shape
                size = try Self.vector(value["size"], range: 0.001...100)
                position = try Self.vector(value["position"], range: -100...100)
                rotation = try value.object["rotation"].map { try Self.vector($0, range: -360...360) } ?? [0, 0, 0]
                color = try Self.vector(value["color"], range: 0...1)
            }

            private static func vector(_ value: EditorCloudValue, range: ClosedRange<Double>) throws -> [Double] {
                guard value.array.count == 3 else { throw Failure.recipe }
                return try value.array.map { entry in
                    switch entry {
                    case .number, .integer:
                        guard range.contains(entry.seconds) else { throw Failure.recipe }
                        return entry.seconds
                    default: throw Failure.recipe
                    }
                }
            }
        }

        init(_ input: EditorCloudValue) throws {
            guard Set(input.object.keys) == ["name", "parts"],
                  let name = input["name"].string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  (1...64).contains(name.utf8.count), name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  (1...24).contains(input["parts"].array.count) else { throw Failure.recipe }
            self.name = name
            parts = try input["parts"].array.map(Part.init)
        }
    }

    static func export(
        _ recipe: Recipe,
        in project: URL,
        using server: EditorWindowsLocalMCP,
        expectedRevision: UInt64,
        isAuthorized: @Sendable () async -> Bool
    ) async throws -> String {
        guard await isAuthorized() else { throw Failure.authorization }
        let root = project.resolvingSymlinksInPath().standardizedFileURL
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        let exports = downloads.appendingPathComponent("Blender", isDirectory: true)
        let job = Foundation.UUID().uuidString.lowercased()
        let directory = exports.appendingPathComponent(job, isDirectory: true)
        try ensureDirectory(downloads)
        try ensureDirectory(exports)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let stage = directory.appendingPathComponent("Export.pending.glb")
        let checked = directory.appendingPathComponent(".\(Foundation.UUID().uuidString).glb")
        let result = directory.appendingPathComponent("Model.glb")
        let receipt = directory.appendingPathComponent("Job.json")
        let tree = [downloads, exports, directory]
        var published = false
        defer {
            if tree.allSatisfy({ isDirect($0, directory: true) }) {
                // Remove only known job files. A server may have created additional files.
                if isDirect(stage, directory: false) { try? FileManager.default.removeItem(at: stage) }
                if isDirect(checked, directory: false) { try? FileManager.default.removeItem(at: checked) }
                if !published {
                    if isDirect(receipt, directory: false) { try? FileManager.default.removeItem(at: receipt) }
                    _ = RemoveDirectoryW(Array(directory.path.utf16) + [0])
                }
            }
        }
        struct Payload: Encodable {
            let recipe: Recipe
            let path: String
        }
        let data = try JSONEncoder().encode(Payload(recipe: recipe, path: stage.path))
        let code = script.replacingOccurrences(of: "ADASTUDIO_PAYLOAD", with: data.base64EncodedString())
        try Task.checkCancellation()
        guard await isAuthorized(), tree.allSatisfy({ isDirect($0, directory: true) }) else { throw Failure.authorization }
        _ = try await server.call(remoteTool, arguments: ["code": .string(code)], expectedRevision: expectedRevision)
        try Task.checkCancellation()
        guard await isAuthorized(), tree.allSatisfy({ isDirect($0, directory: true) }) else { throw Failure.authorization }
        let bytes = try validatedBytes(at: stage)
        try Task.checkCancellation()
        guard await isAuthorized(), tree.allSatisfy({ isDirect($0, directory: true) }) else { throw Failure.authorization }
        try bytes.write(to: checked, options: .withoutOverwriting)
        try EditorBlenderSceneJob.recordExport(bytes, project: root, id: job, name: recipe.name)
        try FileManager.default.moveItem(at: checked, to: result)
        published = true
        return "Downloads/Blender/\(job)/Model.glb"
    }

    static func ensureDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        guard isDirect(url, directory: true) else { throw Failure.artifact }
    }

    static func isDirect(_ url: URL, directory: Bool) -> Bool {
        let attributes = GetFileAttributesW(Array(url.path.utf16) + [0])
        return attributes != DWORD.max && attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 &&
            (attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0) == directory
    }

    static func removeDirectFile(_ url: URL) {
        if isDirect(url, directory: false) { _ = DeleteFileW(Array(url.path.utf16) + [0]) }
    }

    static func validatedBytes(at url: URL) throws -> Data {
        guard isDirect(url, directory: false),
              let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              (20...byteLimit).contains(size) else { throw Failure.artifact }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard let data = try file.read(upToCount: size + 1), data.count == size,
              data[8..<12].enumerated().reduce(0, { $0 | (Int($1.element) << ($1.offset * 8)) }) == size else { throw Failure.artifact }
        do {
            try EditorModelAssetImporter.requireSelfContainedGLB(data)
            let decoded = try NativeGLTFLoader().load(data: data, allowExternalResources: false)
            guard decoded.scenes.contains(where: { !$0.isEmpty }), !decoded.meshes.isEmpty, decoded.meshes.allSatisfy({ mesh in
                !mesh.primitives.isEmpty && mesh.primitives.allSatisfy { primitive in
                    guard let positions = primitive.attributes[.position] else {
                        return false
                    }
                    return positions.componentCount == 3 && positions.count >= 3 && positions.values.allSatisfy(\.isFinite)
                }
            }) else { throw Failure.artifact }
            return data
        } catch { throw Failure.artifact }
    }

    enum Failure: Equatable, LocalizedError {
        case recipe, authorization, artifact

        var errorDescription: String? {
            switch self {
            case .recipe: "The Blender model recipe is invalid. Use supported shapes, sizes and colors."
            case .authorization: "The Blender connection or the open project changed. Start the request again."
            case .artifact: "Blender did not return a valid self-contained GLB in the project Downloads folder."
            }
        }
    }

    private static let script = #"""
    import base64
    import json
    import math

    import bmesh
    import bpy

    def export_model(payload):
        recipe = payload["recipe"]
        scene = bpy.data.scenes.new("Ada Studio Export")
        objects, meshes, materials = [], [], []
        try:
            for index, part in enumerate(recipe["parts"], 1):
                name = f'{recipe["name"]} {index}'
                mesh = bpy.data.meshes.new(name)
                meshes.append(mesh)
                geometry = bmesh.new()
                try:
                    shape = part["shape"]
                    if shape == "box":
                        bmesh.ops.create_cube(geometry, size=1.0)
                    elif shape == "sphere":
                        bmesh.ops.create_uvsphere(geometry, u_segments=24, v_segments=12, radius=0.5)
                    else:
                        top_radius = 0.5 if shape == "cylinder" else 0.12
                        bmesh.ops.create_cone(geometry, cap_ends=True, cap_tris=False, segments=32,
                                              radius1=0.5, radius2=top_radius, depth=1.0)
                    geometry.normal_update()
                    geometry.to_mesh(mesh)
                finally:
                    geometry.free()
                material = bpy.data.materials.new(name)
                materials.append(material)
                material.diffuse_color = (*part["color"], 1.0)
                material.use_nodes = True
                shader = next(node for node in material.node_tree.nodes if node.type == "BSDF_PRINCIPLED")
                next(s for s in shader.inputs if s.identifier == "Base Color").default_value = material.diffuse_color
                next(s for s in shader.inputs if s.identifier == "Roughness").default_value = 0.72
                mesh.materials.append(material)
                obj = bpy.data.objects.new(name, mesh)
                objects.append(obj)
                scene.collection.objects.link(obj)
                obj.scale = part["size"]
                obj.location = part["position"]
                obj.rotation_euler = tuple(math.radians(value) for value in part["rotation"])
            with bpy.context.temp_override(scene=scene, view_layer=scene.view_layers[0], collection=scene.collection):
                outcome = bpy.ops.export_scene.gltf(filepath=payload["path"], export_format="GLB", use_active_scene=True,
                                                   export_animations=False, export_cameras=False, export_lights=False)
            if "FINISHED" not in outcome:
                raise RuntimeError("GLB export did not finish")
        finally:
            for obj in objects:
                bpy.data.objects.remove(obj, do_unlink=True)
            for mesh in meshes:
                bpy.data.meshes.remove(mesh)
            for material in materials:
                bpy.data.materials.remove(material)
            bpy.data.scenes.remove(scene)

    export_model(json.loads(base64.b64decode("ADASTUDIO_PAYLOAD")))
    """#
}
#endif
