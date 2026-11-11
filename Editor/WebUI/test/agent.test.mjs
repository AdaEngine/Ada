import test from "node:test";
import assert from "node:assert/strict";
import { runAgent, runTool, tools } from "../src/agent.js";
import { Document, template, file, scene } from "../src/documents.js";
import { decode } from "../src/platform.js";
import { readFile } from "node:fs/promises";
import { Studio } from "../src/studio.js";
import { groupedTools } from "../src/ada-ai-tools.js";
import toolContract from "../../Sources/AdaEditor/Assets/AdaAIToolContract.json" with { type: "json" };
const contract = JSON.parse(
  await readFile(new URL("../assets/agent-contract.json", import.meta.url)),
);
globalThis.fetch = async () => Response.json({ contract, skills: [] });

test("agent file and scene tools enter the same document undo history", async () => {
  const document = new Document(template(2));
  let edits = 0;
  const studio = {
    document,
    preview: { frame: {}, message: async () => ({ valid: true }) },
    get snapshot() {
      return document.snapshot;
    },
    get scene() {
      return scene(document.snapshot);
    },
    changed() {
      edits++;
    },
    editScene(fn) {
      document.scene(fn);
      edits++;
    },
  };
  await runTool(studio, "editor_file_write", {
    path: "Sources/Agent.ada",
    content: "// test",
  });
  const player = studio.scene.entities.find((e) => e.name === "Player");
  await runTool(studio, "editor_scene_set", {
    entity: player.id,
    component: "AdaTransform.Transform",
    field: "position",
    value: [7, 0, 0],
  });
  assert.equal(edits, 2);
  assert.equal(
    studio.scene.entities.find((e) => e.id === player.id).components[
      "AdaTransform.Transform"
    ].position[0],
    7,
  );
  document.undo();
  assert.equal(
    studio.scene.entities.find((e) => e.id === player.id).components[
      "AdaTransform.Transform"
    ].position[0],
    0,
  );
  assert.equal(
    decode(file(studio.snapshot, "Sources/Agent.ada").data),
    "// test",
  );
  document.undo();
  assert.equal(file(studio.snapshot, "Sources/Agent.ada"), undefined);
  await assert.rejects(
    runTool(studio, "editor_publish", {}),
    /Unavailable tool/,
  );
  await assert.rejects(
    runTool(studio, "editor_file_write", {
      path: "../escape.ada",
      content: "bad",
    }),
    /Invalid/,
  );
});
test("agent clears running state even when appending to a full conversation fails", async () => {
  let saved = false,
    failure;
  const studio = {
    providerID: "fixture",
    model: { tools: true },
    billingMode: "ada",
    document: {},
    snapshot: { messages: [] },
    append() {
      throw new Error("История чата превышает лимит проекта");
    },
    emit() {},
    fail(e) {
      failure = e.message;
    },
    async save(checkpoint) {
      saved = checkpoint;
    },
  };
  await runAgent(studio, "Обнови игру");
  assert.equal(studio.running, false);
  assert.equal(studio.agent, null);
  assert.equal(saved, true);
  assert.match(failure, /Chat history|История чата/);
});

test("hosted grouped actions use real project edits, action grants, and legacy history", async () => {
  globalThis.window = { addEventListener() {} };
  const studio = new Studio();
  studio.providerID = "openrouter";
  studio.modelID = "coder";
  studio.providers = [
    {
      id: "openrouter",
      hosted: true,
      toolContract: 2,
      models: [{ id: "coder", tools: true }],
    },
  ];
  studio.document = new Document(template(2));
  studio.workspace = { id: "project", revision: 1 };
  studio.account = { id: "owner" };
  studio.changed = () => {};
  studio.emit = () => {};
  studio.save = async () => {};
  studio.fail = (error) => {
    throw error;
  };
  studio.preview = { frame: {}, message: async () => ({ valid: true }) };
  studio.refreshAI = async () => {
    studio.aiCatalog = { enabled: true, capabilities: ["llm"] };
    studio.aiBalance = { allowance: 500, available: 500 };
  };
  studio.updateChat((chat) => {
    chat.sessions[0].permission = "ask";
  });
  studio.play = async () => {
    studio.runtimeValidation = { valid: true };
  };
  const path = "Sources/Game.ada";
  studio.document.write(path, "// original");
  studio.document.append({
    role: "assistant",
    content: "Old activity",
    toolCalls: [
      { id: "legacy", function: { name: "editor_file_read", arguments: "{}" } },
    ],
  });
  studio.document.append({
    role: "tool",
    toolCallID: "legacy",
    content: "Previous result",
  });
  const prompts = [];
  const requestTool = studio.requestTool.bind(studio);
  studio.requestTool = (...args) => {
    const result = requestTool(...args);
    if (studio.permissionRequest) {
      prompts.push(studio.permissionRequest.name);
      studio.permissionRequest.decide(
        studio.permissionRequest.name === "editor_files/patch"
          ? "session"
          : null,
      );
    }
    return result;
  };
  const requests = [];
  const call = (id, name, action, args) => ({
    type: "tool",
    call: {
      id,
      function: {
        name,
        arguments: JSON.stringify({ action, arguments: args }),
      },
    },
  });
  globalThis.fetch = async (url, options) => {
    if (url === "./agent-resources.json")
      return Response.json({ contract, skills: [] });
    assert.equal(url, "/v1/ai/generate");
    requests.push(JSON.parse(options.body));
    const events =
      requests.length === 1
        ? [
            call("context", "editor_project", "context", {}),
            call("read", "editor_files", "read", { path }),
            call("bad", "editor_files", "patch", {
              path,
              oldText: "// original",
              newText: 5,
            }),
            call("patch", "editor_files", "patch", {
              path,
              oldText: "// original",
              newText: "// edited",
            }),
            call("delete", "editor_files", "delete", { path }),
            call("build", "editor_task", "build", {}),
          ]
        : [{ type: "text", text: "Done" }];
    events.push({ type: "complete" });
    return new Response(
      events.map((event) => "data: " + JSON.stringify(event) + "\n").join(""),
    );
  };
  assert.equal(await runAgent(studio, "Read, patch and build"), true);
  assert.deepEqual(prompts, ["editor_files/patch", "editor_files/delete"]);
  const result = (id) =>
    JSON.parse(requests[1].messages.find((m) => m.toolCallID === id).content);
  assert.equal(result("patch").saved, true, result("patch").error);
  assert.equal(decode(file(studio.snapshot, path).data), "// edited");
  assert.ok(
    requests[0].messages.some((m) => m.content.includes("Old activity")),
  );
  assert.ok(
    requests[0].messages.every(
      (m) => m.toolCallID !== "legacy" && !m.toolCalls,
    ),
  );
  assert.deepEqual(result("read"), { path, content: "// original" });
  assert.match(result("bad").error, /Invalid tool arguments/);
  assert.match(result("delete").error, /declined/);
  assert.equal(result("build").ok, true);
  assert.equal(typeof result("context").project.name, "string");
  assert.ok(
    studio.chat.events.some(
      (event) => event.id === "delete" && event.summary.includes(path),
    ),
  );
  assert.ok(studio.snapshot.messages.some((m) => m.toolCallID === "legacy"));
  assert.deepEqual(
    requests[0].tools,
    groupedTools({ planning: false, vision: false }).definitions,
  );
  delete studio.providers[0].toolContract;
  assert.equal(await runAgent(studio, "Continue on the legacy server"), true);
  const legacy = requests.at(-1);
  assert.equal(legacy.toolContract, undefined);
  assert.ok(
    legacy.tools.some((tool) => tool.function.name === "editor_file_read"),
  );
  assert.ok(
    !legacy.tools.some((tool) => tool.function.name === "editor_project_apply"),
  );
  assert.ok(
    legacy.messages.every(
      (message) =>
        !message.toolCalls?.some(
          (tool) => tool.function.name === "editor_files",
        ),
    ),
  );
});

test("the shared catalog accounts for every Web action and excludes vision for Coder Next", () => {
  const bindings = toolContract.families.flatMap(({ actions }) =>
    actions.map(({ bindings }) => bindings.web).filter(Boolean),
  );
  assert.deepEqual(
    new Set(bindings),
    new Set(tools.map((tool) => tool.function.name)),
  );
  assert.equal(toolContract.families.length, 17);
  const { families } = groupedTools({ planning: false, vision: false });
  assert.ok(
    [...families.values()].every(({ actions }) =>
      actions.every(({ vision }) => !vision),
    ),
  );
  assert.ok(!families.has("editor_simulation"));
  assert.ok(!families.has("editor_web"));
});
