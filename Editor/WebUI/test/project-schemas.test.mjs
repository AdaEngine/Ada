import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { projectSchemas } from "../src/project-schemas.js";
import { knowledge } from "../src/knowledge.js";
import { Document, template } from "../src/documents.js";

const contract = JSON.parse(
  await readFile(new URL("../assets/agent-contract.json", import.meta.url)),
);
globalThis.fetch = async () => Response.json({ contract });

test("built-in schemas and API member lookup stay available when the current scene is broken", async () => {
  const studio = { snapshot: { files: [] }, preview: { ready: false } };
  const components = await knowledge(studio, "editor_components_describe", {});
  assert.equal(components.total, 13);
  assert.equal(components.projectComponentsAvailable, false);
  assert.ok(
    components.components.find(
      (c) => c.typeName === "AdaPhysics.PhysicsBody2DComponent",
    ),
  );
  const api = await knowledge(studio, "editor_api_describe", {
    query: "isActionJustPressed",
  });
  assert.equal(api.types[0].name, "Input");
  assert.ok(
    api.types[0].members.find(
      (member) => member.name === "isActionJustPressed",
    ),
  );
  assert.equal(api.content, undefined);
});

test("project inspection uses current source text, caches by source content and never derives defaults from entity values", async () => {
  let calls = 0;
  const studio = {
    document: new Document(template(2)),
    preview: {
      ready: false,
      async message(type, payload) {
        calls++;
        assert.equal(type, "agent-tool");
        assert.equal(payload.name, "inspect-sources");
        assert.ok(
          payload.sources.every(
            (source) =>
              source.path.startsWith("Sources/") &&
              typeof source.source === "string",
          ),
        );
        return {
          schemas: [
            {
              typeName: "game.player",
              name: "Player",
              kind: "component",
              source: "Sources/Player.ada",
              fields: [{ name: "health", kind: "int" }],
              defaultPayload: { health: 100 },
            },
          ],
          validation: "production schema parser",
        };
      },
    },
  };
  studio.document.write(
    "Sources/Player.ada",
    '@component(id: "game.player") struct Player { @export var health = 100; }',
  );
  const first = await projectSchemas(studio);
  assert.equal(first.available, true);
  assert.equal(await projectSchemas(studio), first);
  assert.equal(calls, 1);
  studio.document.scene((scene) => {
    scene.entities[0].components["game.player"] = { health: 17 };
  });
  const described = await knowledge(studio, "editor_components_describe", {
    query: "game.player",
  });
  assert.equal(described.projectComponentsAvailable, true);
  assert.deepEqual(described.components[0].defaultPayload, { health: 100 });
  assert.equal(calls, 1);
  studio.document.write(
    "Sources/Player.ada",
    '@component(id: "game.player") struct Player { @export var health = 200; }',
  );
  await projectSchemas(studio);
  assert.equal(calls, 2);
});

test("inspection rejects a response for a changed source set or replaced project", async () => {
  for (const replace of [false, true]) {
    let finish;
    const studio = {
      document: new Document(template(2)),
      preview: {
        message: () =>
          new Promise((resolve) => {
            finish = resolve;
          }),
      },
    };
    const request = projectSchemas(studio);
    if (replace) studio.document = new Document(template(3));
    else studio.document.write("Sources/Changed.ada", "class Changed {}");
    finish({ schemas: [] });
    await assert.rejects(request, /Project changed/);
  }
});

test("missing Player support is reported explicitly while native built-ins remain discoverable", async () => {
  const studio = {
    document: new Document(template(2)),
    preview: {
      async message() {
        throw new Error("Update AdaPlayer");
      },
    },
  };
  const result = await knowledge(studio, "editor_components_describe", {});
  assert.equal(result.projectComponentsAvailable, false);
  assert.equal(result.total, 13);
  assert.match(result.diagnostic, /Update AdaPlayer/);
});
