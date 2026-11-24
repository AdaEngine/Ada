import json
import sys


def respond(request, result):
    print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)


def tool(name):
    return {
        "name": name,
        "description": "Echo a string",
        "inputSchema": {
            "type": "object",
            "properties": {"value": {"type": "string", "maxLength": 40}},
            "required": ["value"],
            "additionalProperties": False,
        },
    }


initialized = False
for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    params = request.get("params", {})
    if method == "initialize":
        respond(request, {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "Fixture", "version": "1"}})
    elif method == "notifications/initialized":
        initialized = True
    elif method == "tools/list" and initialized:
        if params.get("cursor") == "second":
            respond(request, {"tools": [tool("second")]})
        else:
            respond(request, {"tools": [tool("echo")], "nextCursor": "second"})
    elif method == "tools/call" and initialized:
        respond(request, {"structuredContent": {"server": sys.argv[1], "value": params["arguments"]["value"]}, "content": []})
