import AdaApp
@_spi(Scripting) import AdaECS
import AdaInput
import AdaRender
import AdaScene
import AdaScriptAOTFixture
import AdaScriptCompilerCore
@testable import AdaScripting
import AdaSprite
import Foundation
#if canImport(GravityAOT)
    import CGravity
    import GravityAOT
#endif
import Testing

@MainActor @Suite("Shader Graph script capabilities", .serialized) struct ShaderGraphScriptTests {
    private func material() throws -> ShaderGraphMaterial {
        var tint = ShaderGraph.Node(id: "tint", operation: .parameter, type: .color, value: [1, 1, 1, 1], reference: "tint")
        tint.label = "Tint"
        var gain = ShaderGraph.Node(id: "gain", operation: .parameter, value: [0.5], reference: "gain")
        gain.label = "Amount"
        let graph = ShaderGraph(
            target: .sprite,
            output: "output",
            nodes: [
                tint, gain, .init(id: "enabled", operation: .parameter, type: .bool, value: [1], reference: "enabled"),
                .init(id: "color", operation: .multiply, type: .color, inputs: ["a": .init("tint"), "b": .init("gain")]),
                .init(id: "fallback", operation: .constant, type: .color, value: [0, 0, 0, 1]),
                .init(id: "select", operation: .select, type: .color, inputs: ["condition": .init("enabled"), "a": .init("color"), "b": .init("fallback")]),
                .init(id: "output", operation: .output, inputs: ["color": .init("select")]),
            ]
        )
        try graph.compileWGSL().validateWGSL()
        return try ShaderGraphMaterial(source: .init(graph: graph))
    }

    private var fixtureURL: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("AdaScriptAOTFixture/ShaderGraph.ada") }

    private func world(material: ShaderGraphMaterial) -> World {
        Sprite.registerComponent()
        RuntimeTypeRegistry.registerComponent(Sprite.self, names: ["Sprite"])
        ComponentReflectionRegistry.register(Sprite.componentDescriptor)
        let world = World(name: "Graph scripts")
        var sprite = Sprite()
        sprite.graphMaterial = material
        world.spawn { sprite }
        return world
    }

    @Test func shaderCapabilitiesTypeCheckInTheProductionAnalyzer() throws {
        let source = try String(contentsOf: fixtureURL, encoding: .utf8)
        let analysis = AdaScriptAnalyzer.analyze(source: source)
        #expect(analysis.typeIssues.isEmpty, Comment(rawValue: String(describing: analysis.typeIssues)))
    }

    @Test func realVMDiscoversReadsAndChangesTypedValuesWithoutChangingCode() async throws {
        let graph = try material()
        let source = try String(contentsOf: fixtureURL, encoding: .utf8)
        let plugin = try AdaScriptPlugin(source: source, name: "GraphVM")
        let world = world(material: graph)
        let originalCode = graph.program.source
        plugin.setup(in: AppWorlds(main: world))
        await world.runScheduler(SchedulerName(rawValue: "shaderGraphTest"), deltaTime: 0.016)
        #expect(plugin.diagnostics.isEmpty, Comment(rawValue: plugin.diagnostics.joined(separator: "\n")))
        #expect(graph.value(for: "tint") == [0.25, 0.5, 1, 1])
        #expect(graph.value(for: "gain") == [0.75])
        #expect(graph.value(for: "enabled") == [0])
        #expect(graph.program.source == originalCode)
    }

    @Test func vmScriptableComponentBindingChangesItsGraph() async throws {
        let graph = try material()
        let world = world(material: graph)
        let source = AdaScriptSource(
            path: "ShaderGraph.ada",
            source: try String(contentsOf: fixtureURL, encoding: .utf8).replacingOccurrences(of: "shader.graph.controller", with: "shader.graph.controller.vm")
        )
        let schema = AdaScriptObjectSchema(
            identifier: "shader.graph.controller.vm",
            className: "ShaderGraphController",
            version: 1,
            aliases: [],
            bindings: [.init(kind: .component(required: true), propertyName: "sprite", typeName: "Sprite")],
            fields: [:]
        )
        try AdaScriptObjectRegistration.register(schemas: [schema], sources: [source], moduleName: "GraphScriptableVM")
        let script = try ScriptableObjectRegistry.make(named: schema.identifier)
        let owner = try #require(world.getEntities().first)
        let app = AppWorlds(main: world)
        InputPlugin().setup(in: app)
        ScriptableObjectPlugin().setup(in: app)
        world.insert(ScriptableComponents(scripts: [script]), for: owner.id)
        await world.runScheduler(.update, deltaTime: 0.016)
        #expect(graph.value(for: "gain") == [0.125])
    }

    @Test func vmAssignsFreshIndependentMaterialsAndClearsThem() async throws {
        let original = try material()
        let world = world(material: original)
        var duplicate = Sprite()
        duplicate.graphMaterial = original
        world.spawn { duplicate }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AssignedGraph-\(UUID().uuidString).shadergraph")
        defer { try? FileManager.default.removeItem(at: url) }
        var graph = try #require(original.descriptor.graph)
        graph.nodes[0].value = [0, 1, 0, 1]
        try JSONEncoder().encode(graph).write(to: url)
        let source = """
            @system(id: "graph.assignment")
            @access(write: [Sprite])
            class AssignGraph {
                @query(Sprite) var rows
                var applied = false
                func update(context) {
                    for (var row in rows) {
                        if (applied) { row.sprite.assignShader(0, ""); }
                        else { row.sprite.assignShader(0, \(String(reflecting: url.path))); }
                    }
                    applied = true
                }
            }
            """
        let plugin = try AdaScriptPlugin(source: source, name: "GraphAssignment")
        plugin.setup(in: AppWorlds(main: world))
        await world.runScheduler(.update, deltaTime: 0.016)
        let materials = world.getEntities().compactMap { $0.components[Sprite.self]?.graphMaterial }
        try #require(materials.count == 2, Comment(rawValue: plugin.diagnostics.joined(separator: "\n")))
        #expect(materials[0] !== materials[1])
        #expect(materials.allSatisfy { $0.value(for: "tint") == [0, 1, 0, 1] })
        #expect(original.value(for: "tint") == [1, 1, 1, 1])
        await world.runScheduler(.update, deltaTime: 0.016)
        #expect(world.getEntities().allSatisfy { $0.components[Sprite.self]?.graphMaterial == nil })
        #expect(plugin.diagnostics.isEmpty, Comment(rawValue: plugin.diagnostics.joined(separator: "\n")))
    }

    #if canImport(GravityAOT)
        @Test func actualAOTModuleUsesTheSameGraphCapabilities() async throws {
            let pointer = try #require(ada_native_shader_graph_get_module())
            let module = unsafe try NativeModule(module: pointer)
            let source = AdaScriptSource(path: "ShaderGraph.ada", source: try String(contentsOf: fixtureURL, encoding: .utf8))
            let graph = try material()
            let world = world(material: graph)
            let plugin = try AdaScriptNativePlugin(module: module, name: "GraphAOT", sources: [source])
            try plugin.validateBindings()
            plugin.setup(in: AppWorlds(main: world))
            await world.runScheduler(SchedulerName(rawValue: "shaderGraphTest"), deltaTime: 0.016)
            #expect(plugin.diagnostics.isEmpty, Comment(rawValue: plugin.diagnostics.joined(separator: "\n")))
            #expect(graph.value(for: "tint") == [0.25, 0.5, 1, 1])
            #expect(graph.value(for: "gain") == [0.75])
            #expect(graph.value(for: "enabled") == [0])
        }

        @Test func nativeScriptableComponentBindingChangesItsGraph() async throws {
            let pointer = try #require(ada_native_shader_graph_get_module())
            let module = unsafe try NativeModule(module: pointer)
            let plugin = try AdaScriptNativePlugin(module: module, name: "GraphScriptableAOT")
            let graph = try material()
            let world = world(material: graph)
            let app = AppWorlds(main: world)
            InputPlugin().setup(in: app)
            ScriptableObjectPlugin().setup(in: app)
            plugin.setup(in: app)
            let script = try ScriptableObjectRegistry.make(named: "shader.graph.controller")
            let owner = try #require(world.getEntities().first)
            world.insert(ScriptableComponents(scripts: [script]), for: owner.id)
            await world.runScheduler(.update, deltaTime: 0.016)
            #expect(graph.value(for: "gain") == [0.125])
            #expect(plugin.diagnostics.isEmpty, Comment(rawValue: plugin.diagnostics.joined(separator: "\n")))
        }
        @Test func nativeReadOnlyAndExpiredHandlesRejectWrites() throws {
            let pointer = try #require(ada_native_shader_graph_get_module())
            let module = unsafe try NativeModule(module: pointer)
            let graph = try material()
            let world = world(material: graph)
            var access = SystemAccessSet()
            access.addComponentRead(Sprite.self)
            let query = DynamicQuery(where: .has(Sprite.self), components: [Sprite.identifier], access: access)
            query.update(from: world)
            let cursor = query.wrappedValue.makeCursor()
            #expect(cursor.advance())
            let scope = NativeCallbackScope()
            let component = NativeQueryComponent(cursor: cursor, access: .init(alias: "sprite", componentIndex: 0, fields: [:], isWritable: false), scope: scope)
            let probe = try module.makeInstance(type: "ShaderGraphProbe")
            let result = try module.invoke(probe, method: "mutate", arguments: [.host(component)])
            if case .boolean(false) = result {} else { Issue.record("AOT accepted a read-only graph write") }
            _ = try module.invoke(probe, method: "remember", arguments: [.host(component)])
            scope.isActive = false
            do {
                _ = try module.invoke(probe, method: "useSaved")
                Issue.record("AOT accepted an expired graph handle")
            } catch NativeRuntimeError.runtime(let code, _) { #expect(code == UInt32(GRAVITY_AOT_STALE_HANDLE)) }
            #expect(graph.value(for: "gain") == [0.5])
        }
    #endif

    @Test func readOnlyExpiredAndMismatchedCapabilitiesDoNotChangeTheMaterial() throws {
        let graph = try material()
        var active = true
        let reader = ShaderGraphScriptHandle(material: graph, writable: false, isActive: { active })
        #expect(try reader.name("tint") == "Tint")
        #expect(try reader.value("Amount", type: .float) == [0.5])
        #expect(throws: ShaderGraphScriptError.readOnly) { try reader.set("gain", type: .float, value: [1]) }
        let writer = ShaderGraphScriptHandle(material: graph, writable: true, isActive: { active })
        #expect(throws: ShaderGraphScriptError.typeMismatch) { try writer.set("tint", type: .vector4, value: [1, 1, 1, 1]) }
        #expect(throws: ShaderGraphScriptError.unknownParameter) { try writer.set("missing", type: .float, value: [1]) }
        active = false
        #expect(throws: ShaderGraphScriptError.expired) { try writer.set("gain", type: .float, value: [1]) }
        #expect(graph.value(for: "gain") == [0.5])
    }

    @Test func copiedMaterialValuesAreIndependentAndKeepTheirOriginalCode() throws {
        let graph = try material()
        var pbrGraph = try #require(graph.descriptor.graph)
        pbrGraph.target = .pbrSurface
        pbrGraph.nodes[pbrGraph.nodes.count - 1].inputs = ["baseColor": .init("select")]
        let surface = try ShaderGraphMaterial(source: .init(graph: pbrGraph))
        let first = PBRMaterial()
        first.roughnessFactor = 0.3
        first.clearcoatFactor = 0.5
        first.graphMaterial = surface
        let copy = first.makeInstance()
        let instance = try #require(copy.graphMaterial)
        try instance.setValue([0.25], for: "gain")
        #expect(first.graphMaterial?.value(for: "gain") == [0.5])
        #expect(copy.roughnessFactor == 0.3 && copy.clearcoatFactor == 0.5)
        #expect(instance.program == surface.program)
        #expect(instance !== surface)
    }
}
