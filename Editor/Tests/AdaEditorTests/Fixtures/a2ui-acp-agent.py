#!/usr/bin/env python3
"""Deterministic ACP process for native A2UI QA; no model/network credentials required."""
import json
import os
import sys
import time

catalog = "https://adaengine.org/a2ui/catalogs/forms/v1"
session_id = "a2ui-workflow-session"
if "--fail-new" in sys.argv:
    with open(sys.argv[sys.argv.index("--fail-new") + 1], "w") as stream:
        stream.write(str(os.getpid()))

def emit(value):
    print(json.dumps(value), flush=True)

def message(text):
    emit({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session_id,
        "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}})

def envelope(kind, body):
    return json.dumps({"version": "v0.9.1", kind: body}, separators=(",", ":"))

def form():
    fields = [
        {"id": "root", "component": "Column", "spacing": 12, "children": ["heading", "npc-name", "npc-role", "npc-greeting", "repeatable", "npc-health", "generate"]},
        {"id": "heading", "component": "Text", "text": "Configure your NPC"},
        *[{"id": "npc-" + key, "component": "TextField", "placeholder": key.capitalize(), "text": {"path": "/npc/" + key}} for key in ("name", "greeting")],
        {"id": "npc-role", "component": "ChoicePicker", "label": "Role", "value": {"path": "/npc/role"}, "options": [
            {"label": "Guide", "value": "guide"}, {"label": "Merchant", "value": "merchant"}, {"label": "Guard", "value": "guard"}]},
        {"id": "npc-health", "component": "Slider", "value": {"path": "/npc/health"}, "min": 1, "max": 100, "step": 1},
        {"id": "repeatable", "component": "Toggle", "label": "Repeatable dialog", "value": {"path": "/npc/repeatable"}},
        {"id": "generate", "component": "Button", "text": "Generate preview", "action": {"event": {"name": "generate_npc_preview", "context": {key: {"path": "/npc/" + key} for key in ("name", "role", "greeting", "repeatable", "health")}}}}
    ]
    name_check = {"condition": {"call": "required", "args": {"value": {"path": "/npc/name"}}}, "message": "NPC name is required."}
    range_check = {"condition": {"call": "range", "args": {"value": {"path": "/npc/health"}, "min": 1, "max": 100}}, "message": "Health must be 1...100."}
    next(c for c in fields if c["id"] == "npc-name")["checks"] = [name_check]
    next(c for c in fields if c["id"] == "generate")["checks"] = [name_check, range_check]
    return "Configure the NPC below.\n```a2ui\n" + "\n".join([
        envelope("createSurface", {"surfaceId": "npc-config", "catalogId": catalog, "sendDataModel": True}),
        envelope("updateComponents", {"surfaceId": "npc-config", "components": fields}),
        envelope("updateDataModel", {"surfaceId": "npc-config", "value": {"npc": {"name": "Guide", "role": "guide", "health": 10, "greeting": "Welcome to the village", "repeatable": True}}})
    ]) + "\n```\n"

def preview(prompt):
    data_line = next(line for line in prompt.splitlines() if line.startswith("Envelope: "))
    action = json.loads(data_line[len("Envelope: "):])["action"]
    assert action["surfaceId"] == "npc-config", "wrong originating surface"
    assert action["context"]["name"] == "Ada Guide", "local edit was not sent"
    assert action["context"]["role"] == "merchant", "picker selection was not sent"
    assert action["context"]["health"] == 51, "slider value was not sent"
    fields = [
        {"id": "root", "component": "Column", "spacing": 16, "children": ["title", "greeting", "continue"]},
        {"id": "title", "component": "Text", "text": action["context"]["name"] + " dialog"},
        {"id": "greeting", "component": "Text", "text": action["context"]["greeting"]},
        {"id": "continue", "component": "Button", "text": "Continue", "action": {"event": {"name": "continue_dialog"}}}
    ]
    return "Here is an editable dialog preview.\n```a2ui\n" + "\n".join([
        envelope("createSurface", {"surfaceId": "npc-preview", "catalogId": catalog}),
        envelope("updateComponents", {"surfaceId": "npc-preview", "components": fields})
    ]) + "\n```\n"

for line in sys.stdin:
    req = json.loads(line)
    method = req.get("method")
    if method == "initialize":
        result = {"protocolVersion": 1, "agentCapabilities": {"loadSession": True}, "agentInfo": {"name": "A2UI workflow fixture", "version": "1"}}
    elif method in ("session/new", "session/load"):
        if "--fail-new" in sys.argv:
            emit({"jsonrpc": "2.0", "id": req["id"], "error": {"code": -32000, "message": "Fixture session setup failure"}})
            continue
        result = {"sessionId": session_id}
    elif method == "session/prompt":
        if "--probe-client" in sys.argv:
            path = sys.argv[sys.argv.index("--probe-client") + 1]
            emit({"jsonrpc": "2.0", "id": "read-probe", "method": "fs/read_text_file", "params": {"sessionId": session_id, "path": path}})
            response = json.loads(sys.stdin.readline())
            assert response.get("result", {}).get("content") == "delegate-alive", response.get("error")
        assert req["params"]["sessionId"] == session_id
        prompt = "\n".join(item.get("text", "") for item in req["params"]["prompt"])
        text = preview(prompt) if any(line.startswith("Envelope: ") for line in prompt.splitlines()) else form()
        for index in range(0, len(text), 37):
            message(text[index:index + 37])
            time.sleep(0.01)
        result = {"stopReason": "end_turn"}
    else:
        result = {}
    if "id" in req:
        emit({"jsonrpc": "2.0", "id": req["id"], "result": result})
