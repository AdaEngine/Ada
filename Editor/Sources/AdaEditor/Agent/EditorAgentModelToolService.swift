import AdaEngine
import Foundation
import Math
import MCP

/// CPU import inspection; never creates GPU resources or changes the global loader.
@MainActor
final class EditorAgentModelToolService {
    private let projectURL: URL
    private let maximumBytes = 128 * 1024 * 1024

    init(projectURL: URL) {
        self.projectURL = projectURL.resolvingSymlinksInPath().standardizedFileURL
    }

    static var capabilities: [String: Any] {
        [
            "formats": ["glb", "gltf"],
            "tools": ["editor.model.inspect", "editor.model.validate", "editor.model.import", "editor.model.material.edit", "editor.model.texture.assign"],
            "inspection": "CPU native glTF import; rest-pose scene bounds, geometry, PBR slots, hierarchy, skins and named clips",
            "verification": "Import/profile validation only. Use visible Play and a completed frame capture for rendering; exercise named clips for animation playback.",
            "limits": ["128 MiB model and local dependencies combined", "128 joints per skin", "glTF primitive topologies", "UV0/UV1", "one set of four skin influences"],
            "unavailable": ["Blender execution", "3D model generation", "rig editing", "skeletal clip authoring", "Draco/Meshopt/KTX2 decoding"],
        ]
    }

    func execute(name: String, arguments: [String: Value]) throws -> [String: Any] {
        if name == "editor.model.import" {
            let source = try resolve(required("source", arguments), importing: true)
            _ = try inspect(source, importing: true)
            let destination = try resolve(required("destination", arguments), directory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let imported = try EditorModelAssetImporter.copy(source, to: destination)
            var result = try inspect(imported)
            result["imported"] = true
            result["requiresRebuild"] = true
            return result
        }
        let url = try resolve(required("path", arguments))
        if name == "editor.model.material.edit" {
            _ = try inspect(url)
            return try editMaterial(url, arguments: arguments)
        }
        guard ["editor.model.inspect", "editor.model.validate"].contains(name) else { throw Failure("Unknown model tool: \(name)") }
        return try inspect(url)
    }

    private func inspect(_ url: URL, importing: Bool = false) throws -> [String: Any] {
        let data = try boundedData(url)
        let root = try document(data, at: url)
        let dependencies = try preflight(root, at: url, modelBytes: data.count, importing: importing)
        let imported = try NativeGLTFLoader().load(data: data, baseURL: url.deletingLastPathComponent())
        let bounds = try sceneBounds(imported)
        guard imported.skins.allSatisfy({ $0.joints.count <= 128 }) else { throw Failure("AdaEngine supports at most 128 joints per skin.") }
        for image in imported.images {
            guard let bytes = image.data, bytes.count <= 24 * 1024 * 1024 else { throw Failure("Model image is missing or exceeds 24 MiB.") }
            let decoded = try Image.decode(from: bytes, fileExtension: image.uri?.pathExtension)
            guard decoded.width <= 16384, decoded.height <= 16384, decoded.width * decoded.height <= 16_777_216 else {
                throw Failure("Model image exceeds 16 million pixels.")
            }
        }
        var vertexCount = 0
        var triangleCount = 0
        for mesh in imported.meshes {
            for primitive in mesh.primitives {
                guard let positions = primitive.attributes[.position], positions.componentCount == 3,
                      !positions.values.isEmpty, positions.values.allSatisfy(\.isFinite) else { throw Failure("Expected finite POSITION geometry.") }
                let count = primitive.indices?.count ?? positions.count
                guard primitive.indices?.allSatisfy({ Int($0) < positions.count }) ?? true else { throw Failure("Primitive indices are invalid.") }
                switch primitive.mode {
                case .triangles:
                    guard count >= 3, count.isMultiple(of: 3) else { throw Failure("Invalid triangle index count.") }
                    triangleCount += count / 3
                case .triangleStrip, .triangleFan:
                    guard count >= 3 else { throw Failure("Invalid triangle strip/fan index count.") }
                    triangleCount += count - 2
                case .lines:
                    guard count >= 2, count.isMultiple(of: 2) else { throw Failure("Invalid line index count.") }
                case .lineLoop, .lineStrip:
                    guard count >= 2 else { throw Failure("Invalid line loop/strip index count.") }
                case .points:
                    guard count > 0 else { throw Failure("Empty point primitive.") }
                }
                if let index = primitive.materialIndex, !imported.materials.indices.contains(index) { throw Failure("Primitive references a missing material.") }
                for (attribute, accessor) in primitive.attributes {
                    guard accessor.count == positions.count, accessor.values.allSatisfy(\.isFinite) else { throw Failure("Vertex attributes have invalid lengths or values.") }
                    if case let .texCoord(index) = attribute, index != 0 && index != 1 { throw Failure("AdaEngine supports UV0 and UV1.") }
                }
                vertexCount += positions.count
            }
        }
        let materials = imported.materials.enumerated().prefix(200).map { index, material -> [String: Any] in
            [
                "index": index, "name": material.name ?? "Material \(index)",
                "baseColorFactor": [material.baseColorFactor.x, material.baseColorFactor.y, material.baseColorFactor.z, material.baseColorFactor.w],
                "metallicFactor": material.metallicFactor, "roughnessFactor": material.roughnessFactor,
                "emissiveFactor": [material.emissiveFactor.x, material.emissiveFactor.y, material.emissiveFactor.z],
                "alphaMode": material.alphaMode.rawValue, "doubleSided": material.doubleSided,
                "textureSlots": [
                    "baseColor": material.baseColorTextureIndex.map { $0 as Any } ?? NSNull(),
                    "normal": material.normalTextureIndex.map { $0 as Any } ?? NSNull(),
                    "metallicRoughness": material.metallicRoughnessTextureIndex.map { $0 as Any } ?? NSNull(),
                    "occlusion": material.occlusionTextureIndex.map { $0 as Any } ?? NSNull(),
                    "emissive": material.emissiveTextureIndex.map { $0 as Any } ?? NSNull(),
                ],
                "textureCoordinates": material.textureCoordinates,
            ]
        }
        return [
            "path": relative(url), "assetReference": reference(url), "valid": true,
            "verification": "native_gltf_import_and_profile", "rendered": false, "animationPlaybackVerified": false,
            "counts": [
                "nodes": imported.nodes.count, "meshes": imported.meshes.count, "materials": imported.materials.count,
                "textures": imported.textures.count, "skins": imported.skins.count, "animations": imported.animations.count,
                "vertices": vertexCount, "triangles": triangleCount,
            ],
            "bounds": bounds, "boundsPose": "rest; selected scene; original model scale; excludes animated displacement",
            "materials": materials,
            "meshes": imported.meshes.enumerated().prefix(200).map { index, mesh in
                [
                    "index": index, "name": mesh.name ?? "Mesh \(index)", "primitiveCount": mesh.primitives.count,
                    "primitives": mesh.primitives.prefix(200).map { primitive in
                        [
                            "mode": primitive.mode.rawValue, "vertices": primitive.attributes[.position]?.count ?? 0,
                            "indices": primitive.indices?.count ?? 0, "material": primitive.materialIndex.map { $0 as Any } ?? NSNull(),
                        ] as [String: Any]
                    },
                ] as [String: Any]
            },
            "nodes": imported.nodes.enumerated().prefix(200).map { index, node in
                [
                    "index": index, "name": node.name ?? "Node \(index)", "children": Array(node.children.prefix(200)),
                    "mesh": node.meshIndex.map { $0 as Any } ?? NSNull(), "skin": node.skinIndex.map { $0 as Any } ?? NSNull(),
                ] as [String: Any]
            },
            "skins": imported.skins.enumerated().prefix(200).map { index, skin in
                ["index": index, "name": skin.name ?? "Skin \(index)", "joints": skin.joints, "jointCount": skin.joints.count] as [String: Any]
            },
            "animations": imported.animations.enumerated().prefix(200).map { index, clip in
                [
                    "index": index, "name": clip.name ?? "Animation \(index)", "duration": clip.duration, "channels": clip.channels.count,
                    "interpolations": Set(clip.samplers.map { $0.interpolation.rawValue }).sorted(),
                ] as [String: Any]
            },
            "textures": imported.textures.enumerated().prefix(200).map { index, texture in
                ["index": index, "image": texture.source, "sampler": texture.sampler.map { $0 as Any } ?? NSNull()] as [String: Any]
            },
            "images": imported.images.enumerated().prefix(200).map { index, image in
                ["index": index, "path": image.uri.map(relative) ?? "embedded", "bytes": image.data?.count ?? 0] as [String: Any]
            },
            "dependencies": Array(dependencies.prefix(200)),
            "truncated": [
                imported.nodes.count, imported.meshes.count, imported.materials.count, imported.animations.count,
                imported.textures.count, imported.images.count, dependencies.count,
            ].contains { $0 > 200 } || imported.nodes.contains { $0.children.count > 200 } || imported.meshes.contains { $0.primitives.count > 200 },
        ]
    }

    private func sceneBounds(_ model: GLTFImportResult) throws -> [String: Any] {
        var parents: [Int: Int] = [:]
        for (index, node) in model.nodes.enumerated() {
            for child in node.children {
                guard model.nodes.indices.contains(child), parents[child] == nil else { throw Failure("Invalid or multiply parented model node.") }
                parents[child] = index
            }
            if let mesh = node.meshIndex, !model.meshes.indices.contains(mesh) { throw Failure("Node references a missing mesh.") }
        }
        // Validate every node, including nodes outside the selected scene, without recursive traversal.
        var transforms: [Int: Transform3D] = [:]
        for index in model.nodes.indices {
            var chain: [Int] = []
            var visiting = Set<Int>()
            var current: Int? = index
            while let node = current, transforms[node] == nil {
                guard visiting.insert(node).inserted else { throw Failure("Model hierarchy contains a cycle.") }
                chain.append(node)
                current = parents[node]
            }
            for node in chain.reversed() {
                let parentTransform = parents[node].flatMap { transforms[$0] } ?? .identity
                transforms[node] = parentTransform * model.nodes[node].transform
            }
        }
        if let scene = model.defaultScene, !model.scenes.indices.contains(scene) { throw Failure("Invalid default scene.") }
        for roots in model.scenes {
            guard roots.allSatisfy({ model.nodes.indices.contains($0) && parents[$0] == nil }) else { throw Failure("Invalid scene root.") }
        }
        let roots = model.scenes.isEmpty ? model.nodes.indices.filter { parents[$0] == nil } : model.scenes[model.defaultScene ?? 0]
        var pending = roots
        var visited = Set<Int>()
        var minimum = Vector3(Float.greatestFiniteMagnitude)
        var maximum = Vector3(-Float.greatestFiniteMagnitude)
        var hasGeometry = false
        while let index = pending.popLast() {
            guard visited.insert(index).inserted else { continue }
            let node = model.nodes[index]
            pending.append(contentsOf: node.children)
            guard let mesh = node.meshIndex, let transform = transforms[index] else { continue }
            for primitive in model.meshes[mesh].primitives {
                guard let positions = primitive.attributes[.position], positions.componentCount == 3 else { continue }
                for offset in stride(from: 0, to: positions.values.count, by: 3) {
                    let point = transform * Vector4(positions.values[offset], positions.values[offset + 1], positions.values[offset + 2], 1)
                    guard [point.x, point.y, point.z, point.w].allSatisfy(\.isFinite), abs(point.w - 1) < 0.001 else { throw Failure("Invalid model transform.") }
                    minimum = Vector3(min(minimum.x, point.x), min(minimum.y, point.y), min(minimum.z, point.z))
                    maximum = Vector3(max(maximum.x, point.x), max(maximum.y, point.y), max(maximum.z, point.z))
                    hasGeometry = true
                }
            }
        }
        guard hasGeometry else {
            return ["empty": true]
        }
        let size = maximum - minimum
        return ["min": [minimum.x, minimum.y, minimum.z], "max": [maximum.x, maximum.y, maximum.z], "size": [size.x, size.y, size.z]]
    }

    private func preflight(_ root: [String: Any], at url: URL, modelBytes: Int, importing: Bool) throws -> [String] {
        guard (root["asset"] as? [String: Any])?["version"] as? String == "2.0" else { throw Failure("Expected glTF 2.0.") }
        for key in ["nodes", "meshes", "materials", "skins", "animations", "textures", "images", "accessors", "bufferViews"] {
            guard (root[key] as? [Any] ?? []).count <= 10000 else { throw Failure("Model has too many \(key).") }
        }
        let accessors = root["accessors"] as? [[String: Any]] ?? []
        var costs: [Int] = []
        for accessor in accessors {
            guard let count = accessor["count"] as? Int, (0...2_000_000).contains(count) else { throw Failure("Accessor count exceeds the inspection budget.") }
            costs.append(count * 16)
        }
        var elements = 0
        func charge(_ index: Int) throws {
            guard costs.indices.contains(index) else { throw Failure("Invalid accessor reference.") }
            elements += costs[index]
            guard elements <= 32_000_000 else { throw Failure("Repeated accessor decoding exceeds the inspection budget.") }
        }
        for mesh in root["meshes"] as? [[String: Any]] ?? [] {
            let primitives = mesh["primitives"] as? [[String: Any]] ?? []
            guard primitives.count <= 10000 else { throw Failure("Too many mesh primitives.") }
            for primitive in primitives {
                if let mode = primitive["mode"] as? Int, !(0...6).contains(mode) { throw Failure("Invalid primitive mode.") }
                for index in (primitive["attributes"] as? [String: Int] ?? [:]).values { try charge(index) }
                if let index = primitive["indices"] as? Int { try charge(index) }
            }
        }
        for animation in root["animations"] as? [[String: Any]] ?? [] {
            for sampler in animation["samplers"] as? [[String: Any]] ?? [] {
                if let index = sampler["input"] as? Int { try charge(index) }
                if let index = sampler["output"] as? Int { try charge(index) }
            }
        }
        for skin in root["skins"] as? [[String: Any]] ?? [] {
            if let index = skin["inverseBindMatrices"] as? Int { try charge(index) }
        }
        var bytes = modelBytes
        var dependencies = Set<String>()
        for resource in (root["buffers"] as? [[String: Any]] ?? []) + (root["images"] as? [[String: Any]] ?? []) {
            guard let uri = resource["uri"] as? String, !uri.hasPrefix("data:") else { continue }
            guard let parsed = URL(string: uri), parsed.scheme == nil, parsed.host == nil, parsed.query == nil, parsed.fragment == nil,
                  let path = uri.removingPercentEncoding, !path.hasPrefix("/"), !path.hasPrefix("~") else { throw Failure("Model dependencies must be local relative files.") }
            let dependency = url.deletingLastPathComponent().appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
            guard dependency.path.hasPrefix(projectURL.path + "/") else { throw Failure("Model dependency escapes the project.") }
            let checked = try resolve(relative(dependency), importing: importing, model: false)
            let name = relative(checked)
            dependencies.insert(name)
            let info = try checked.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard info.isRegularFile == true, let size = info.fileSize, size <= maximumBytes - bytes else {
                throw Failure("Model dependency reads exceed 128 MiB or are not regular files.")
            }
            bytes += size
        }
        return dependencies.sorted()
    }

    private func editMaterial(_ url: URL, arguments: [String: Value]) throws -> [String: Any] {
        guard let index = arguments["material"]?.intValue, index >= 0,
              let patch = try JSONSerialization.jsonObject(with: Data(required("settingsJSON", arguments).utf8)) as? [String: Any], !patch.isEmpty else {
            throw Failure("Provide a material index and a nonempty settingsJSON object.")
        }
        let allowed: Set<String> = ["baseColorFactor", "metallicFactor", "roughnessFactor", "emissiveFactor", "alphaMode", "alphaCutoff", "doubleSided"]
        guard Set(patch.keys).isSubset(of: allowed) else { throw Failure("Unsupported material field.") }
        let original = try boundedData(url)
        var root = try document(original, at: url)
        guard var materials = root["materials"] as? [[String: Any]], materials.indices.contains(index) else { throw Failure("Material index is missing.") }
        var material = materials[index]
        var pbr = material["pbrMetallicRoughness"] as? [String: Any] ?? [:]
        for (key, value) in patch {
            if ["baseColorFactor", "metallicFactor", "roughnessFactor"].contains(key) { pbr[key] = value } else { material[key] = value }
        }
        material["pbrMetallicRoughness"] = pbr
        materials[index] = material
        root["materials"] = materials
        let json = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        // Native material decoding rejects out-of-range factors and invalid enum/type values before writing.
        _ = try NativeGLTFLoader().load(data: encoded(json, original: original, url: url), baseURL: url.deletingLastPathComponent())
        guard try Data(contentsOf: url) == original else { throw Failure("Model changed during editing; inspect it again.") }
        try encoded(json, original: original, url: url).write(to: url, options: .atomic)
        return ["path": relative(url), "material": index, "requiresRebuild": true, "preservedGeometry": true]
    }

    private func encoded(_ json: Data, original: Data, url: URL) throws -> Data {
        url.pathExtension.lowercased() == "glb"
            ? try EditorAgentModelTextureTools.encodeGLB(json: json, preserving: Array(EditorAgentModelTextureTools.decodeGLB(original).dropFirst())) : json
    }

    private func document(_ data: Data, at url: URL) throws -> [String: Any] {
        let json = url.pathExtension.lowercased() == "glb" ? try EditorAgentModelTextureTools.decodeGLB(data).first?.data ?? Data() : data
        guard json.count <= 16 * 1024 * 1024, let root = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw Failure("Expected a model JSON object up to 16 MiB.")
        }
        return root
    }

    private func boundedData(_ url: URL) throws -> Data {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, let size = info.fileSize, size <= maximumBytes else { throw Failure("Expected a regular model file up to 128 MiB.") }
        return try Data(contentsOf: url)
    }

    private func resolve(_ path: String, importing: Bool = false, directory: Bool = false, model: Bool = true) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { throw Failure("Use a project-relative path.") }
        let url = projectURL.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        let roots = [try assetsURL()] + (importing ? [projectURL.appendingPathComponent("Downloads")] : [])
        guard roots.contains(where: { root in
            let resolved = root.resolvingSymlinksInPath().standardizedFileURL
            return resolved.path.hasPrefix(projectURL.path + "/") && (url == resolved && directory || url.path.hasPrefix(resolved.path + "/"))
        }) else { throw Failure("Keep model files inside project Assets or Downloads; destinations must be inside Assets.") }
        if !directory, model, !EditorModelResource.extensions.contains(url.pathExtension.lowercased()) {
            throw Failure("Expected a .glb or .gltf model.")
        }
        return url
    }

    private func assetsURL() throws -> URL {
        let project = try ProjectSystem.loadProject(at: projectURL)
        return projectURL.appendingPathComponent(project.paths.assets ?? "Assets").resolvingSymlinksInPath().standardizedFileURL
    }

    private func relative(_ url: URL) -> String { String(url.path.dropFirst(projectURL.path.count + 1)) }
    private func reference(_ url: URL) -> String {
        guard let root = try? assetsURL(), url.path.hasPrefix(root.path + "/") else {
            return ""
        }
        return "@res://" + String(url.path.dropFirst(root.path.count + 1))
    }
    private func required(_ key: String, _ arguments: [String: Value]) throws -> String {
        guard let value = arguments[key]?.stringValue, !value.isEmpty else { throw Failure("Missing \(key).") }
        return value
    }
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
