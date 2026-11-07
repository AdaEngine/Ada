import assert from "node:assert/strict";
import { copyFile, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setImmediate } from "node:timers/promises";
import { pathToFileURL } from "node:url";
import test from "node:test";
import { Window } from "happy-dom";

async function runtimeFixture() {
  const directory = await mkdtemp(join(tmpdir(), "ada-player-startup-"));
  const source = new URL("../../../Plugins/AdaWebExportPlugin/Runtime/", import.meta.url);
  for (const name of ["studio-player.js", "studio-editor.js", "studio-editor-math.js"]) {
    await copyFile(new URL(name, source), join(directory, name));
  }
  await writeFile(join(directory, "package.json"), '{"type":"module"}');
  await writeFile(join(directory, "main.js"),
    'globalThis.__fixtureStarted();\nawait globalThis.__fixtureStartup;\nconsole.log("[AdaWebPlayer] Ready: fixture");\n');
  const origin = "https://studio.example";
  const window = new Window({
    url: "https://preview.example/studio-preview.html#studioParent=" + encodeURIComponent(origin),
  });
  const responses = [];
  const parent = { postMessage(value) { responses.push(value); } };
  let finishStartup, mainStarted;
  const started = new Promise(resolve => { mainStarted = resolve; });
  const startup = new Promise(resolve => { finishStartup = resolve; });
  let now = 0, timerID = 0;
  const timers = new Map();
  const globals = {
    window, document: window.document, location: window.location, parent,
    ResizeObserver: class { observe() {} },
    requestAnimationFrame: callback => queueMicrotask(() => callback(0)),
    fetch: async () => Response.json({ allowedOrigins: [origin] }),
    setTimeout: (callback, delay) => {
      const id = ++timerID;
      timers.set(id, { callback, at: now + delay });
      return id;
    },
    clearTimeout: id => timers.delete(id),
    setInterval: () => 0,
    __fixtureStarted: () => mainStarted(),
    __fixtureStartup: startup,
  };
  const extra = ["__adaStudioPreview", "__adaStudioFrameReady", "__adaStudioRequestID",
    "__adaSoloMode", "__adaStudioEditMode"];
  const saved = new Map([...Object.keys(globals), ...extra].map(name =>
    [name, Object.getOwnPropertyDescriptor(globalThis, name)]));
  const consoleMethods = new Map(["log", "info", "warn", "error"].map(name => [name, console[name]]));
  for (const [name, value] of Object.entries(globals)) {
    Object.defineProperty(globalThis, name, { configurable: true, writable: true, value });
  }
  await import(pathToFileURL(join(directory, "studio-player.js")).href);
  const flush = async () => { await setImmediate(); await setImmediate(); };
  return {
    responses, started, finishStartup,
    async load() {
      window.dispatchEvent(new window.MessageEvent("message", {
        source: parent, origin,
        data: {
          protocol: "ada-studio-preview-v1", id: "load",
          type: "load", payload: {
            formatVersion: 1, editMode: false, revision: "first",
            files: [{ path: ".ada/project.json", data: Buffer.from('{"build":{"system":"adascript"}}').toString("base64") }],
          },
        },
      }));
      await started;
    },
    advance(milliseconds) {
      now += milliseconds;
      for (const [id, timer] of [...timers]) {
        if (timer.at <= now) { timers.delete(id); timer.callback(); }
      }
    },
    flush,
    render() { globalThis.__adaStudioFrameReady(globalThis.__adaStudioRequestID); },
    async close() {
      for (const [name, descriptor] of saved) {
        if (descriptor) Object.defineProperty(globalThis, name, descriptor);
        else delete globalThis[name];
      }
      for (const [name, method] of consoleMethods) console[name] = method;
      await window.happyDOM.close();
      await rm(directory, { recursive: true, force: true });
    },
  };
}

test("cold WASM startup does not spend the completed-frame timeout", async () => {
  const runtime = await runtimeFixture();
  try {
    await runtime.load();
    runtime.advance(90_001);
    await runtime.flush();
    assert.equal(runtime.responses.length, 0);
    runtime.finishStartup();
    await runtime.flush();
    assert.equal(runtime.responses.length, 0, "startup alone is not a rendered frame");
    runtime.render();
    await runtime.flush();
    assert.equal(runtime.responses.length, 1);
    assert.equal(runtime.responses[0].value.ready, true);
  } finally { await runtime.close(); }
});

test("a running engine must still complete a frame within its deadline", async () => {
  const runtime = await runtimeFixture();
  try {
    await runtime.load();
    runtime.finishStartup();
    await runtime.flush();
    runtime.advance(89_999);
    await runtime.flush();
    assert.equal(runtime.responses.length, 0);
    runtime.advance(2);
    await runtime.flush();
    assert.equal(runtime.responses.length, 1);
    assert.equal(runtime.responses[0].error, "AdaEngine did not render the updated scene");
  } finally { await runtime.close(); }
});
