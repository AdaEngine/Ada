import AdaEngine
import AdaScriptCompilerCore
import Foundation
import Observation

@MainActor
@Observable
final class EditorStudioToolHost {
    private(set) var definitions: [EditorStudioToolDefinition] = []
    private(set) var panels: [EditorStudioToolPanel] = []
    var selectedPanelID: String?
    var error: String?
    private(set) var permissionRequest: EditorStudioToolPermissionRequest?
    private(set) var enabledIDs: Set<String> = []
    @ObservationIgnored private var signatures: [String: String] = [:]
    @ObservationIgnored private var uiSignatures: [String: String] = [:]
    @ObservationIgnored private var runtimes: [String: AdaScriptToolRuntime] = [:]
    @ObservationIgnored private var projectURL: URL?
    @ObservationIgnored private weak var editor: EditorViewModel?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var actionTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var selectedPanel: EditorStudioToolPanel? { panels.first { $0.id == selectedPanelID } ?? panels.first }
    private var preferenceKey: String { "studio.tools." + (projectURL?.path ?? "") }

    func open(projectURL: URL, editor: EditorViewModel) {
        guard self.projectURL != projectURL.resolvingSymlinksInPath().standardizedFileURL || self.editor !== editor else {
            return
        }
        self.projectURL = projectURL.resolvingSymlinksInPath().standardizedFileURL
        self.editor = editor
        reload()
    }

    func close() {
        reloadTask?.cancel()
        actionTask?.cancel()
        for id in Array(runtimes.keys) { retire(id) }
        editor = nil
        projectURL = nil
        permissionRequest = nil
    }

    func scheduleReload() {
        guard projectURL != nil else {
            return
        }
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard !Task.isCancelled else {
                return
            }
            self?.reload()
        }
    }

    func reload() {
        guard let projectURL else {
            return
        }
        do {
            let overrides = sourceOverrides()
            let candidates = try EditorStudioToolDiscovery.discover(at: projectURL, overrides: overrides)
            definitions = candidates
            for id in Array(runtimes.keys) where !candidates.contains(where: { $0.schema.id == id }) { retire(id) }
            let approvals = defaults.dictionary(forKey: preferenceKey) as? [String: String] ?? [:]
            error = nil
            for candidate in candidates {
                let id = candidate.schema.id
                guard approvals[id] == approvalIdentity(candidate) else {
                    retire(id)
                    continue
                }
                do {
                    try install(candidate, projectURL: projectURL, overrides: overrides)
                    enabledIDs.insert(id)
                } catch { self.error = "\(candidate.schema.name): \(error.localizedDescription) Previous working version retained." }
            }
        } catch { self.error = error.localizedDescription }
    }

    private func install(_ definition: EditorStudioToolDefinition, projectURL: URL, overrides: [String: String]) throws {
        let id = definition.schema.id
        let keepsRuntime = signatures[id] == definition.signature && runtimes[id]?.isFailed == false
        let uiSignature = try resourceSignature(definition, projectURL: projectURL, overrides: overrides) + "|" + String(describing: editor?.workbench.uiCatalog.generation)
        if keepsRuntime, uiSignatures[id] == uiSignature {
            return
        }
        let runtime: AdaScriptToolRuntime
        if keepsRuntime, let previous = runtimes[id] {
            runtime = previous
        } else {
            runtime = try AdaScriptToolRuntime(sources: definition.sources, schema: definition.schema, grantedPermissions: definition.schema.permissions)
            try runtime.activate()
        }
        do {
            let mounted = try runtime.panels.map { contribution in
                let panelID = id + ":" + contribution.id
                return try EditorStudioToolPanel(
                    definition: definition,
                    contribution: contribution,
                    runtime: runtime,
                    catalog: editor?.workbench.uiCatalog ?? .standard,
                    overrides: overrides,
                    projectURL: projectURL,
                    previous: panels.first { $0.id == panelID }
                )
            }
            for panel in mounted { panel.bindActions { [weak self] panel, action in self?.enqueue(panel: panel, action: action) } }
            for panel in panels where panel.toolID == id { panel.isRetired = true }
            panels.removeAll { $0.toolID == id }
            if !keepsRuntime { runtimes[id]?.deactivate() }
            runtimes[id] = runtime
            signatures[id] = definition.signature
            uiSignatures[id] = uiSignature
            panels.append(contentsOf: mounted)
            if selectedPanelID == nil { selectedPanelID = mounted.first?.id }
        } catch {
            if !keepsRuntime { runtime.deactivate() }
            throw error
        }
    }

    private func retire(_ id: String) {
        for panel in panels where panel.toolID == id { panel.isRetired = true }
        runtimes.removeValue(forKey: id)?.deactivate()
        panels.removeAll { $0.toolID == id }
        signatures[id] = nil
        uiSignatures[id] = nil
        enabledIDs.remove(id)
        if !panels.contains(where: { $0.id == selectedPanelID }) { selectedPanelID = panels.first?.id }
    }

    private func sourceOverrides() -> [String: String] {
        guard let editor else {
            return [:]
        }
        return Dictionary(
            uniqueKeysWithValues: editor.workbench.openDocuments.compactMap { document in
                guard case .text(let text) = document, text.isDirty, text.relativePath.hasPrefix("Tools/") else {
                    if case .ui(let ui) = document, ui.isDirty, ui.relativePath.hasPrefix("Tools/") {
                        return (ui.relativePath, ui.content)
                    }
                    return nil
                }
                return (text.relativePath, text.content)
            }
        )
    }

    private func resourceSignature(_ definition: EditorStudioToolDefinition, projectURL: URL, overrides: [String: String]) throws -> String {
        guard
            let enumerator = FileManager.default.enumerator(
                at: definition.directory,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .contentModificationDateKey],
                options: .skipsHiddenFiles
            )
        else {
            return ""
        }
        var resources: [String] = []
        for case let url as URL in enumerator {
            let properties = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .contentModificationDateKey])
            if properties.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            let relative = String(url.path.dropFirst(projectURL.path.count + 1))
            if url.pathExtension.lowercased() == "ui" {
                resources.append(relative + "\n" + (try overrides[relative] ?? String(contentsOf: url, encoding: .utf8)))
            } else {
                resources.append(relative + "|" + String(properties.contentModificationDate?.timeIntervalSince1970 ?? 0))
            }
        }
        return resources.sorted().joined(separator: "\n")
    }

    private func enqueue(panel: EditorStudioToolPanel, action: String) {
        guard let editor, !panel.isRetired else {
            return
        }
        let document = editor.workbench.activeSceneDocument
        do {
            let inputs = try panel.inputs()
            let previous = actionTask
            actionTask = Task { [weak self, weak panel] in
                await previous?.value
                await Task.yield()
                guard let self, let panel, !panel.isRetired, !Task.isCancelled else {
                    return
                }
                self.perform(panel: panel, action: action, inputs: inputs, document: document)
            }
        } catch { panel.error = error.localizedDescription }
    }

    private func perform(panel: EditorStudioToolPanel, action: String, inputs: [String: AdaScriptSchemaField.Value], document: EditorSceneDocument?) {
        do {
            let scene = document.map {
                AdaScriptToolScene(path: $0.relativePath, revision: EditorAgentSceneToolService.revision(for: $0.content), entityCount: $0.sceneModel?.entities.count ?? 0)
            }
            let entities = try panel.runtime.perform(action, inputs: inputs, scene: scene)
            if !entities.isEmpty {
                guard let editor, let document, let projectURL,
                    let current = editor.workbench.activeSceneDocument, current.id == document.id,
                    current.content == document.content, !current.isReadOnly, let model = current.sceneModel
                else {
                    throw EditorStudioToolDiscovery.Failure("The active scene changed or is read-only. Run the action again.")
                }
                let operations = entities.map { entity in
                    var transform = EditorComponentRegistry.defaultPayload(for: EditorBuiltInComponentType.transform)
                    transform["position"] = .array([.double(entity.x), .double(entity.y), .double(0)])
                    return EditorAgentSceneOperation.createEntity(
                        id: nil,
                        name: entity.name,
                        parentID: nil,
                        components: [EditorBuiltInComponentType.transform: transform]
                    )
                }
                var updatedModel = try EditorAgentSceneToolService(projectURL: projectURL).applying(operations: operations, to: model)
                // Keep the current editing context instead of opening Inspector for
                // each generated entity and displacing the tool's panel.
                updatedModel.editor = model.editor
                var updated = current
                updated.sceneModel = updatedModel
                updated.content = try updatedModel.encodedYAML()
                updated.loadSummary = EditorSceneFileLoader.summary(from: updated.content)
                updated.isDirty = updated.content != updated.lastSavedContent
                updated.statusMessage = "Applied \(panel.title)"
                editor.workbench.replaceSceneDocument(updated)
            }
            for item in panels where item.toolID == panel.toolID {
                for (key, value) in panel.runtime.values { item.session.context.set(key, to: EditorStudioToolPanel.uiValue(value)) }
            }
            panel.error = nil
        } catch {
            panel.error = error.localizedDescription
            editor?.appendOutput("Studio tool \(panel.toolID): \(error.localizedDescription)")
        }
    }
}

// Consent and its persisted identity are separate from runtime generation ownership.
extension EditorStudioToolHost {
    func enable(_ id: String, presentation: EditorStudioToolPermissionRequest.Presentation = .workspace) {
        guard let definition = definitions.first(where: { $0.schema.id == id }), projectURL != nil else {
            return
        }
        if let reason = unavailabilityReason(definition) {
            error = reason
            return
        }
        if isAuthorized(definition) {
            activateApproved(definition)
            return
        }
        permissionRequest = .init(definition: definition, presentation: presentation)
    }

    func approve(_ requestID: UUID) {
        guard let request = permissionRequest, request.id == requestID else {
            return
        }
        guard let definition = definitions.first(where: { $0.schema.id == request.definition.schema.id }) else {
            permissionRequest = nil
            error = "The tool is no longer available in this project."
            return
        }
        guard definition.signature == request.definition.signature,
            approvalIdentity(definition) == approvalIdentity(request.definition)
        else {
            permissionRequest = nil
            error = "The tool changed while access was being reviewed. Review it again before enabling."
            return
        }
        permissionRequest = nil
        var approvals = defaults.dictionary(forKey: preferenceKey) as? [String: String] ?? [:]
        approvals[definition.schema.id] = approvalIdentity(definition)
        defaults.set(approvals, forKey: preferenceKey)
        activateApproved(definition)
    }

    func cancelPermissionRequest(_ requestID: UUID) {
        guard let request = permissionRequest, request.id == requestID else {
            return
        }
        recordRevocation(request.definition)
        permissionRequest = nil
    }

    func reviewAvailableTools() {
        guard permissionRequest == nil, let id = reviewCandidateIDs.first else {
            return
        }
        enable(id)
    }

    var reviewCandidateIDs: [String] {
        let approvals = defaults.dictionary(forKey: preferenceKey) as? [String: String] ?? [:]
        return definitions.filter {
            unavailabilityReason($0) == nil && !isAuthorized($0) && approvals[$0.schema.id] != "denied:" + approvalIdentity($0)
        }.map(\.schema.id)
    }

    func isAuthorized(_ definition: EditorStudioToolDefinition) -> Bool {
        (defaults.dictionary(forKey: preferenceKey) as? [String: String])?[definition.schema.id] == approvalIdentity(definition)
    }

    func unavailabilityReason(_ definition: EditorStudioToolDefinition) -> String? {
        guard definition.schema.apiVersion == 1, definition.schema.platforms.contains(.macOS) else {
            return "This tool requires an unsupported Studio API or platform."
        }
        let unsupported = definition.schema.permissions.filter { ![.documentRead, .documentWrite].contains($0) }
        return unsupported.isEmpty ? nil : "This version of Studio does not support the requested \(unsupported.map(\.rawValue).joined(separator: ", ")) access."
    }

    private func activateApproved(_ definition: EditorStudioToolDefinition) {
        guard isAuthorized(definition), let projectURL else {
            return
        }
        let id = definition.schema.id
        do {
            try install(definition, projectURL: projectURL, overrides: sourceOverrides())
            enabledIDs.insert(id)
            selectedPanelID = panels.first { $0.toolID == id }?.id
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func disable(_ id: String) {
        retire(id)
        if let definition = definitions.first(where: { $0.schema.id == id }) { recordRevocation(definition) }
        if permissionRequest?.definition.schema.id == id { permissionRequest = nil }
    }

    private func recordRevocation(_ definition: EditorStudioToolDefinition) {
        var approvals = defaults.dictionary(forKey: preferenceKey) as? [String: String] ?? [:]
        approvals[definition.schema.id] = "denied:" + approvalIdentity(definition)
        defaults.set(approvals, forKey: preferenceKey)
    }

    private func approvalIdentity(_ definition: EditorStudioToolDefinition) -> String {
        let schema = definition.schema
        return "consent-v1|" + definition.directory.path + "/" + schema.sourcePath + "|" + String(schema.apiVersion) + "|"
            + schema.permissions.map(\.rawValue).sorted().joined(separator: ",") + "|"
            + schema.platforms.map(\.rawValue).sorted().joined(separator: ",")
    }
}
