@_spi(AdaEngine) import AdaEngine
import Observation

@MainActor @Observable
final class EditorUISceneModel {
    var document: UISceneDocument
    var selectedID: String
    var collapsedLayerIDs: Set<String> = []
    var search = ""
    var rawSource: String
    var showsSource = false
    var insertionModifierID: String?
    var selectedBindingOwnerID: String?
    @ObservationIgnored var bindingSceneDocumentIDs: Set<String> = []
    @ObservationIgnored var onBindingOwners: (() -> [EditorUIBindingOwner])?
    @ObservationIgnored var onBindingChange: ((EditorUIBindingOwner, [String: UIScriptFieldBinding], [String: UIScriptFieldBinding]) -> Bool)?
    @ObservationIgnored var onPresentModifierPicker: ((String) -> Void)?
    @ObservationIgnored var onOpenUI: ((URL) -> Void)?
    var isInteractive = false
    var zoom: Float = 1
    var width: Float = 800
    var height: Float = 600
    var error: String?
    var lastAction: String?
    var session: UISceneInstance?
    var preview: UIView?
    var isReadOnly: Bool
    var catalog: UICatalog
    let resources: UISceneResources
    let sourceURL: URL?
    @ObservationIgnored var onHistoryChange: ((Bool) -> Void)?
    @ObservationIgnored var onChange: ((String) -> Void)?
    private struct HistoryEntry {
        let document: UISceneDocument
        let externalChange: ((Bool) -> Bool)?
    }
    @ObservationIgnored private var undoStack: [HistoryEntry] = []
    @ObservationIgnored private var redoStack: [HistoryEntry] = []

    init(content: String, sourceURL: URL?, resourceRoot: URL?, isReadOnly: Bool = false, catalog: UICatalog = .standard) {
        self.rawSource = content
        self.catalog = catalog
        self.sourceURL = sourceURL
        self.isReadOnly = isReadOnly
        resources = UISceneResources(rootURL: resourceRoot ?? sourceURL?.deletingLastPathComponent() ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        let decoded = Result { try UISceneDocument.decode(content) }
        let parsed = (try? decoded.get()) ?? UISceneDocument()
        document = parsed
        selectedID = parsed.root.id
        if case let .failure(failure) = decoded {
            error = failure.localizedDescription
            showsSource = true
        } else {
            rebuild()
        }
    }

    var selectedNode: UINodeDescription? {
        var result: UINodeDescription?
        document.root.visit {
            if $0.id == selectedID {
                result = $0
            }
        }
        return result
    }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var palette: [UIDescriptorSignature] {
        catalog.viewSignatures.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    func edit(_ change: (inout UISceneDocument) throws -> Void, externalChange: ((Bool) -> Bool)? = nil) {
        guard !isReadOnly else {
            return
        }
        do {
            var candidate = document
            try change(&candidate)
            try candidate.validate()
            try validateChildren(candidate.root)
            guard candidate != document else {
                return
            }
            guard externalChange?(true) != false else {
                error = "The scene binding changed or its owner is no longer available. Reopen the binding picker."
                return
            }
            undoStack.append(.init(document: document, externalChange: externalChange))
            redoStack.removeAll()
            document = candidate
            publish()
        } catch { self.error = error.localizedDescription }
    }

    func updateSelected(_ change: (inout UINodeDescription) -> Void) {
        let id = selectedID
        edit { Self.modify(&$0.root, id: id, change) }
    }

    func add(_ type: String, selectingNewNode: Bool = true) {
        guard let signature = catalog.views[type]?.signature else {
            return
        }
        var node = UINodeDescription(type: type)
        for parameter in signature.parameters {
            if let value = parameter.defaultValue {
                node.arguments[parameter.name] = .init(value: value)
            }
        }
        let id = selectedID
        let modifierID = insertionModifierID
        edit { document in
            Self.modify(&document.root, id: id) { parent in
                if let modifierID, let index = parent.modifiers.firstIndex(where: { $0.id == modifierID }) {
                    parent.modifiers[index].children.append(node)
                } else {
                    parent.children.append(node)
                }
            }
        }
        if contains(node.id) {
            collapsedLayerIDs.remove(id)
            if selectingNewNode {
                insertionModifierID = nil
                selectedID = node.id
            }
        }
    }

    func removeSelected() {
        let id = selectedID
        guard id != document.root.id else {
            return
        }
        edit { Self.remove(&$0.root, id: id) }
        selectedID = document.root.id
    }

    func duplicateSelected() {
        guard let node = selectedNode, node.id != document.root.id else {
            return
        }
        let copy = Self.reidentified(node)
        edit { Self.insertSibling(&$0.root, after: node.id, node: copy) }
        if contains(copy.id) {
            selectedID = copy.id
        }
    }

    func wrap(_ type: String) {
        let id = selectedID
        edit { Self.modify(&$0.root, id: id) { $0 = UINodeDescription(type: type, children: [$0]) } }
    }

    func move(_ id: String, into parentID: String, at index: Int? = nil) {
        guard id != document.root.id, id != parentID, contains(parentID) else {
            return
        }
        var moving: UINodeDescription?
        document.root.visit {
            if $0.id == id {
                moving = $0
            }
        }
        guard let moving else {
            return
        }
        var cyclic = false
        moving.visit {
            if $0.id == parentID {
                cyclic = true
            }
        }
        guard !cyclic else {
            error = "A node cannot contain itself."
            return
        }
        edit {
            Self.remove(&$0.root, id: id)
            Self.modify(&$0.root, id: parentID) { parent in
                parent.children.insert(moving, at: min(max(index ?? parent.children.count, 0), parent.children.count))
            }
        }
    }

    func reorder(_ direction: Int) {
        let id = selectedID
        edit { document in
            Self.walk(&document.root) { parent in
                guard let index = parent.children.firstIndex(where: { $0.id == id }), parent.children.indices.contains(index + direction) else {
                    return
                }
                parent.children.swapAt(index, index + direction)
            }
        }
    }

    func undo() {
        guard !isReadOnly, let previous = undoStack.last else {
            return
        }
        guard previous.externalChange?(false) != false else {
            error = "Cannot undo: the scene binding changed or its owner was closed."
            return
        }
        undoStack.removeLast()
        redoStack.append(.init(document: document, externalChange: previous.externalChange))
        document = previous.document
        publish()
        onHistoryChange?(false)
    }

    func redo() {
        guard !isReadOnly, let next = redoStack.last else {
            return
        }
        guard next.externalChange?(true) != false else {
            error = "Cannot redo: the scene binding changed or its owner was closed."
            return
        }
        redoStack.removeLast()
        undoStack.append(.init(document: document, externalChange: next.externalChange))
        document = next.document
        publish()
        onHistoryChange?(true)
    }

    func addModifier(_ type: String, to nodeID: String? = nil) {
        guard let descriptor = catalog.modifiers[type] else {
            return
        }
        let arguments = Dictionary(uniqueKeysWithValues: descriptor.signature.parameters.compactMap { p in p.defaultValue.map { (p.name, UIArgument(value: $0)) } })
        let targetID = nodeID ?? selectedID
        edit { document in
            Self.modify(&document.root, id: targetID) { $0.modifiers.append(.init(type: type, arguments: arguments)) }
        }
    }

    func editSource(_ source: String) {
        guard !isReadOnly else {
            return
        }
        rawSource = source
        onChange?(source)
        do {
            let candidate = try UISceneDocument.decode(source)
            if candidate != document {
                undoStack.append(.init(document: document, externalChange: nil))
                redoStack.removeAll()
                document = candidate
            }
            rebuild()
        } catch { self.error = error.localizedDescription }
    }

    func signature(for node: UINodeDescription) -> UIDescriptorSignature? {
        guard
            node.type == "UI", let path = node.arguments["path"]?.value?.string,
            let url = try? resources.resolve(path, relativeTo: sourceURL), let nested = try? resources.load(url)
        else {
            return catalog.views[node.type]?.signature
        }
        return .init(id: "UI", name: "UI", parameters: [.init("path", type: .string)] + nested.inputs, actions: nested.actions)
    }

    func openNestedUI() {
        guard let node = selectedNode, let path = node.arguments["path"]?.value?.string else {
            return
        }
        do { onOpenUI?(try resources.resolve(path, relativeTo: sourceURL)) } catch { self.error = error.localizedDescription }
    }

    func reload(content: String) {
        // The file watcher also reports our own autosaves. Keep their undo history.
        guard content != rawSource else {
            return
        }
        do {
            rawSource = content
            document = try UISceneDocument.decode(content)
            undoStack.removeAll()
            redoStack.removeAll()
            rebuild()
        } catch { self.error = error.localizedDescription }
    }

    private func contains(_ id: String) -> Bool {
        var found = false
        document.root.visit {
            if $0.id == id {
                found = true
            }
        }
        return found
    }

    private func publish() {
        if !contains(selectedID) {
            selectedID = document.root.id
        }
        do {
            rawSource = try document.encodedYAML()
            onChange?(rawSource)
            rebuild()
            if let sourceURL {
                EventManager.default.send(UISceneResourceChanged(url: sourceURL, document: document))
            }
        } catch { self.error = error.localizedDescription }
    }

    func install(catalog: UICatalog) {
        guard self.catalog.generation != catalog.generation else {
            return
        }
        let context = session?.context ?? UIBindingContext()
        self.catalog = catalog
        do {
            let candidate = try UISceneInstance(document: document, context: context, catalog: catalog, resources: resources, sourceURL: sourceURL)
            session = candidate
            preview = UIContainerView(rootView: UISceneView(session: candidate))
            preview?.backgroundColor = .clear
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func rebuild() {
        let context = session?.context ?? UIBindingContext()
        for input in document.inputs {
            if let value = input.defaultValue,
                session?.document.inputs.first(where: { $0.name == input.name })?.defaultValue != input.defaultValue {
                context.set(input.name, to: value)
            }
        }
        context.applyDefaults(document.inputs)
        var actions = Set(document.actions.map(\.name))
        document.root.visit { node in
            actions.formUnion(node.actions.values)
            for modifier in node.modifiers { actions.formUnion(modifier.actions.values) }
        }
        for action in actions { context.on(action) { [weak self] _ in self?.lastAction = action } }
        do {
            if let session {
                if !session.update(document) {
                    error = session.diagnostic
                    return
                }
            } else {
                let newSession = try UISceneInstance(document: document, context: context, catalog: catalog, resources: resources, sourceURL: sourceURL)
                session = newSession
                preview = UIContainerView(rootView: UISceneView(session: newSession))
                preview?.backgroundColor = .clear
            }
            if let sourceURL {
                try resources.publish(document, at: sourceURL)
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func validateChildren(_ node: UINodeDescription) throws {
        guard let signature = catalog.views[node.type]?.signature else {
            return
        }
        if signature.content == .none && !node.children.isEmpty || signature.content == .single && node.children.count > 1 {
            throw UIDiagnostic("\(signature.name) cannot accept these children.", nodeID: node.id)
        }
        for child in node.children { try validateChildren(child) }
        for modifier in node.modifiers {
            if let signature = catalog.modifiers[modifier.type]?.signature {
                if signature.content == .none && !modifier.children.isEmpty || signature.content == .single && modifier.children.count > 1 {
                    throw UIDiagnostic("Invalid content for modifier '\(modifier.type)'.")
                }
            }
            for child in modifier.children { try validateChildren(child) }
        }
    }

    static func modify(_ node: inout UINodeDescription, id: String, _ body: (inout UINodeDescription) -> Void) {
        if node.id == id {
            body(&node)
            return
        }
        for index in node.children.indices { modify(&node.children[index], id: id, body) }
        for modifier in node.modifiers.indices {
            for index in node.modifiers[modifier].children.indices { modify(&node.modifiers[modifier].children[index], id: id, body) }
        }
    }

    private static func walk(_ node: inout UINodeDescription, _ body: (inout UINodeDescription) -> Void) {
        body(&node)
        for index in node.children.indices { walk(&node.children[index], body) }
    }
    private static func remove(_ node: inout UINodeDescription, id: String) {
        node.children.removeAll { $0.id == id }
        for index in node.children.indices { remove(&node.children[index], id: id) }
        for index in node.modifiers.indices {
            node.modifiers[index].children.removeAll { $0.id == id }
            for child in node.modifiers[index].children.indices { remove(&node.modifiers[index].children[child], id: id) }
        }
    }
    private static func insertSibling(_ node: inout UINodeDescription, after id: String, node copy: UINodeDescription) {
        if let index = node.children.firstIndex(where: { $0.id == id }) {
            node.children.insert(copy, at: index + 1)
            return
        }
        for index in node.children.indices { insertSibling(&node.children[index], after: id, node: copy) }
    }
    private static func reidentified(_ node: UINodeDescription) -> UINodeDescription {
        var copy = node
        copy.id = UUID().uuidString
        copy.children = copy.children.map(reidentified)
        copy.modifiers = copy.modifiers.map { modifier in
            var value = modifier
            value.id = UUID().uuidString
            value.children = value.children.map(reidentified)
            return value
        }
        return copy
    }
}

extension EditorWorkbenchViewModel {
    func uiSceneModel(for document: EditorTextDocument, resourceRoot: URL?, bindingCatalog: [EditorScriptableObjectDescriptor] = []) -> EditorUISceneModel {
        if let model = uiSceneModels[document.id] {
            configureBindings(model, resourceRoot: resourceRoot, catalog: bindingCatalog)
            return model
        }
        let model = EditorUISceneModel(
            content: document.content,
            sourceURL: document.absolutePath.map { URL(fileURLWithPath: $0) },
            resourceRoot: resourceRoot,
            isReadOnly: document.isReadOnly,
            catalog: uiCatalog
        )
        model.onPresentModifierPicker = { [weak self, weak model] nodeID in
            guard let self, let model else {
                return
            }
            self.modifierPickerRequest = .init(model: model, nodeID: nodeID)
        }
        model.onHistoryChange = { [weak self] redo in
            if redo {
                self?.achievementRedos.insert(document.id)
            } else {
                self?.achievementRedos.remove(document.id)
            }
        }
        model.onChange = { [weak self] content in
            self?
                .updateTextDocument(id: document.id) {
                    $0.content = content
                    $0.isDirty = content != $0.lastSavedContent
                    $0.errorMessage = nil
                }
        }
        model.onOpenUI = { [weak self] url in
            guard let self, let content = try? String(contentsOf: url, encoding: .utf8) else {
                return
            }
            self.open(
                .ui(
                    EditorTextDocument(
                        id: "ui:\(url.path)",
                        title: url.lastPathComponent,
                        relativePath: url.lastPathComponent,
                        absolutePath: url.path,
                        language: .plainText,
                        content: content,
                        lastSavedContent: content,
                        errorMessage: nil
                    )
                )
            )
        }
        configureBindings(model, resourceRoot: resourceRoot, catalog: bindingCatalog)
        uiSceneModels[document.id] = model
        return model
    }

    private func configureBindings(_ model: EditorUISceneModel, resourceRoot: URL?, catalog: [EditorScriptableObjectDescriptor]) {
        let url = model.sourceURL
        model.onBindingOwners = { [weak self] in self?.uiBindingOwners(sourceURL: url, resourceRoot: resourceRoot, catalog: catalog) ?? [] }
        model.onBindingChange = { [weak self, weak model] owner, before, after in
            guard self?.replaceUIBindings(owner: owner, expected: before, replacement: after) == true else {
                return false
            }
            model?.bindingSceneDocumentIDs.insert(owner.documentID)
            return true
        }
    }
}
