@_spi(AdaEngine) import AdaEngine
import AdaPackageManifestTool
import Foundation
import Observation

@Observable
@MainActor
final class EditorInspectorSidebarViewModel {
    struct TransformField: Equatable {
        var field: EditorComponentField
        var value: String

        var label: String { field.label }

        init(field: EditorComponentField, value: String) {
            self.field = field
            self.value = value
        }

        init(label: String, value: String) {
            self.field = EditorComponentField(key: label.lowercased(), label: label, kind: .readOnly, isEditable: false)
            self.value = value
        }
    }

    struct SelectedEntity: Equatable {
        var editorID: String
        var name: String
        var componentNames: [String]
        var transformFields: [TransformField]
        var components: [ComponentSection]
        var addableComponents: [AddableComponent]
        var scriptableObjects: [ScriptableObjectSection] = []
        var addableScriptableObjects: [EditorScriptableObjectDescriptor] = []
        var gizmo: EditorGizmo?
        var hasExplicitGizmo: Bool
    }

    struct ComponentSection: Equatable {
        var typeName: String
        var displayName: String
        var fields: [ComponentField]
        var canRemove: Bool
    }

    struct ComponentField: Equatable {
        var typeName: String
        var field: EditorComponentField
        var value: String
    }

    struct AddableComponent: Equatable {
        var typeName: String
        var displayName: String
        var category: String
        var description: String
    }

    struct TextureAsset: Equatable, Identifiable {
        var id: String { reference }
        var name: String
        var reference: String
        var absolutePath: String
    }

    struct SceneAsset: Equatable, Identifiable {
        var id: String { reference }
        var name: String
        var reference: String
        var absolutePath: String
    }

    struct ScriptableObjectSection: Equatable {
        var identifier: String
        var displayName: String
        var fields: [ComponentField]
    }

    var transformFields: [TransformField]
    var scriptName: String
    var scriptDescription: String
    var selectedEntity: SelectedEntity?
    var isComponentPickerPresented = false
    var componentSearchText = ""
    var scriptableObjectCatalog: [EditorScriptableObjectDescriptor] = []
    var textureAssets: [TextureAsset] = []
    var sceneAssets: [SceneAsset] = []
    var uiSourcePaths: [String] = []
    var uiSceneFiles: [String: String] = [:]
    @ObservationIgnored var uiSourceContent: ((String) -> String?)?

    @ObservationIgnored
    var applyGizmoChange: ((EditorGizmo) -> Void)?
    @ObservationIgnored
    var addEntity: ((EditorSceneEntityPreset) -> Void)?
    @ObservationIgnored
    var addComponent: ((String) -> Void)?
    @ObservationIgnored
    var removeComponent: ((String) -> Void)?
    @ObservationIgnored
    var updateComponentField: ((String, EditorComponentField, String) -> Void)?
    @ObservationIgnored
    var addScriptableObject: ((EditorScriptableObjectDescriptor) -> Void)?
    @ObservationIgnored
    var removeScriptableObject: ((String) -> Void)?
    @ObservationIgnored
    var updateScriptableObjectField: ((String, EditorComponentField, String) -> Void)?
    @ObservationIgnored
    private var sceneViewportActionOwner: ObjectIdentifier?
    @ObservationIgnored
    private var vectorAxisDrafts: [VectorAxisDraftKey: String] = [:]
    // Read by the existing TextField bindings each frame, without rebuilding the Inspector tree.
    @ObservationIgnored
    private var liveTransformAxes: [String: [String]] = [:]

    init(
        transformFields: [TransformField] = [
            TransformField(label: "Position", value: "0.0, 1.2, -5.4"),
            TransformField(label: "Rotation", value: "0, 180, 0"),
        ],
        scriptName: String = AdaEngineStyleContent.inspectorScript,
        scriptDescription: String = AdaEngineStyleContent.inspectorScriptDescription
    ) {
        self.transformFields = transformFields
        self.scriptName = scriptName
        self.scriptDescription = scriptDescription
        self.selectedEntity = nil
    }

    var gizmoNameBinding: Binding<String> {
        Binding(
            get: { self.selectedEntity?.gizmo?.name ?? "" },
            set: { self.updateSelectedGizmo { $0.name = $1 }($0) }
        )
    }

    func selectEntity(_ entity: SelectedEntity?) {
        liveTransformAxes.removeAll(keepingCapacity: true)
        for field in entity?.transformFields ?? [] {
            liveTransformAxes[field.field.key] = vectorComponents(from: field.value, count: field.field.kind.vectorComponentCount)
        }
        selectedEntity = entity
        transformFields = entity?.transformFields ?? []
        vectorAxisDrafts.removeAll()
        if entity == nil {
            dismissComponentPicker()
        }
    }

    func updateLiveTransform(editorID: String, payload: EditorComponentPayload) {
        guard
            selectedEntity?.editorID == editorID,
            let descriptor = EditorComponentRegistry.descriptor(named: EditorBuiltInComponentType.transform)
        else {
            return
        }
        for field in descriptor.fields {
            liveTransformAxes[field.key] = vectorComponents(from: field.displayValue(in: payload), count: field.kind.vectorComponentCount)
            for axisIndex in 0..<field.kind.vectorComponentCount {
                vectorAxisDrafts[VectorAxisDraftKey(typeName: EditorBuiltInComponentType.transform, fieldKey: field.key, axisIndex: axisIndex)] = nil
            }
        }
    }

    func setSceneViewportActions(
        owner: AnyObject,
        applyGizmoChange: @escaping (EditorGizmo) -> Void,
        addEntity: @escaping (EditorSceneEntityPreset) -> Void,
        addComponent: @escaping (String) -> Void,
        removeComponent: @escaping (String) -> Void,
        updateComponentField: @escaping (String, EditorComponentField, String) -> Void,
        addScriptableObject: @escaping (EditorScriptableObjectDescriptor) -> Void,
        removeScriptableObject: @escaping (String) -> Void,
        updateScriptableObjectField: @escaping (String, EditorComponentField, String) -> Void
    ) {
        sceneViewportActionOwner = ObjectIdentifier(owner)
        self.applyGizmoChange = applyGizmoChange
        self.addEntity = addEntity
        self.addComponent = addComponent
        self.removeComponent = removeComponent
        self.updateComponentField = updateComponentField
        self.addScriptableObject = addScriptableObject
        self.removeScriptableObject = removeScriptableObject
        self.updateScriptableObjectField = updateScriptableObjectField
    }

    func clearSceneViewportActions(owner: AnyObject) {
        guard sceneViewportActionOwner == ObjectIdentifier(owner) else {
            return
        }

        sceneViewportActionOwner = nil
        applyGizmoChange = nil
        addEntity = nil
        addComponent = nil
        removeComponent = nil
        updateComponentField = nil
        addScriptableObject = nil
        removeScriptableObject = nil
        updateScriptableObjectField = nil
    }

    func addGizmo() {
        let gizmo = selectedEntity?.gizmo ?? EditorGizmo(name: selectedEntity?.name ?? "Gizmo", kind: .custom)
        updateGizmo(gizmo)
    }

    func addEntityRequested(_ preset: EditorSceneEntityPreset = .empty) {
        addEntity?(preset)
    }

    func addComponentRequested(_ typeName: String) {
        addComponent?(typeName)
    }

    var componentPickerPresentationBinding: Binding<Bool> {
        Binding(
            get: { self.isComponentPickerPresented },
            set: { isPresented in
                if isPresented {
                    self.presentComponentPicker()
                } else {
                    self.dismissComponentPicker()
                }
            }
        )
    }

    var componentSearchTextBinding: Binding<String> {
        Binding(
            get: { self.componentSearchText },
            set: { self.componentSearchText = $0 }
        )
    }

    func presentComponentPicker() {
        guard selectedEntity?.addableComponents.isEmpty == false else {
            return
        }
        componentSearchText = ""
        isComponentPickerPresented = true
    }

    func dismissComponentPicker() {
        isComponentPickerPresented = false
        componentSearchText = ""
    }

    func addableComponents(matching query: String) -> [AddableComponent] {
        let components = selectedEntity?.addableComponents ?? []
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else {
            return components
        }
        return components.filter {
            $0.displayName.lowercased().contains(normalizedQuery)
                || $0.category.lowercased().contains(normalizedQuery)
                || $0.description.lowercased().contains(normalizedQuery)
        }
    }

    func textureAssets(matching query: String) -> [TextureAsset] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else {
            return textureAssets
        }
        return textureAssets.filter {
            $0.name.lowercased().contains(normalizedQuery) || $0.reference.lowercased().contains(normalizedQuery)
        }
    }

    func textureAsset(droppedFileURL url: URL) -> TextureAsset? {
        let droppedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        return textureAssets.first {
            URL(fileURLWithPath: $0.absolutePath).resolvingSymlinksInPath().standardizedFileURL.path == droppedPath
        }
    }

    func sceneAssets(matching query: String) -> [SceneAsset] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else {
            return sceneAssets
        }
        return sceneAssets.filter {
            $0.name.lowercased().contains(normalizedQuery) || $0.reference.lowercased().contains(normalizedQuery)
        }
    }

    func removeComponentRequested(_ typeName: String) {
        removeComponent?(typeName)
    }

    func addScriptableObjectRequested(_ descriptor: EditorScriptableObjectDescriptor) {
        addScriptableObject?(descriptor)
    }

    func removeScriptableObjectRequested(_ identifier: String) {
        removeScriptableObject?(identifier)
    }

    func scriptableObjectFieldBinding(identifier: String, field: EditorComponentField) -> Binding<String> {
        Binding(
            get: {
                self.selectedEntity?
                    .scriptableObjects
                    .first { $0.identifier == identifier }?
                    .fields
                    .first { $0.field.key == field.key }?
                    .value ?? ""
            },
            set: { value in
                guard
                    let objectIndex = self.selectedEntity?.scriptableObjects.firstIndex(where: { $0.identifier == identifier }),
                    let fieldIndex = self.selectedEntity?.scriptableObjects[objectIndex].fields.firstIndex(where: { $0.field.key == field.key })
                else {
                    return
                }
                self.selectedEntity?.scriptableObjects[objectIndex].fields[fieldIndex].value = value
                self.updateScriptableObjectField?(identifier, field, value)
            }
        )
    }

    func componentFieldBinding(typeName: String, field: EditorComponentField) -> Binding<String> {
        Binding(
            get: {
                self.componentFieldValue(typeName: typeName, field: field)
            },
            set: { value in
                self.setComponentField(typeName: typeName, field: field, value: value)
            }
        )
    }

    func transformFieldBinding(_ field: TransformField) -> Binding<String> {
        componentFieldBinding(typeName: EditorBuiltInComponentType.transform, field: field.field)
    }

    func componentVectorAxisBinding(typeName: String, field: EditorComponentField, axisIndex: Int) -> Binding<String> {
        Binding(
            get: {
                let draftKey = VectorAxisDraftKey(typeName: typeName, fieldKey: field.key, axisIndex: axisIndex)
                if let draft = self.vectorAxisDrafts[draftKey] {
                    return draft
                }

                if typeName == EditorBuiltInComponentType.transform,
                    let axes = self.liveTransformAxes[field.key], axes.indices.contains(axisIndex) {
                    return axes[axisIndex]
                }

                let components = self.vectorComponents(
                    from: self.componentFieldValue(typeName: typeName, field: field),
                    count: field.kind.vectorComponentCount
                )
                guard components.indices.contains(axisIndex) else {
                    return ""
                }
                return components[axisIndex]
            },
            set: { value in
                self.setVectorAxis(typeName: typeName, field: field, axisIndex: axisIndex, value: value)
            }
        )
    }

    func transformVectorAxisBinding(field: TransformField, axisIndex: Int) -> Binding<String> {
        componentVectorAxisBinding(typeName: EditorBuiltInComponentType.transform, field: field.field, axisIndex: axisIndex)
    }

    private func componentFieldValue(typeName: String, field: EditorComponentField) -> String {
        if typeName == EditorBuiltInComponentType.transform, let axes = liveTransformAxes[field.key] {
            return axes.joined(separator: ", ")
        }
        return selectedEntity?
            .components
            .first { $0.typeName == typeName }?
            .fields
            .first { $0.field.key == field.key }?
            .value ?? ""
    }

    private func setComponentField(typeName: String, field: EditorComponentField, value: String) {
        guard
            let componentIndex = selectedEntity?.components.firstIndex(where: { $0.typeName == typeName }),
            let fieldIndex = selectedEntity?.components[componentIndex].fields.firstIndex(where: { $0.field.key == field.key })
        else {
            return
        }
        selectedEntity?.components[componentIndex].fields[fieldIndex].value = value
        if typeName == EditorBuiltInComponentType.transform {
            liveTransformAxes[field.key] = vectorComponents(from: value, count: field.kind.vectorComponentCount)
        }
        updateComponentField?(typeName, field, value)
    }

    private func setVectorAxis(typeName: String, field: EditorComponentField, axisIndex: Int, value: String) {
        let count = field.kind.vectorComponentCount
        guard axisIndex < count else {
            return
        }

        let draftKey = VectorAxisDraftKey(typeName: typeName, fieldKey: field.key, axisIndex: axisIndex)
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedValue.isEmpty || Double(trimmedValue) == nil {
            vectorAxisDrafts[draftKey] = value
            return
        }

        vectorAxisDrafts[draftKey] = nil
        var components = vectorComponents(from: componentFieldValue(typeName: typeName, field: field), count: count)
        components[axisIndex] = trimmedValue
        setComponentField(typeName: typeName, field: field, value: components.joined(separator: ", "))
    }

    private func vectorComponents(from value: String, count: Int) -> [String] {
        var components =
            value
            .split { $0 == "," || $0 == " " || $0 == "\t" }
            .map { String($0) }
        if components.count < count {
            components.append(contentsOf: Array(repeating: "0", count: count - components.count))
        }
        return Array(components.prefix(count))
    }

    func toggleGizmoEnabled() {
        updateSelectedGizmo { gizmo, _ in
            gizmo.isEnabled.toggle()
        }("")
    }

    func setGizmoKind(_ kind: EditorGizmoKind) {
        updateSelectedGizmo { gizmo, _ in
            gizmo.kind = kind
        }("")
    }

    private func updateSelectedGizmo(_ update: @escaping (inout EditorGizmo, String) -> Void) -> (String) -> Void {
        { value in
            guard var gizmo = self.selectedEntity?.gizmo else {
                var gizmo = EditorGizmo(name: self.selectedEntity?.name ?? "Gizmo", kind: .custom)
                update(&gizmo, value)
                self.updateGizmo(gizmo)
                return
            }
            update(&gizmo, value)
            self.updateGizmo(gizmo)
        }
    }

    private func updateGizmo(_ gizmo: EditorGizmo) {
        selectedEntity?.gizmo = gizmo
        selectedEntity?.hasExplicitGizmo = true
        applyGizmoChange?(gizmo)
    }
}

private struct VectorAxisDraftKey: Hashable {
    var typeName: String
    var fieldKey: String
    var axisIndex: Int
}

extension EditorComponentFieldKind {
    var vectorComponentCount: Int {
        switch self {
        case .vector2:
            return 2
        case .vector3:
            return 3
        case .vector4:
            return 4
        default:
            return 0
        }
    }
}
