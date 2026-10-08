import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { applyTheme } from "../apply-docc-theme.mjs";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, "../..");
const require = createRequire(import.meta.url);
const { lexAdaScriptLine } = require(path.join(repositoryRoot, "Documentation", "DocCTheme", "theme.js"));

test("applies theme assets and hosting-base-aware tags idempotently", async () => {
  const outputDirectory = await mkdtemp(path.join(os.tmpdir(), "adaengine-docc-theme-"));
  const nestedDirectory = path.join(outputDirectory, "documentation", "adaengine");
  await mkdir(nestedDirectory, { recursive: true });
  const html = '<!doctype html><html><head><script>var baseUrl = "/adaengine-docs/"</script><link href="/adaengine-docs/css/index.123.css" rel="stylesheet"></head><body></body></html>';
  await writeFile(path.join(outputDirectory, "index.html"), html);
  await writeFile(path.join(nestedDirectory, "index.html"), html);

  assert.equal(await applyTheme(outputDirectory), 2);
  assert.equal(await applyTheme(outputDirectory), 2);

  const themedHTML = await readFile(path.join(nestedDirectory, "index.html"), "utf8");
  assert.equal(themedHTML.match(/adaengine-theme\.css/g)?.length, 1);
  assert.equal(themedHTML.match(/adaengine-docc-theme\.js/g)?.length, 1);
  assert.match(themedHTML, /href="\/adaengine-docs\/css\/adaengine-theme\.css"/);
  assert.match(themedHTML, /src="\/adaengine-docs\/js\/adaengine-docc-theme\.js"/);
  assert.match(await readFile(path.join(outputDirectory, "css", "adaengine-theme.css"), "utf8"), /--ada-theme-background/);
  assert.match(await readFile(path.join(outputDirectory, "js", "adaengine-docc-theme.js"), "utf8"), /lexAdaScriptLine/);
});

test("highlights AdaScript keywords, annotations, types, values, and nested comments", () => {
  const state = { blockCommentDepth: 0 };
  const firstLine = lexAdaScriptLine('@system class MovementSystem { var speed = 12.5; /* outer /* nested */', state);
  const secondLine = lexAdaScriptLine('comment */ const name = "AdaScript"; // tail', state);

  assert.ok(firstLine.some((token) => token.type === "annotation" && token.text === "@system"));
  assert.ok(firstLine.some((token) => token.type === "keyword" && token.text === "class"));
  assert.ok(firstLine.some((token) => token.type === "type" && token.text === "MovementSystem"));
  assert.ok(firstLine.some((token) => token.type === "number" && token.text === "12.5"));
  assert.equal(state.blockCommentDepth, 0);
  assert.ok(secondLine.some((token) => token.type === "string" && token.text === '"AdaScript"'));
  assert.ok(secondLine.some((token) => token.type === "comment" && token.text === "// tail"));
});
