/// Version-1 transport envelope for editor authoring clients. Model references remain detached strings.
public struct AnimationAuthoringRequest: Codable, Equatable, Sendable {
    public enum Action: String, CaseIterable, Codable, Sendable {
        case inspect, create, extract, apply, capture, sample, validate, save, undo, redo, bind, preview, reload, discard
        case graphInspect, graphApply, graphPreview, graphUndo, graphRedo, graphBind
        case modifierInspect, modifierCreate, modifierApply, modifierSample, modifierSave, modifierUndo, modifierRedo
        case modifierPreview, modifierBind, modifierReload, modifierDiscard

        public var writesResource: Bool {
            switch self {
            case .create, .extract, .apply, .capture, .save, .undo, .redo, .reload, .discard, .graphApply, .graphUndo, .graphRedo: true
            case .modifierCreate, .modifierApply, .modifierSave, .modifierUndo, .modifierRedo, .modifierReload, .modifierDiscard: true
            default: false
            }
        }

        public var isReadOnly: Bool {
            self == .inspect || self == .sample || self == .validate || self == .graphInspect || self == .modifierInspect || self == .modifierSample
        }

        public var requiresPreviewPermission: Bool { self == .preview || self == .graphPreview || self == .modifierPreview }
        public var requiresSceneWritePermission: Bool { self == .bind || self == .graphBind || self == .modifierBind }

        public var isModifierAction: Bool {
            switch self {
            case .modifierInspect, .modifierCreate, .modifierApply, .modifierSample, .modifierSave, .modifierUndo, .modifierRedo,
                 .modifierPreview, .modifierBind, .modifierReload, .modifierDiscard: true
            default: false
            }
        }

        /// Graph actions address the open asset workspace; expectedRevision is its graph revision.
        public var isGraphAction: Bool {
            switch self {
            case .graphInspect, .graphApply, .graphPreview, .graphUndo, .graphRedo, .graphBind: true
            default: false
            }
        }
    }

    public var action: Action
    public var path: String
    public var expectedRevision: String?
    public var modelPath: String?
    public var sourceClip: String?
    public var name: String?
    public var clipID: String?
    public var trackID: String?
    public var time: Double?
    public var duration: Double?
    public var operations: [AnimationEdit]?
    public var scenePath: String?
    public var entityID: String?
    public var sceneRevision: String?
    public var offset: Int?
    public var limit: Int?
    public var discardChanges: Bool?
    public var graph: AnimationGraph?
    public var modifierOperations: [AnimationModifierEdit]?
    public var modifierBindings: [String: AnimationIKBinding3D]?

    public init(action: Action, path: String, expectedRevision: String? = nil, modelPath: String? = nil,
                sourceClip: String? = nil, name: String? = nil, clipID: String? = nil, trackID: String? = nil,
                time: Double? = nil, duration: Double? = nil, operations: [AnimationEdit]? = nil,
                scenePath: String? = nil, entityID: String? = nil, sceneRevision: String? = nil, offset: Int? = nil, limit: Int? = nil,
                discardChanges: Bool? = nil, graph: AnimationGraph? = nil, modifierOperations: [AnimationModifierEdit]? = nil,
                modifierBindings: [String: AnimationIKBinding3D]? = nil) {
        self.action = action
        self.path = path
        self.expectedRevision = expectedRevision
        self.modelPath = modelPath
        self.sourceClip = sourceClip
        self.name = name
        self.clipID = clipID
        self.trackID = trackID
        self.time = time
        self.duration = duration
        self.operations = operations
        self.scenePath = scenePath
        self.entityID = entityID
        self.sceneRevision = sceneRevision
        self.offset = offset
        self.limit = limit
        self.discardChanges = discardChanges
        self.graph = graph
        self.modifierOperations = modifierOperations
        self.modifierBindings = modifierBindings
    }
}
