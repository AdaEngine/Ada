import AdaEngine
import Foundation
import MCP

/// Native desktop animation authoring uses the same revisioned drafts as Animator and project Tools.
@MainActor
enum EditorAgentAnimationTools {
    static var capabilities: [String: Any] {
        ["formats": ["animlib", "animmod"], "tools": tools().map(\.name), "toolAPI": 2,
         "clients": ["Animator", "editor agent", "project Tools"], "save": "Explicit, revision-checked resource Save; scene binding is a separate transaction.",
         "verification": "CPU samples and preview acknowledgements do not prove pixels. Capture the loaded viewport and verify visible Play."]
    }

    static var modelCapabilities: [String: Any] {
        var result = EditorAgentModelToolService.capabilities
        result["unavailable"] = (result["unavailable"] as? [String])?.map {
            $0 == "visual imported rig/keyframe editing" ? "visual rig structure editing" : $0
        } ?? []
        return result
    }

    static func tools() -> [Tool] {
        AnimationAuthoringRequest.Action.allCases.map { action in
            Tool(name: "editor.animation.\(action.rawValue)",
                 description: description(action),
                 inputSchema: .object(["type": "object", "properties": .object([
                    "requestJSON": .object(["type": "string", "description": .string(
                        "JSON AnimationAuthoringRequest, at most 64 KiB. action must match the tool name; path is project-relative inside Assets. "
                        + "Inspect for revision and stable IDs before editing. Mutations require expectedRevision; save is explicit.")])
                 ]), "required": .array([.string("requestJSON")])]),
                 annotations: .init(readOnlyHint: action.isReadOnly))
        }
    }

    static func execute(name: String, arguments: [String: Value], viewModel: EditorViewModel) async throws -> [String: Any] {
        guard let text = arguments["requestJSON"]?.stringValue, text.utf8.count <= 65_536,
            let service = viewModel.workbench.animationService else {
            throw Failure("Open a native project and provide requestJSON (at most 64 KiB).")
        }
        let request = try JSONDecoder().decode(AnimationAuthoringRequest.self, from: Data(text.utf8))
        guard name == "editor.animation.\(request.action.rawValue)" else { throw Failure("Request action must match the tool name.") }
        return try await service.execute(request, workbench: viewModel.workbench)
    }

    private static func description(_ action: AnimationAuthoringRequest.Action) -> String {
        switch action {
        case .modifierInspect: "Inspect a .animmod draft: revision, full rig binding, ordered paginated modifiers and history state."
        case .modifierCreate: "Create an unsaved .animmod draft from modelPath (.glb/.gltf), preserving the source model."
        case .modifierApply: "Apply modifierOperations (add/remove/move/update) atomically with expectedRevision. Maximum 32 constraints and 64 segments per chain; stable IDs."
        case .modifierSample: "Sample .animmod from rest or imported sourceClip at finite time. Returns paginated poses and solver/reach diagnostics, not rendered proof."
        case .modifierSave: "Save .animmod with expectedRevision, rejecting external disk changes."
        case .modifierUndo, .modifierRedo: "Move the shared IK history with expectedRevision."
        case .modifierReload: "Reload IK from disk with expectedRevision; dirty drafts require discardChanges: true."
        case .modifierDiscard: "Discard IK draft with expectedRevision and discardChanges: true, without deleting the file."
        case .modifierPreview: "Preview the open IK workspace at finite time with expectedRevision. Capture the viewport for visual verification."
        case .modifierBind: "Bind saved compatible IK to scenePath/entityID with expectedRevision and sceneRevision. Optional modifierBindings use stable scene entity IDs and local offsets. One scene Undo transaction."
        case .inspect: "Inspect an animation draft: revision, clips, node bindings, tracks and paginated keys. Optional clipID/trackID and offset/limit (1...256)."
        case .create: "Create an unsaved rest-pose clip from modelPath into path (.animlib); optional name. Existing libraries require expectedRevision."
        case .extract: "Copy sourceClip from modelPath (.glb/.gltf) into a project .animlib draft. Source bytes stay unchanged."
        case .apply:
            "Atomically apply operations to a draft with expectedRevision. Operations: clip.create/duplicate/remove/configure, "
            + "track.create/remove/configure, key.put/remove. IDs are stable; key replacement is explicit."
        case .capture: "Capture a sampled clipID/time into a new pose clip; optional name/duration and required expectedRevision."
        case .sample: "Sample clipID at finite time without events. Returns paginated local TRS and morph weights; CPU samples do not prove rendered output."
        case .validate: "Validate draft schema; optional modelPath also checks exact rig compatibility."
        case .save: "Explicitly save a draft with expectedRevision. Rejects external disk changes."
        case .undo, .redo: "Move animation draft history with expectedRevision, producing a new revision."
        case .reload: "Reload an open library from disk with expectedRevision; dirty drafts require explicit discardChanges: true."
        case .discard: "Close and discard an open draft without writing or deleting its file. Requires expectedRevision and discardChanges: true."
        case .bind: "Bind a saved compatible library/clipID to an open Model3DSource entity using scenePath/entityID/sceneRevision and expectedRevision. Uses scene Undo history."
        case .preview: "Open the library viewport at clipID/time. Acknowledges the preview request; capture the viewport after load for visual proof."
        case .graphInspect: "Inspect an open GLB/glTF/animlib workspace graph: graph revision, root, paginated nodes, validity and resource revision. Open the asset first; wait until ready."
        case .graphApply: "Replace the open asset preview graph atomically using graph and its expectedRevision. Incomplete drafts retain validation diagnostics; source assets stay unchanged."
        case .graphUndo, .graphRedo: "Move the shared canvas graph/layout history using the current graph expectedRevision."
        case .graphPreview: "Activate the valid asset graph at finite time; requires graph expectedRevision. Acknowledgement does not verify rendered output."
        case .graphBind: "Apply the current graph to a compatible open scene Model3DSource using graph expectedRevision and scenePath/entityID/sceneRevision. Bound libraries must be saved. One scene Undo transaction."
        }
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
