"""Accept live native playback, then render 24 fixed phases through native GPU skinning.

Run native_rig.py generate first, and open Assets/Scenes/Walk.ascn in Studio.
Only GIF encoding uses Pillow; rigging, clip evaluation and pixels come from AdaEngine.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

from experiment import MCP, build

ROOT = Path(__file__).resolve().parent
EVIDENCE = ROOT / "Evidence/Rig"
SCENE = "Assets/Scenes/Walk.ascn"
SOURCE = "@res://Models/Skeleton-Walk.glb"


def save(name, data):
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    (EVIDENCE / name).write_text(json.dumps(data, indent=2)+"\n", encoding="utf-8")


def select(client, source, clip):
    scene = client.tool("editor.scene.get", path=SCENE)
    client.tool("editor.scene.apply", path=SCENE, expectedRevision=scene["revision"], operations=[{
        "op": "setComponent", "entityID": "subject", "typeName": "AdaScene.Model3DSource",
        "payload": {"source": source, "animation": clip, "autoplay": True, "repeats": True},
    }])
    return build(client)


def scenario(client, **options):
    result = client.tool("editor.play.run_scenario", width=960, height=800, maxDimension=960, **options)
    if (result["status"] != "completed" or result["errors"] or result["scriptErrorCount"]
            or any(frame.get("uniform", True) or "error" in frame for frame in result["frames"])):
        raise RuntimeError(result)
    return result


def gif():
    from PIL import Image
    images = [Image.open(EVIDENCE / "frames" / f"frame-{index:02d}.png").convert("RGB") for index in range(24)]
    palette = images[0].quantize(colors=256)
    frames = [frame.quantize(palette=palette) for frame in images]
    frames[0].save(EVIDENCE / "walk.gif", save_all=True, append_images=frames[1:], duration=50, loop=0, disposal=2)
    for image in images:
        image.close()


def main():
    global EVIDENCE, SOURCE
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", default="http://127.0.0.1:2516/mcp")
    parser.add_argument("--asset", default="Assets/Models/Skeleton-Walk.glb")
    parser.add_argument("--evidence", type=Path, default=EVIDENCE)
    parser.add_argument("--live-only", action="store_true", help="Capture playback and bind pose without the Swift baseline's 24 fixed phases")
    args = parser.parse_args()
    source_path = Path(args.asset)
    if source_path.is_absolute() or source_path.parts[:2] != ("Assets", "Models") or ".." in source_path.parts:
        parser.error("--asset must be a project-relative Assets/Models GLB")
    if not args.live_only and source_path.name != "Skeleton-Walk.glb":
        parser.error("Alternative assets need --live-only; fixed CapturePose clips belong to the Swift baseline")
    SOURCE = "@res://" + source_path.relative_to("Assets").as_posix()
    evidence_path = args.evidence if args.evidence.is_absolute() else ROOT / args.evidence
    EVIDENCE = evidence_path
    client = MCP(args.endpoint)
    context = client.tool("editor.project.context")
    if Path(context["projectPath"]).resolve() != ROOT or context["activeDocument"]["path"] != SCENE:
        raise RuntimeError("Open this project's Walk.ascn in Studio before capturing")
    status = client.tool("editor.task.status")
    if status["isWorkspaceTaskRunning"] or status["playMode"] != "editing":
        client.tool("editor.task.stop")
    validation = client.tool("editor.model.validate", path=source_path.as_posix())
    save("native-validation.json", validation)
    if not validation.get("valid") or validation["counts"]["skins"] != 1 or validation["skins"][0]["jointCount"] != 23:
        raise RuntimeError("Rig import/profile contract failed")
    report = {"renderer": client.tool("render_graph.get")["backend"], "frames": [],
              "method": "Live Walk and BindPose, rendered by native GPU skinning." if args.live_only else
                        "Fixed CapturePose clips sampled from every second Walk key; rendered by native skinning, 20 fps.",
              "sourceSha256": hashlib.sha256((ROOT / source_path).read_bytes()).hexdigest()}
    try:
        select(client, SOURCE, "Walk")
        live = scenario(client, duration=3, steps=[
            {"t": .4, "snapshot": "a"}, {"t": .8, "capture": "walk-live-a"},
            {"t": 1.3, "snapshot": "b"}, {"t": 1.8, "capture": "walk-live-b"},
            {"t": 2.5, "snapshot": "c"},
        ], watch={"entities": ["Rig.hips", "Rig.leftHip", "Rig.rightHip", "Rig.leftKnee", "Rig.rightKnee",
                                "Rig.leftAnkle", "Rig.rightAnkle", "Rig.leftHand", "Rig.rightHand"],
                  "components": ["Transform"]})
        save("live-motion.json", live)
        report["liveFrames"] = live["frames"]
        for frame in live["frames"]:
            shutil.copy2(frame["path"], EVIDENCE / (frame["label"] + ".png"))
        hips = [next(e for e in snapshot["entities"] if e["name"] == "Rig.leftHip") for snapshot in live["snapshots"]]
        rotations = {tuple(entity["componentFields"]["AdaTransform.Transform"]["rotation"]) for entity in hips}
        if len(rotations) < 2 or live["snapshots"][-1]["frameSequence"] <= live["snapshots"][0]["frameSequence"]:
            raise RuntimeError("Live animation did not advance")
        report["liveDistinctHipPoses"] = len(rotations)
        print(f"Live Walk: {len(rotations)} distinct sampled hip poses; no script errors", flush=True)
        select(client, SOURCE, "BindPose")
        bind = scenario(client, duration=.3, steps=[{"t": .15, "capture": "bind-pose"}], watch={"entities": ["Rig.head"]})
        report["bindFrame"] = bind["frames"][0]
        shutil.copy2(bind["frames"][0]["path"], EVIDENCE / "bind-pose.png")
        (EVIDENCE / "frames").mkdir(parents=True, exist_ok=True)
        for frame in range(0 if args.live_only else 24):
            select(client, "@res://Models/Skeleton-Walk-samples.glb", f"CapturePose{frame}")
            result = scenario(client, duration=.25, steps=[{"t": .12, "capture": f"pose-{frame:02d}"}],
                              watch={"entities": ["Rig.leftAnkle", "Rig.rightAnkle"], "components": ["Transform"]})
            image = result["frames"][0]
            target = EVIDENCE / "frames" / f"frame-{frame:02d}.png"
            shutil.copy2(image["path"], target)
            report["frames"].append({**image, "poseTime": frame * .05, "savedAs": str(target.relative_to(EVIDENCE))})
            if frame % 4 == 0 or frame == 23:
                print(f"Native GPU phases: {frame+1}/24", flush=True)
        if not args.live_only:
            gif()
    finally:
        save("build-output.json", select(client, SOURCE, "Walk"))
        save("capture-report.json", report)
    client.tool("editor.play.start")


if __name__ == "__main__":
    main()
