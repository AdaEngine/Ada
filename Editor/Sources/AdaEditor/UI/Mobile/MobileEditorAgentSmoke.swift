#if DEBUG && os(iOS) && targetEnvironment(simulator)
    import Foundation
    import MCP
    import Protocols
    import SloppyRuntime

    /// Repeatable on-device tool smoke without provider credentials or changes to user projects.
    @MainActor
    enum MobileEditorAgentSmoke {
        static func run() async {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentToolSmoke-\(UUID())")
            var checks: [[String: Any]] = []
            do {
                let definitions = try MobileEditorAgentToolBridge.definitions()
                let example = EditorAgentKnowledge.examples[0]
                for (path, content) in example.files {
                    let url = root.appendingPathComponent(path)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try content.write(to: url, atomically: true, encoding: .utf8)
                }
                let service = EditorMobileAgentToolService(projectURL: root)
                defer { service.finish() }
                let executor = SloppyWorkspaceToolExecutor(
                    rootURL: root,
                    build: {
                        await MainActor.run {
                            let value = service.build()
                            return SloppyBuildResult(ok: value.ok, summary: value.payload)
                        }
                    },
                    additionalToolNames: Set(definitions.map(\.name)),
                    additionalToolHandler: { await MobileEditorAgentToolBridge.invoke($0, service: service) }
                )
                _ = SloppyRuntimeHost(additionalTools: definitions)
                for (name, arguments) in [
                    ("editor.project.context", [:]),
                    ("editor.docs.search", ["query": JSONValue.string("AdaScript")]),
                    ("editor.docs.read", ["id": .string("AdaScripting")]),
                    ("editor.api.describe", ["query": .string("Input")]),
                    ("editor.components.describe", ["query": .string("Transform")]),
                    ("editor.examples.read", ["id": .string("keyboard-movement")]),
                    ("editor.texture.render", ["path": .string("Assets/Textures/sheet.png"), "specJSON": .string("{\"width\":64,\"height\":32,\"pattern\":\"checker\",\"cellSize\":16}")]),
                    ("editor.atlas.write", ["path": .string("Assets/Textures/test.atlas"), "descriptorJSON": .string("{\"images\":[{\"path\":\"sheet.png\",\"key\":\"terrain\"}],\"sampler\":\"nearest\"}")]),
                    ("editor.atlas.pack", ["path": .string("Assets/Textures/test.atlas"), "previewPath": .string("Assets/Textures/packed.png")]),
                    ("editor.tileset.create", ["path": .string("Assets/Tiles/test.tileset"), "image": .string("Assets/Textures/sheet.png"), "tileWidth": .number(16), "tileHeight": .number(16)]),
                    ("editor.tilemap.write", ["path": .string("Assets/Tiles/test.tilemap"), "resourceJSON": .string("{\"atlasColors\":[],\"cells\":[],\"tileSetReference\":\"@res://Tiles/test.tileset\"}")]),
                    ("editor.tilemap.edit", ["path": .string("Assets/Tiles/test.tilemap"), "operationsJSON": .string("[{\"op\":\"fill\",\"x\":0,\"y\":0,\"width\":2,\"height\":2,\"tile\":3}]")]),
                    ("editor.asset.validate", ["path": .string("Assets/Tiles/test.tilemap")]),
                    ("editor.gravity.diagnostics", [:]),
                    ("editor.build", [:]),
                    ("editor.runtime.start", [:]),
                    ("editor.runtime.step", ["frames": .number(6), "keys": .array([.string("d")])]),
                    ("editor.runtime.step", ["frames": .number(6), "keys": .array([])]),
                    ("editor.output.read", [:]),
                ] {
                    let value = await executor.invoke(.init(tool: name, arguments: arguments))
                    checks.append(["tool": name, "ok": value.ok, "result": try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))])
                }
                if CommandLine.arguments.contains("--mobile-agent-web-smoke") {
                    for (name, arguments) in [
                        ("editor.web.search", ["query": JSONValue.string("AdaEngine Swift")]),
                        ("editor.web.fetch", ["url": .string("https://example.com")]),
                        ("editor.web.download", ["url": .string("https://example.com"), "destination": .string("Downloads/example.html")]),
                    ] {
                        let value = await executor.invoke(.init(tool: name, arguments: arguments))
                        checks.append(["tool": name, "ok": value.ok, "result": try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))])
                    }
                    let saved = try String(contentsOf: root.appendingPathComponent("Downloads/example.html"), encoding: .utf8)
                    checks.append(["tool": "web.download.bytes", "ok": saved.contains("Example Domain")])
                }
                let valid = await service.validatePrototype()
                checks.append(["tool": "completion.valid", "ok": valid.ok, "result": valid.payload])
                _ = await executor.invoke(.init(tool: "files.write", arguments: ["path": .string("Sources/Game.ada"), "content": .string("@system class Broken {")]))
                let invalid = await executor.invoke(.init(tool: "editor.build", arguments: [:]))
                checks.append(["tool": "build.rejects_invalid_source", "ok": !invalid.ok, "result": invalid.error?.message ?? ""])
                let report: [String: Any] = ["ok": checks.allSatisfy { $0["ok"] as? Bool == true }, "toolCount": definitions.count, "checks": checks]
                print("MOBILE_AGENT_SMOKE_REPORT " + (try EditorAgentToolEncoding.string(JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]))))
            } catch {
                print(
                    "MOBILE_AGENT_SMOKE_REPORT "
                        + ((try? EditorAgentToolEncoding.string(JSONSerialization.data(withJSONObject: ["ok": false, "error": String(describing: error)]))) ?? "{}")
                )
            }
            try? FileManager.default.removeItem(at: root)
        }
    }
#endif
