"""Generate and accept the model using a running native Ada Studio MCP server.

    python experiment.py generate --destination Assets/Models/Skeleton-next.glb
    python experiment.py capture

Open this project in Studio with --mcp-port=2516 first. No Python packages needed.
"""
import argparse
import json
import math
from pathlib import Path
import shutil
import time
import urllib.request
import urllib.parse

ROOT = Path(__file__).resolve().parent


class MCP:
    def __init__(self, endpoint):
        if urllib.parse.urlsplit(endpoint).scheme not in ("http", "https"):
            raise ValueError("The MCP endpoint must use HTTP or HTTPS")
        self.endpoint, self.session, self.sequence = endpoint, None, 0
        self.request("initialize", {
            "protocolVersion": "2024-11-05", "capabilities": {},
            "clientInfo": {"name": "procedural-skeleton-study", "version": "1"},
        })

    def request(self, method, params):
        self.sequence += 1
        headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
        if self.session:
            headers["Mcp-Session-Id"] = self.session
        payload = {"jsonrpc": "2.0", "id": self.sequence, "method": method, "params": params}
        request = urllib.request.Request(self.endpoint, headers=headers, data=json.dumps(payload).encode())
        with urllib.request.urlopen(request, timeout=60) as response:
            self.session = response.headers.get("Mcp-Session-Id", self.session)
            body = response.read().decode()
        if body.startswith(("event:", "data:")):
            body = next(line[5:].strip() for line in body.splitlines() if line.startswith("data:"))
        reply = json.loads(body)
        if "error" in reply:
            raise RuntimeError(reply["error"])
        return reply["result"]

    def tool(self, name, **arguments):
        result = self.request("tools/call", {"name": name, "arguments": arguments})
        text = next(item["text"] for item in result["content"] if item["type"] == "text")
        if result.get("isError"):
            raise RuntimeError(text)
        return json.loads(text)


def save(name, payload):
    target = ROOT / "Evidence" / name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(payload, indent=2, ensure_ascii=False)+"\n", encoding="utf-8")


def build(client):
    client.tool("editor.build.start")
    deadline = time.monotonic()+60
    while time.monotonic() < deadline:
        state = client.tool("editor.task.status")
        if not state["isWorkspaceTaskRunning"]:
            output = client.tool("editor.output.read", limit=40)
            if state.get("buildStep", {}).get("title") != "Completed":
                raise RuntimeError({"state": state, "output": output})
            return output
        time.sleep(.2)
    raise TimeoutError("Native project build exceeded 60 seconds")


def turn(client, degrees):
    half = math.radians(degrees)/2
    scene = client.tool("editor.scene.get")
    client.tool("editor.scene.apply", expectedRevision=scene["revision"], operations=[{
        "op": "setComponent", "entityID": "subject", "typeName": "AdaTransform.Transform",
        "payload": {"position": [0, 0, 0], "rotation": [0, math.sin(half), 0, math.cos(half)], "scale": [1, 1, 1]},
    }])


def capture(client):
    status = client.tool("editor.task.status")
    if status["isWorkspaceTaskRunning"] or status["playMode"] != "editing":
        client.tool("editor.task.stop")
    report = {"model": "Assets/Models/Skeleton.glb", "views": [], "limitations": [
        "Static multipart model; no skin, animation clips, retopology or texture maps.",
        "These checks do not prove manifold topology, absence of intersections, or reference similarity.",
    ]}
    validation = client.tool("editor.model.validate", path=report["model"])
    save("native-validation.json", validation)
    if not validation.get("valid"):
        raise RuntimeError("Native model validation failed")
    try:
        for name, degrees in [("front", 0), ("three-quarter", -28), ("side", -90), ("back", 180)]:
            turn(client, degrees)
            build(client)
            result = client.tool("editor.play.run_scenario", width=1280, height=960, maxDimension=1280,
                                 duration=.7, steps=[{"t": .4, "capture": name}],
                                 watch={"entities": ["Camera", "Skeleton minion"], "components": ["Transform"]})
            frames = result.get("frames", [])
            if (result["status"] != "completed" or result["errors"] or result["scriptErrorCount"]
                    or len(frames) != 1 or frames[0].get("uniform", True) or "error" in frames[0]):
                raise RuntimeError(result)
            target = ROOT / "Evidence" / f"{name}.png"
            shutil.copy2(frames[0]["path"], target)
            save(f"session-{name}.json", result)
            report["views"].append({"yawDegrees": degrees, "savedAs": target.name, **frames[0]})
            print(f"{name}: native GPU {frames[0]['width']}x{frames[0]['height']}", flush=True)
    finally:
        turn(client, -28)
        build(client)
        save("capture-report.json", report)
    client.tool("editor.play.start")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["generate", "capture"])
    parser.add_argument("--endpoint", default="http://127.0.0.1:2516/mcp")
    parser.add_argument("--destination", default="Assets/Models/Skeleton.glb")
    args = parser.parse_args()
    client = MCP(args.endpoint)
    context = client.tool("editor.project.context")
    if Path(context["projectPath"]).resolve() != ROOT:
        raise RuntimeError("The MCP endpoint has a different project open")
    if args.action == "capture":
        settings = json.loads((ROOT / ".ada/project.json").read_text(encoding="utf-8"))
        if (context["activeDocument"]["path"] != "Assets/Scenes/Showcase.ascn"
                or settings["runtime"]["entry"]["scene"] != "Assets/Scenes/Showcase.ascn"):
            raise RuntimeError("Static capture requires Showcase.ascn as both active scene and runtime entry; use rig_capture.py for Walk.ascn")
        capture(client)
    else:
        result = client.tool("editor.model.generate", source=(ROOT / "Generators/Skeleton.ada").read_text(encoding="utf-8"),
                             destination=args.destination)
        save("generation.json", result)
        validation = client.tool("editor.model.validate", path=result["path"])
        save("native-validation.json", validation)
        if not validation.get("valid"):
            raise RuntimeError("Native import failed")
        print(f"{result['path']}: {result['triangleCount']} triangles, {result['vertexCount']} vertices")


if __name__ == "__main__":
    main()
