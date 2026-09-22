import AdaEngine
import AdaScriptCompilerCore
import Foundation

struct EditorScriptableObjectDescriptor: Equatable, Sendable {
    struct Field: Equatable, Sendable {
        var name: String
        var defaultValue: EditorSceneValue
        var kind: EditorComponentFieldKind
    }

    var fields: [Field]
    var identifier: String
    var name: String
    var requiredComponentTypeNames: [String]
    var sourcePath: String
    var version: Int
}

struct EditorScenePlayRuntime: Sendable {
    var moduleName: String
    var schemas: [AdaScriptObjectSchema]
    var sources: [AdaScriptSource]
    var hasSystems: Bool
    var startupSystemIdentifier: String?
    var inputActions: [InputAction] = []

    @MainActor
    func install(in app: inout AppWorlds) throws {
        if app.main.getResource(Input.self) != nil {
            try app.main.getRefResource(Input.self).wrappedValue.setInputActions(inputActions)
        }
        try RuntimeLogStore.$currentSource.withValue("Game") {
            try registerScriptableObjects()
            if let plugin = try makeScriptPlugin() {
                app.addPlugin(plugin)
            }
        }
    }

    @MainActor
    func registerScriptableObjects() throws {
        let unregisteredSchemas = schemas.filter {
            ScriptableObjectRegistry.descriptor(named: $0.identifier) == nil
        }
        try AdaScriptObjectRegistration.register(
            schemas: unregisteredSchemas,
            sources: sources,
            moduleName: moduleName
        )
    }

    func makeScriptPlugin() throws -> AdaScriptPlugin? {
        guard hasSystems else {
            return nil
        }
        return try AdaScriptPlugin(
            sources: sources,
            name: moduleName,
            startupSystemIdentifier: startupSystemIdentifier
        )
    }
}

enum EditorScriptableObjectCatalogLoader {
    struct Result: Sendable {
        var descriptors: [EditorScriptableObjectDescriptor]
        var playRuntime: EditorScenePlayRuntime
    }

    static func load(
        project: AdaProject,
        at projectURL: URL,
        fileManager: FileManager = .default
    ) throws -> Result {
        let sourceRoot = projectURL.appendingPathComponent(project.paths.sources ?? "Sources", isDirectory: true)
        let sources =
            try loadSources(at: sourceRoot, fileManager: fileManager)
            + AdaScriptLibraryLock.load(at: projectURL).loadSources(at: projectURL)
        return try makeResult(project: project, sources: sources)
    }

    static func makeResult(project: AdaProject, sources: [AdaScriptSource]) throws -> Result {
        let schemas = try AdaScriptSchemaParser.parseScriptables(sources: sources)
        let hasSystems = try !AdaScriptSchemaParser.parseSystemCapabilities(sources: sources).isEmpty
        return Result(
            descriptors: schemas.map(makeEditorDescriptor).sorted { $0.name < $1.name },
            playRuntime: EditorScenePlayRuntime(
                moduleName: project.runtime.moduleName,
                schemas: schemas.map(makeRuntimeSchema),
                sources: sources,
                hasSystems: hasSystems,
                startupSystemIdentifier: project.runtime.entry.startupSystem,
                inputActions: project.inputActions
            )
        )
    }

    private static func loadSources(at rootURL: URL, fileManager: FileManager) throws -> [AdaScriptSource] {
        guard
            let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        var sources: [AdaScriptSource] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "ada" {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                continue
            }
            let relativePath =
                fileURL.path.hasPrefix(rootURL.path + "/")
                ? String(fileURL.path.dropFirst(rootURL.path.count + 1))
                : fileURL.lastPathComponent
            sources.append(
                AdaScriptSource(
                    path: relativePath,
                    source: try String(contentsOf: fileURL, encoding: .utf8)
                )
            )
        }
        return sources.sorted { $0.path < $1.path }
    }

    private static func makeEditorDescriptor(_ schema: AdaScriptableSchema) -> EditorScriptableObjectDescriptor {
        EditorScriptableObjectDescriptor(
            fields: schema.fields.map {
                EditorScriptableObjectDescriptor.Field(
                    name: $0.name,
                    defaultValue: editorSceneValue($0.defaultValue),
                    kind: editorFieldKind($0.defaultValue)
                )
            },
            identifier: schema.id,
            name: schema.name,
            requiredComponentTypeNames: schema.bindings.compactMap { binding in
                if case .component(required: true) = binding.kind {
                    return EditorComponentRegistry.descriptors.first { descriptor in
                        descriptor.typeName == binding.typeName
                            || descriptor.displayName == binding.typeName
                            || descriptor.typeName.hasSuffix(".\(binding.typeName)")
                    }?
                    .typeName ?? binding.typeName
                }
                return nil
            },
            sourcePath: schema.sourcePath,
            version: schema.version
        )
    }

    private static func makeRuntimeSchema(_ schema: AdaScriptableSchema) -> AdaScriptObjectSchema {
        AdaScriptObjectSchema(
            identifier: schema.id,
            className: schema.name,
            version: schema.version,
            aliases: schema.aliases,
            bindings: schema.bindings.map { binding in
                let kind: AdaScriptObjectBinding.Kind =
                    switch binding.kind {
                    case let .component(required): .component(required: required)
                    case let .resource(optional): .resource(optional: optional)
                    }
                return AdaScriptObjectBinding(
                    kind: kind,
                    propertyName: binding.propertyName,
                    typeName: binding.typeName
                )
            },
            fields: Dictionary(
                uniqueKeysWithValues: schema.fields.map {
                    ($0.name, editorFieldValue($0.defaultValue))
                }
            )
        )
    }

    private static func editorFieldKind(_ value: AdaScriptSchemaField.Value) -> EditorComponentFieldKind {
        switch value {
        case .bool: .bool
        case .double: .float
        case .int: .int
        case .string: .string
        }
    }

    private static func editorSceneValue(_ value: AdaScriptSchemaField.Value) -> EditorSceneValue {
        switch value {
        case let .bool(value): .bool(value)
        case let .double(value): .double(value)
        case let .int(value): .int(Int(value))
        case let .string(value): .string(value)
        }
    }

    private static func editorFieldValue(_ value: AdaScriptSchemaField.Value) -> ReflectedFieldValue {
        switch value {
        case let .bool(value): .bool(value)
        case let .double(value): .double(value)
        case let .int(value): .int(Int(value))
        case let .string(value): .string(value)
        }
    }
}
