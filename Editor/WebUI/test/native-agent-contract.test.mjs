import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { nativeAgentContract } from "../scripts/native-agent-contract.mjs";

const root = fileURLToPath(new URL("../../..", import.meta.url));

test("the real native snapshot is current, complete and preserves unsafe integer values as text", async () => {
  const value = await nativeAgentContract(root);
  assert.equal(value.components.length, 13);
  assert.equal(value.input.bindings.length, 146);
  assert.equal(value.runtimeAPI, 4);
  const space = value.input.bindings.find(
    (b) => b.kind === "key" && b.name === "space",
  );
  assert.deepEqual(space.encoded, { key: { _0: " " } });
  const physics = value.components.find(
    (c) => c.typeName === "AdaPhysics.PhysicsBody2DComponent",
  );
  assert.equal(
    physics.defaultPayload.filter.collisionBitMask,
    "18446744073709551615",
  );
  assert.match(physics.defaultPayloadJSON, /18446744073709551615/);
  const input = value.api.types.find((type) => type.name === "Input");
  assert.ok(
    input.members.find((member) => member.name === "isActionJustPressed"),
  );
  const example = value.examples.find((e) => e.id === "side-scroller-3d");
  assert.ok(example.files[".ada/project.json"]);
  assert.ok(Object.keys(example.files).some((file) => file.endsWith(".ascn")));
  assert.equal(value.fingerprint.length, 64);
  assert.equal(value.sourceHashes, undefined);
});

test("frontend export refuses a stale native source, malformed fingerprint and duplicate types", async (t) => {
  const folder = await mkdtemp(path.join(tmpdir(), "agent-contract-"));
  t.after(() => rm(folder, { recursive: true, force: true }));
  const destination = path.join(
    folder,
    "Editor/WebUI/assets/agent-contract.json",
  );
  const source = "Sources/AdaInput/InputKeyCodes.swift";
  const sourcePath = path.join(folder, source);
  await mkdir(path.dirname(destination), { recursive: true });
  await mkdir(path.dirname(sourcePath), { recursive: true });
  const value = JSON.parse(
    await readFile(path.join(root, "Editor/WebUI/assets/agent-contract.json")),
  );
  value.sourceHashes = {
    [source]: createHash("sha256").update("current source").digest("hex"),
  };
  await writeFile(sourcePath, "current source");
  await writeFile(destination, JSON.stringify(value));
  assert.equal((await nativeAgentContract(folder)).components.length, 13);
  await writeFile(sourcePath, "changed source");
  await assert.rejects(
    nativeAgentContract(folder),
    /stale: Sources\/AdaInput\/InputKeyCodes/,
  );
  value.sourceHashes = { "Sources/../../outside": "a".repeat(64) };
  await writeFile(destination, JSON.stringify(value));
  await assert.rejects(
    nativeAgentContract(folder),
    /Invalid native contract source fingerprint/,
  );
  value.components.push(value.components[0]);
  await writeFile(destination, JSON.stringify(value));
  await assert.rejects(
    nativeAgentContract(folder),
    /Duplicate native component/,
  );
});
