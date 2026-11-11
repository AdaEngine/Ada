import assert from "node:assert/strict";
import test from "node:test";
import { runAgent } from "../src/agent.js";
import { Document, file, template } from "../src/documents.js";
import { Studio } from "../src/studio.js";

function harness() {
  globalThis.window = { addEventListener() {} };
  const studio = new Studio();
  studio.document = new Document(template(3));
  studio.workspace = { id: "project", revision: 1 };
  studio.account = { id: "owner" };
  studio.changed = () => {};
  studio.emit = () => {};
  studio.save = async () => {};
  studio.providerID = "openrouter";
  studio.modelID = "coder";
  studio.providers = [
    { id: "openrouter", models: [{ id: "coder", tools: true }] },
  ];
  studio.updateChat(() => {});
  return studio;
}

test("hosted tool contract groups actions and enforces Plan before dispatch", async () => {
  const s = harness();
  s.billingMode = "ada";
  s.providers[0].hosted = true;
  s.providers[0].toolContract = 2;
  s.providers[0].models[0].vision = false;
  s.refreshAI = async () => {
    s.aiCatalog = { enabled: true, capabilities: ["llm"] };
    s.aiBalance = { allowance: 500, available: 500 };
  };
  s.updateChat((c) => {
    c.sessions[0].mode = "plan";
  });
  const requests = [];
  const path = "Sources/Unauthorized.ada";
  globalThis.fetch = async (url, options) => {
    if (url === "./agent-resources.json") return Response.json({ skills: [] });
    const request = JSON.parse(options.body);
    requests.push(request);
    if (requests.length > 1)
      return new Response(
        'data: {"type":"text","text":"Done"}\ndata: {"type":"complete"}\n',
      );
    const call = {
      id: "denied-write",
      function: {
        name: "editor_files",
        arguments: JSON.stringify({
          action: "create",
          arguments: { path, content: "// denied" },
        }),
      },
    };
    return new Response(
      `data: ${JSON.stringify({ type: "tool", call })}\ndata: {"type":"complete"}\n`,
    );
  };
  assert.equal(await runAgent(s, "Plan a game"), true);
  assert.equal(requests[0].toolContract, 2, "hosted v2 contract");
  assert.equal(requests[0].toolHost, "web");
  assert.ok(requests[0].tools.length <= 17);
  const files = requests[0].tools.find(
    (tool) => tool.function.name === "editor_files",
  );
  assert.deepEqual(files.function.parameters.properties.action.enum, [
    "list",
    "search",
    "read",
  ]);
  assert.match(
    requests[1].messages.find(
      (message) => message.toolCallID === "denied-write",
    ).content,
    /Unavailable tool/,
  );
  assert.equal(file(s.snapshot, path), undefined);
});
