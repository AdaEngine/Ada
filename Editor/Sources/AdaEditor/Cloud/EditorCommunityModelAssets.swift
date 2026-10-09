import AdaEngine
import Foundation

/// Checks model metadata before native import allocates decoded vertex/animation arrays.
enum EditorCommunityModelAssets {
    static func validate(in directory: URL) throws {
        let assets = directory.appendingPathComponent("Assets").resolvingSymlinksInPath().standardizedFileURL
        guard let files = FileManager.default.enumerator(at: assets, includingPropertiesForKeys: nil) else { return }
        for case let file as URL in files where ["glb", "gltf"].contains(file.pathExtension.lowercased()) {
            let data = try Data(contentsOf: file)
            let json = try document(data)
            guard (json["asset"] as? [String: Any])?["version"] as? String == "2.0" else { throw invalid }
            for (name, maximum) in [("nodes", 2048), ("meshes", 256), ("materials", 256), ("textures", 512), ("skins", 128), ("animations", 128), ("accessors", 4096), ("bufferViews", 4096), ("images", 512), ("buffers", 512)] {
                guard json[name] == nil || (json[name] as? [Any]).map({ $0.count <= maximum }) == true else { throw invalid }
            }
            var total = 0
            for accessor in json["accessors"] as? [[String: Any]] ?? [] {
                guard let count = accessor["count"] as? Int, count >= 0, count <= 1_000_000 else { throw invalid }
                let width = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT2": 4, "MAT3": 9, "MAT4": 16][accessor["type"] as? String ?? ""] ?? 16
                total += count * width
                guard total <= 4_000_000 else { throw invalid }
                if let sparse = accessor["sparse"] as? [String: Any], let amount = sparse["count"] as? Int, amount < 0 || amount > count { throw invalid }
            }
            try validateNumbers(json)
            let nodes = json["nodes"] as? [[String: Any]] ?? []
            var visiting = Set<Int>(), heights: [Int: Int] = [:]
            func visit(_ index: Int, depth: Int) throws -> Int {
                guard nodes.indices.contains(index), depth <= 128, !visiting.contains(index) else { throw invalid }
                if let height = heights[index] { return height }
                visiting.insert(index)
                var height = 0
                for child in nodes[index]["children"] as? [Int] ?? [] {
                    height = max(height, 1 + (try visit(child, depth: depth + 1)))
                }
                guard height <= 128 else { throw invalid }
                visiting.remove(index); heights[index] = height
                return height
            }
            for index in nodes.indices { _ = try visit(index, depth: 0) }
            for element in (json["buffers"] as? [[String: Any]] ?? []) + (json["images"] as? [[String: Any]] ?? []) {
                guard let uri = element["uri"] as? String else { continue }
                if uri.hasPrefix("data:") {
                    guard uri.utf8.count <= 24 * 1024 * 1024 else { throw invalid }
                    continue
                }
                let decoded = uri.removingPercentEncoding ?? uri
                let target = file.deletingLastPathComponent().appendingPathComponent(decoded).resolvingSymlinksInPath().standardizedFileURL
                guard !decoded.hasPrefix("/"), !decoded.contains(":"), !decoded.contains("\\"), !decoded.contains("?"), !decoded.contains("#"),
                      target.path.hasPrefix(assets.path + "/"), FileManager.default.fileExists(atPath: target.path) else { throw invalid }
            }
            // Real CPU importer validation catches bad indices, formats and animation/skin bindings.
            _ = try NativeGLTFLoader().load(data: data, baseURL: file.deletingLastPathComponent())
        }
    }

    private static var invalid: Error { EditorCommunityPackageManifest.Failure.invalidPackage }

    private static func validateNumbers(_ value: Any) throws {
        if let object = value as? [String: Any] {
            for (name, item) in object {
                if ["byteOffset", "byteLength", "byteStride"].contains(name) {
                    guard let amount = item as? Int, amount >= 0, amount <= 16 * 1024 * 1024 else { throw invalid }
                }
                try validateNumbers(item)
            }
        } else if let array = value as? [Any] { for item in array { try validateNumbers(item) } }
    }

    private static func document(_ data: Data) throws -> [String: Any] {
        var payload = data
        if data.prefix(4) == Data("glTF".utf8) {
            func integer(_ offset: Int) throws -> Int {
                guard offset >= 0, offset + 4 <= data.count else { throw invalid }
                return Int(data[offset]) | Int(data[offset + 1]) << 8 | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
            }
            guard try integer(4) == 2, try integer(8) == data.count else { throw invalid }
            var cursor = 12, found: Data?
            while cursor < data.count {
                let length = try integer(cursor), type = try integer(cursor + 4)
                cursor += 8
                guard length % 4 == 0, length <= data.count - cursor else { throw invalid }
                if type == 0x4E4F534A {
                    guard found == nil else { throw invalid }
                    found = data.subdata(in: cursor..<(cursor + length))
                }
                cursor += length
            }
            guard let found else { throw invalid }
            payload = found
        }
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else { throw invalid }
        return object
    }
}
