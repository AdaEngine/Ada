// Golden-frame check for the SAGA browser renderer.
//
//   node script/web_golden_saga.mjs <web-player-bundle> [--record]
//
// <web-player-bundle> is an `AdaWebPlayer` export packed with Tests/WebGolden/SAGASmoke (see the README next to it).
// The bundle must contain `saga-golden.mjs` and `saga-webgpu.mjs` (shipped by the export plugin).
// With --record the settled frame replaces the golden PNG; otherwise it is compared with it and the exit code is
// 1 on mismatch.
//
// Needs `playwright-core` (or SAGA_PLAYWRIGHT=<path>) and a Chromium with WebGPU (SAGA_CHROMIUM=<executable>).
import { createReadStream } from "node:fs";
import { mkdir, stat, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { createRequire } from "node:module";
import { dirname, extname, join, normalize, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const args = process.argv.slice(2);
const record = args.includes("--record");
const bundle = args.find(arg => !arg.startsWith("--"));
if (!bundle) throw new Error("Pass the exported web player bundle directory");
const actualPath = args.find(arg => arg.startsWith("--actual="))?.slice("--actual=".length);

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const goldenPath = join(root, "Tests/AdaEngineTests/GoldenFrames/saga-browser/smoke-160x96.png");
const types = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".wasm": "application/wasm",
    ".json": "application/json", ".png": "image/png", ".wgsl": "text/plain", ".glb": "model/gltf-binary" };

const server = createServer(async (request, response) => {
    const url = new URL(request.url, "http://127.0.0.1");
    let path = normalize(join(resolve(bundle), decodeURIComponent(url.pathname)));
    if (url.pathname === "/golden/smoke-160x96.png" && !record) path = goldenPath;
    if (!path.startsWith(resolve(bundle)) && path !== goldenPath) { response.writeHead(403).end(); return; }
    try {
        if (!(await stat(path)).isFile()) throw new Error("not a file");
        response.writeHead(200, { "content-type": types[extname(path)] ?? "application/octet-stream", "cache-control": "no-store" });
        createReadStream(path).pipe(response);
    } catch {
        response.writeHead(404).end();
    }
});
await new Promise(done => server.listen(0, "127.0.0.1", done));
const origin = `http://127.0.0.1:${server.address().port}`;

const require = createRequire(import.meta.url);
const { chromium } = require(process.env.SAGA_PLAYWRIGHT ?? "playwright-core");
const browser = await chromium.launch({
    executablePath: process.env.SAGA_CHROMIUM,
    args: ["--enable-unsafe-webgpu", "--enable-features=Vulkan", ...(process.platform === "darwin" ? ["--use-angle=metal"] : [])],
});
let failed = false;
try {
    // Preserve the projection of the original smoke reference before downsampling.
    const page = await browser.newPage({ viewport: { width: 1369, height: 829 }, deviceScaleFactor: 1 });
    page.on("console", message => { if (message.type() === "error") console.error("[page]", message.text()); });
    page.on("pageerror", error => console.error("[page]", error.message));
    await page.goto(`${origin}/index.html?solo=1`);
    const startup = await page.waitForFunction(() => {
        const loader = document.querySelector("#ada-loader[data-state='error']");
        if (loader) return { error: loader.innerText };
        return globalThis.__adaSAGAHost?.metrics?.().presentedFrames > 0;
    }, null, { timeout: 120_000 }).catch(async error => {
        const state = await page.evaluate(() => ({
            loader: document.querySelector("#ada-loader")?.innerText,
            metrics: globalThis.__adaSAGAHost?.metrics?.(),
        }));
        throw new Error(`No SAGA frame was presented: ${JSON.stringify(state)}`, { cause: error });
    });
    const startupResult = await startup.jsonValue();
    if (startupResult.error) throw new Error(startupResult.error);
    if (record) {
        const base64 = await page.evaluate(async () => {
            const golden = await import("./saga-golden.mjs");
            const frame = await golden.captureStable(globalThis.__adaSAGAHost);
            const bytes = new Uint8Array(await (await golden.frameToPng(frame)).arrayBuffer());
            let text = "";
            for (const byte of bytes) text += String.fromCharCode(byte);
            return btoa(text);
        });
        await mkdir(dirname(goldenPath), { recursive: true });
        await writeFile(goldenPath, Buffer.from(base64, "base64"));
        console.log(`Recorded ${goldenPath}`);
    } else {
        const { actualPNG, ...result } = await page.evaluate(async (saveActual) => {
            const golden = await import("./saga-golden.mjs");
            const { actual, ...rest } = await golden.checkGolden(globalThis.__adaSAGAHost, "./golden/smoke-160x96.png");
            if (!saveActual) return rest;
            const blob = await golden.frameToPng(actual);
            return { ...rest, actualPNG: Array.from(new Uint8Array(await blob.arrayBuffer())) };
        }, Boolean(actualPath));
        if (actualPath) await writeFile(actualPath, Buffer.from(actualPNG));
        console.log(JSON.stringify(result));
        failed = !result.ok;
    }
} finally {
    await browser.close();
    server.close();
}
process.exit(failed ? 1 : 0);
