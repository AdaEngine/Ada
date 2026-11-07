@tool(id: "studio.ik-helper", name: "IK Helper", version: "1.0.0", api: 2,
    platforms: ["macos", "windows"],
    permissions: ["editor.animations.read", "editor.animations.write", "editor.animations.preview", "editor.documents.read", "editor.documents.write"])
class IKHelper {
    @export var path = "Assets/Arm.animmod";
    @export var modelPath = "Assets/Robot.glb";
    @export var rootBone = "";
    @export var middleBone = "";
    @export var endBone = "";
    @export var entityID = "robot";
    @export var targetEntity = "target";
    @export var targetX = 1.0;
    @export var targetY = 1.0;
    @export var targetZ = 0.0;
    @export var revision = "";
    @export var job = "";
    @export var status = "Create or Inspect, then Poll. Use stable bone IDs from the Inspector or agent inspection.";

    func activate(editor) { editor.addPanel(id: "ik-helper", title: "IK Helper", location: "right", ui: "IKHelper.ui"); }
    func create(editor) { job = editor.animations.submit(["action": "modifierCreate", "path": path, "modelPath": modelPath]); }
    func inspect(editor) { job = editor.animations.submit(["action": "modifierInspect", "path": path, "limit": 32]); }
    func addTwoBone(editor) {
        job = editor.animations.submit(["action": "modifierApply", "path": path, "expectedRevision": revision,
            "modifierOperations": [["kind": "add", "modifier": ["id": "arm", "kind": "twoBone",
                "joints": [rootBone, middleBone, endBone], "target": ["x": targetX, "y": targetY, "z": targetZ],
                "enabled": true, "influence": 1.0, "iterations": 16]]]]);
    }
    func sample(editor) { job = editor.animations.submit(["action": "modifierSample", "path": path, "limit": 8]); }
    func save(editor) { job = editor.animations.submit(["action": "modifierSave", "path": path, "expectedRevision": revision]); }
    func undo(editor) { job = editor.animations.submit(["action": "modifierUndo", "path": path, "expectedRevision": revision]); }
    func preview(editor) { job = editor.animations.submit(["action": "modifierPreview", "path": path, "expectedRevision": revision, "time": 0.0]); }
    func bind(editor) {
        job = editor.animations.submit(["action": "modifierBind", "path": path, "expectedRevision": revision,
            "scenePath": editor.scenePath, "sceneRevision": editor.sceneRevision, "entityID": entityID,
            "modifierBindings": ["arm": ["target": ["entity": targetEntity, "point": ["x": 0.0, "y": 0.0, "z": 0.0]]]]]);
    }
    func poll(editor) {
        if (job == "") { status = "No pending job."; return; }
        var envelope = editor.animations.poll(job);
        status = envelope["status"];
        if (status == "pending") { return; }
        job = "";
        if (status == "failed") { status = envelope["error"]; return; }
        var result = envelope["result"];
        if (result["revision"] != null) { revision = result["revision"]; }
        status = "Completed. Save is explicit. Samples are not rendered verification.";
    }
}
