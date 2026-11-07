@tool(
    id: "studio.animation-helper",
    name: "Animation Helper",
    version: "1.2.0",
    api: 2,
    platforms: ["macos", "windows"],
    permissions: ["editor.animations.read", "editor.animations.write", "editor.animations.preview", "editor.documents.read", "editor.documents.write"]
)
class AnimationHelper {
    @export var path = "Assets/Animations/Robot.animlib";
    @export var modelPath = "Assets/Robot.glb";
    @export var sourceClip = "Walk";
    @export var clipID = "";
    @export var trackID = "";
    @export var nodeID = "";
    @export var keyID = "";
    @export var keyTime = 0.0;
    @export var sampledRotationZ = 0.0;
    @export var entityID = "robot";
    @export var revision = "";
    @export var graphRevision = "";
    @export var job = "";
    @export var status = "Extract or inspect, then Poll. Save is explicit.";

    func activate(editor) {
        editor.addPanel(id: "animation-helper", title: "Animation Helper", location: "right", ui: "AnimationHelper.ui");
    }

    func inspect(editor) {
        job = editor.animations.submit(["action": "inspect", "path": path, "limit": 16]);
        status = "Inspection queued. Click Poll.";
    }

    func extract(editor) {
        job = editor.animations.submit(["action": "extract", "path": path, "modelPath": modelPath,
            "sourceClip": sourceClip, "expectedRevision": revision]);
        status = "Extraction queued. Click Poll.";
    }

    func inspectTracks(editor) {
        job = editor.animations.submit(["action": "inspect", "path": path, "clipID": clipID, "limit": 256]);
        status = "Track inspection queued. Click Poll.";
    }

    func inspectKeys(editor) {
        job = editor.animations.submit(["action": "inspect", "path": path, "clipID": clipID, "trackID": trackID, "limit": 1]);
        status = "Key inspection queued. Click Poll.";
    }

    func rotateBone(editor) {
        job = editor.animations.submit(["action": "apply", "path": path, "expectedRevision": revision,
            "operations": [["id": "rotate-bone", "kind": "key.put", "clipID": clipID, "trackID": trackID,
                "replaceExisting": true, "key": ["id": keyID, "time": keyTime,
                    "value": [0.0, 0.0, 0.7071067811865476, 0.7071067811865476]]]]]);
        status = "Local Z quarter-turn queued for the inspected rotation key. Click Poll.";
    }

    func sample(editor) {
        job = editor.animations.submit(["action": "sample", "path": path, "clipID": clipID, "time": keyTime, "offset": 0, "limit": 8]);
        status = "Pose sample queued. Click Poll.";
    }

    func bind(editor) {
        job = editor.animations.submit(["action": "bind", "path": path, "expectedRevision": revision,
            "clipID": clipID, "scenePath": editor.scenePath, "sceneRevision": editor.sceneRevision, "entityID": entityID]);
        status = "Saved clip binding queued for the open scene. Click Poll.";
    }

    func oneShot(editor) {
        job = editor.animations.submit(["action": "apply", "path": path, "expectedRevision": revision,
            "operations": [["id": "set-one-shot", "kind": "clip.configure", "clipID": clipID, "repeats": false]]]);
        status = "Edit queued. Click Poll, then Save when ready.";
    }

    func save(editor) {
        job = editor.animations.submit(["action": "save", "path": path, "expectedRevision": revision]);
        status = "Save queued. Click Poll.";
    }

    func preview(editor) {
        job = editor.animations.submit(["action": "preview", "path": path, "clipID": clipID, "time": 0.25]);
        status = "Preview queued. Click Poll, then inspect the viewport.";
    }

    func inspectGraph(editor) {
        job = editor.animations.submit(["action": "graphInspect", "path": modelPath, "limit": 16]);
        status = "Open the model viewport first. Graph inspection queued; click Poll.";
    }

    func halfWeightGraph(editor) {
        job = editor.animations.submit(["action": "graphApply", "path": modelPath, "expectedRevision": graphRevision,
            "graph": ["root": "Output", "nodes": [
                ["id": "Source", "kind": "clip", "clip": sourceClip, "speed": 1, "repeats": true, "inputs": [], "events": []],
                ["id": "Output", "kind": "blend", "clip": "", "speed": 1, "repeats": true,
                    "inputs": [["node": "Source", "weight": 0.5]], "events": []]]]]);
        status = "Replacing the preview graph with the imported clip at half weight. Click Poll.";
    }

    func previewGraph(editor) {
        job = editor.animations.submit(["action": "graphPreview", "path": modelPath, "expectedRevision": graphRevision, "time": 0.25]);
        status = "Graph preview queued. Click Poll, then inspect the viewport.";
    }

    func bindGraph(editor) {
        job = editor.animations.submit(["action": "graphBind", "path": modelPath, "expectedRevision": graphRevision,
            "scenePath": editor.scenePath, "sceneRevision": editor.sceneRevision, "entityID": entityID]);
        status = "Graph binding queued for the open scene. Click Poll; Save the scene explicitly.";
    }

    func poll(editor) {
        if (job == "") { status = "Submit an action first."; return; }
        var envelope = editor.animations.poll(job);
        status = envelope["status"];
        if (status == "pending") { return; }
        job = "";
        if (status == "failed") { status = envelope["error"]; return; }
        var result = envelope["result"];
        if (result["revision"] != null) {
            if (result["root"] != null) { graphRevision = result["revision"]; }
            else { revision = result["revision"]; }
        }
        if (result["createdClipID"] != null) { clipID = result["createdClipID"]; }
        if (result["clips"] != null && result["tracks"] == null && result["clips"].count > 0) {
            clipID = result["clips"][0]["id"];
        }
        if (result["tracks"] != null) {
            var tracks = result["tracks"];
            var i = 0;
            while (i < tracks.count) {
                if (tracks[i]["channel"] == "rotation") {
                    trackID = tracks[i]["id"]; nodeID = tracks[i]["nodeID"]; break;
                }
                i += 1;
            }
        }
        if (result["keys"] != null && result["keys"].count > 0) {
            keyID = result["keys"][0]["id"]; keyTime = result["keys"][0]["time"];
        }
        if (result["poses"] != null) {
            var poses = result["poses"];
            var i = 0;
            var found = false;
            while (i < poses.count) {
                if (poses[i]["nodeID"] == nodeID) {
                    sampledRotationZ = poses[i]["rotation"][2]; found = true; break;
                }
                i += 1;
            }
            var nextOffset = result["offset"] + poses.count;
            if (!found && poses.count > 0 && nextOffset < result["total"]) {
                job = editor.animations.submit(["action": "sample", "path": path, "clipID": clipID,
                    "time": keyTime, "offset": nextOffset, "limit": 8]);
                status = "Reading the next pose page. Click Poll.";
                return;
            }
            if (!found) { status = "The selected bone was not found in the sampled pose."; return; }
        }
        status = "Completed. Inspect the draft; Save writes it explicitly.";
    }
}
