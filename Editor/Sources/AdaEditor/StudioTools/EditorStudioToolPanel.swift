import AdaEngine
import AdaScriptCompilerCore
import Foundation
import Observation

@MainActor
@Observable
final class EditorStudioToolPanel {
    let id: String
    let toolID: String
    let title: String
    let sourceURL: URL
    let session: UISceneInstance
    let runtime: AdaScriptToolRuntime
    var error: String?
    var isRetired = false

    init(
        definition: EditorStudioToolDefinition,
        contribution: AdaScriptToolPanel,
        runtime: AdaScriptToolRuntime,
        catalog: UICatalog,
        overrides: [String: String],
        projectURL: URL,
        previous: EditorStudioToolPanel? = nil
    ) throws {
        id = definition.schema.id + ":" + contribution.id
        toolID = definition.schema.id
        title = contribution.title
        self.runtime = runtime
        let root = definition.directory.resolvingSymlinksInPath().standardizedFileURL
        let parent = root.appendingPathComponent(definition.schema.sourcePath).deletingLastPathComponent()
        guard !contribution.ui.hasPrefix("/"), !contribution.ui.contains(":") else {
            throw EditorStudioToolDiscovery.Failure("Panel UI must be relative to the tool source.")
        }
        sourceURL = parent.appendingPathComponent(contribution.ui).resolvingSymlinksInPath().standardizedFileURL
        guard sourceURL.path.hasPrefix(root.path + "/"), sourceURL.pathExtension.lowercased() == "ui" else {
            throw EditorStudioToolDiscovery.Failure("Panel UI must be a .ui resource inside the tool directory.")
        }
        let relative = String(sourceURL.path.dropFirst(projectURL.resolvingSymlinksInPath().path.count + 1))
        let document = try UISceneDocument.decode(overrides[relative] ?? String(contentsOf: sourceURL, encoding: .utf8))
        let values = runtime.values.mapValues(Self.uiValue)
        let context = UIBindingContext(values: values)
        for input in document.inputs {
            guard let fieldValue = values[input.name], input.type.accepts(fieldValue) else {
                throw EditorStudioToolDiscovery.Failure("UI input '\(input.name)' must match an @export tool field.")
            }
            if let retained = previous?.session.context.value(input.name), input.type.accepts(retained) {
                context.set(input.name, to: retained)
            }
        }
        var actions = Set(document.actions.map(\.name))
        document.root.visit { node in
            actions.formUnion(node.actions.values)
            for modifier in node.modifiers { actions.formUnion(modifier.actions.values) }
        }
        for action in actions {
            try runtime.validateAction(action)
            context.on(action) { _ in }
        }
        let resources = UISceneResources(rootURL: root)
        for (path, content) in overrides where path.hasSuffix(".ui") {
            let url = projectURL.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
            if url.path.hasPrefix(root.path + "/") {
                try resources.publish(UISceneDocument.decode(content), at: url)
            }
        }
        session = try UISceneInstance(
            document: document,
            context: context,
            catalog: catalog,
            resources: resources,
            sourceURL: sourceURL
        )
    }

    func inputs() throws -> [String: AdaScriptSchemaField.Value] {
        var result: [String: AdaScriptSchemaField.Value] = [:]
        for field in runtime.schema.fields {
            guard let value = session.context.value(field.name) else { continue }
            switch (field.defaultValue, value) {
            case (.bool, .bool(let value)): result[field.name] = .bool(value)
            case (.string, .string(let value)): result[field.name] = .string(value)
            case (.double, .number(let value)) where value.isFinite: result[field.name] = .double(value)
            case (.int, .number(let value)) where value.isFinite:
                guard let integer = Int64(exactly: value) else { throw EditorStudioToolDiscovery.Failure("'\(field.name)' must be an integer.") }
                result[field.name] = .int(integer)
            default: throw EditorStudioToolDiscovery.Failure("Invalid UI input '\(field.name)'.")
            }
        }
        return result
    }

    func bindActions(_ perform: @escaping @MainActor (EditorStudioToolPanel, String) -> Void) {
        var actions = Set(session.document.actions.map(\.name))
        session.document.root.visit { node in
            actions.formUnion(node.actions.values)
            for modifier in node.modifiers { actions.formUnion(modifier.actions.values) }
        }
        for action in actions {
            session.context.on(action) { [weak self] _ in
                guard let self, !self.isRetired else {
                    return
                }
                perform(self, action)
            }
        }
    }

    static func uiValue(_ value: AdaScriptSchemaField.Value) -> UIValue {
        switch value {
        case .bool(let value): .bool(value)
        case .int(let value): .number(Double(value))
        case .double(let value): .number(value)
        case .string(let value): .string(value)
        }
    }
}
