import assert from "node:assert/strict";
import { createReadStream } from "node:fs";
import { mkdir, stat } from "node:fs/promises";
import { createServer } from "node:http";
import { createRequire } from "node:module";
import { extname, resolve, sep } from "node:path";
import { test } from "node:test";
import { setTimeout } from "node:timers/promises";

const require = createRequire(import.meta.url);
const { chromium } = require(process.env.SAGA_PLAYWRIGHT ?? "playwright-core");
const expectedPhases = ["idle", "walk", "run", "jump", "fall", "land"];
const types = {
    ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript",
    ".wasm": "application/wasm", ".json": "application/json", ".png": "image/png",
};

test("GardenRobot's animation reaches the Chrome canvas", async t => {
    const bundle = resolve(process.env.GARDEN_ROBOT_BUNDLE);
    const output = process.env.GARDEN_ROBOT_SCREENSHOTS;
    if (output) await mkdir(output, { recursive: true });
    const server = createServer(async (request, response) => {
        const url = new URL(request.url, "http://127.0.0.1");
        const path = resolve(bundle, "." + decodeURIComponent(url.pathname));
        if (!path.startsWith(bundle + sep)) { response.writeHead(403).end(); return; }
        if (!(await stat(path).catch(() => null))?.isFile()) { response.writeHead(404).end(); return; }
        response.writeHead(200, { "content-type": types[extname(path)] ?? "application/octet-stream" });
        createReadStream(path).pipe(response);
    });
    await new Promise(done => server.listen(0, "127.0.0.1", done));
    t.after(() => server.close());
    const browser = await chromium.launch({
        executablePath: process.env.SAGA_CHROMIUM,
        args: ["--enable-unsafe-webgpu", "--enable-features=Vulkan"],
    });
    t.after(() => browser.close());
    const page = await browser.newPage({ viewport: { width: 1200, height: 700 }, deviceScaleFactor: 1 });
    const phaseFrames = new Map();
    const errors = [];
    let completed = false;
    page.on("pageerror", error => errors.push(error.message));
    page.on("console", message => {
        const phase = /^GardenRobot phase: (\w+)$/.exec(message.text())?.[1];
        if (completed || !expectedPhases.includes(phase)) return;
        completed = phase === "idle" && phaseFrames.has("land");
        if (!completed && phaseFrames.has(phase)) return;
        phaseFrames.set(phase, captureAfterPresentation(page, output && resolve(output, phase + ".png")));
    });
    await page.goto(`http://127.0.0.1:${server.address().port}/index.html?solo=1`);
    const deadline = Date.now() + 30_000;
    while (!completed && Date.now() < deadline) await setTimeout(100);
    assert.deepEqual(errors, []);
    assert.deepEqual([...phaseFrames.keys()], expectedPhases);
    assert.ok(completed, "GardenRobot did not return to idle after landing");

    const frames = [];
    const captures = await Promise.all(phaseFrames.values());
    for (const [index, phase] of expectedPhases.entries()) {
        const screenshot = captures[index];
        const frame = await page.evaluate(async base64 => {
            const bitmap = await createImageBitmap(await (await fetch("data:image/png;base64," + base64)).blob());
            const canvas = new OffscreenCanvas(240, 140);
            const context = canvas.getContext("2d");
            context.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
            bitmap.close();
            const pixels = context.getImageData(0, 0, canvas.width, canvas.height).data;
            const robot = [];
            let left = canvas.width;
            let top = canvas.height;
            for (let offset = 0; offset < pixels.length; offset += 4) {
                const red = pixels[offset];
                const green = pixels[offset + 1];
                const blue = pixels[offset + 2];
                if (red > 80 && red > green + 8 && green > blue + 12) {
                    const pixel = offset / 4;
                    robot.push(pixel);
                    left = Math.min(left, pixel % canvas.width);
                    top = Math.min(top, Math.floor(pixel / canvas.width));
                }
            }
            return robot.map(pixel => pixel - (top * canvas.width + left));
        }, screenshot.toString("base64"));
        assert.ok(frame.length >= 40, `GardenRobot was absent from the Chrome canvas during ${phase}`);
        frames.push(frame.join(","));
    }
    assert.ok(new Set(frames).size >= 4, "Chrome displayed fewer than four distinct GardenRobot poses");
});

async function captureAfterPresentation(page, path) {
    const previous = await page.evaluate(() => globalThis.__adaSAGAHost.metrics().presentedFrames);
    // SceneView reports the offscreen frame before the browser composites the window.
    await page.waitForFunction(
        frames => globalThis.__adaSAGAHost.metrics().presentedFrames > frames,
        previous,
        { timeout: 3_000 },
    ).catch(error => {
        if (error.name !== "TimeoutError") throw error;
        // Capture the stalled canvas so the pixel assertion reports what was visible.
    });
    return page.screenshot({ path });
}
