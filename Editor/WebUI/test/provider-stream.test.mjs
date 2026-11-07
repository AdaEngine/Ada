import test from "node:test";
import assert from "node:assert/strict";
import { Studio } from "../src/studio.js";
import {
  browserProviders,
  directConnection,
  providerTitle,
  setBillingMode,
} from "../src/provider-settings.js";
import { providerPayload, streamDirect } from "../src/provider-stream.js";

const tools = [
  {
    type: "function",
    function: {
      name: "editor_file_read",
      description: "Read a file",
      parameters: {
        type: "object",
        properties: { path: { type: "string" } },
        required: ["path"],
      },
    },
  },
];
const call = {
  id: "call_1",
  type: "function",
  function: {
    name: "editor_file_read",
    arguments: '{"path":"Sources/Game.ada"}',
  },
};
const connection = (protocol = "responses") => ({
  protocol,
  baseURL: "https://provider.example/v1",
  apiKey: "test-key",
  model: "test-model",
  responses: new Map(),
});
const body = {
  model: "test-model",
  messages: [
    {
      role: "user",
      content: "Read my game",
      images: ["data:image/png;base64,AAAA"],
    },
  ],
  tools,
};
function response(events, { ending = true } = {}) {
  const bytes = new TextEncoder().encode(
    ": keep-alive\r\n\r\n" +
      events
        .map(
          (value) =>
            "event: message\r\ndata: " + JSON.stringify(value) + "\r\n\r\n",
        )
        .join("") +
      (ending ? "data: [DONE]\n\n" : ""),
  );
  return new Response(
    new ReadableStream({
      start(controller) {
        for (let i = 0; i < bytes.length; i += 7)
          controller.enqueue(bytes.slice(i, i + 7));
        controller.close();
      },
    }),
    { headers: { "Content-Type": "text/event-stream" } },
  );
}
function complete(output, extra = {}) {
  return {
    type: "response.completed",
    response: { status: "completed", output, ...extra },
  };
}

test("BYOK provider labels and keys are isolated by provider and custom endpoint", () => {
  globalThis.window = { addEventListener() {} };
  const s = new Studio();
  s.billingMode = "byok";
  s.providerID = "browser-openai";
  s.apiKey = "openai-only";
  s.providerID = "browser-compatible";
  assert.equal(s.apiKey, "");
  s.compatible.baseURL = "https://one.example/v1";
  s.compatible.modelID = s.modelID = "custom/model";
  s.apiKey = "one-only";
  assert.equal(directConnection(s).baseURL, "https://one.example/v1");
  s.compatible.baseURL = "https://two.example/v1";
  assert.equal(s.apiKey, "");
  s.apiKey = "two-only";
  s.compatible.baseURL = "https://one.example/v1/";
  assert.equal(s.apiKey, "one-only");
  setBillingMode(s, "byok");
  assert.equal(s.modelID, "custom/model");
  s.providerID = "browser-openai";
  assert.equal(s.apiKey, "openai-only");
  assert.equal(
    providerTitle({ id: "openrouter", title: "Ada AI" }, "byok"),
    "OpenRouter",
  );
  assert.equal(
    providerTitle({ id: "openrouter", title: "Ada AI" }, "ada"),
    "Ada AI",
  );
  assert(browserProviders().every((p) => !p.hosted));
});

test("custom connection rejects unsafe URLs before a request and normalizes full endpoints", () => {
  globalThis.window = { addEventListener() {} };
  const s = new Studio();
  s.providerID = "browser-compatible";
  s.billingMode = "byok";
  s.modelID = "test-model";
  for (const url of [
    "http://api.example/v1",
    "https://key@api.example/v1",
    "https://api.example/v1?key=secret",
    "https://api.example/#secret",
    "garbage",
  ]) {
    s.compatible.baseURL = url;
    s.apiKey = "test-key";
    assert.throws(() => directConnection(s), /HTTPS Base URL/);
  }
  s.compatible.baseURL = "https://api.example/v1/chat/completions/";
  s.apiKey = "test-key";
  assert.equal(directConnection(s).baseURL, "https://api.example/v1");
  s.apiKey = "invalid\r\nHeader: key";
  assert.throws(() => directConnection(s), /API key/);
});

test("Responses carries tools, images, tool results and encrypted reasoning without serializing credentials", async () => {
  const c = connection(),
    emitted = [];
  const reasoning = {
    type: "reasoning",
    id: "rs_1",
    encrypted_content: "opaque",
    summary: [],
  };
  let options;
  await streamDirect(
    c,
    body,
    undefined,
    (e) => emitted.push(e),
    async (url, init) => {
      assert.equal(url, "https://provider.example/v1/responses");
      options = init;
      return response([
        { type: "response.output_text.delta", delta: "Читаю" },
        complete(
          [
            reasoning,
            {
              type: "message",
              id: "msg_1",
              status: "completed",
              role: "assistant",
              phase: "commentary",
              content: [
                { type: "output_text", text: "Читаю", annotations: [] },
              ],
            },
            {
              type: "function_call",
              call_id: call.id,
              name: call.function.name,
              arguments: call.function.arguments,
            },
          ],
          { usage: { input_tokens: 10, output_tokens: 3 } },
        ),
      ]);
    },
  );
  assert.equal(options.credentials, "omit");
  assert.equal(options.redirect, "error");
  assert.equal(options.referrerPolicy, "no-referrer");
  assert.equal(options.headers.Authorization, "Bearer test-key");
  assert(!options.body.includes("test-key"));
  const payload = JSON.parse(options.body);
  assert.equal(payload.store, false);
  assert.equal(payload.tools[0].strict, false);
  assert.equal(payload.input[0].content[1].type, "input_image");
  assert.deepEqual(
    emitted.map((e) => e.type),
    ["text", "tool", "usage", "complete"],
  );
  assert.deepEqual(emitted[1].call, call);
  const next = providerPayload(c, {
    ...body,
    messages: [
      ...body.messages,
      { role: "assistant", content: "Читаю", toolCalls: [call] },
      { role: "tool", toolCallID: call.id, content: "Game contents" },
    ],
  });
  assert(next.input.some((item) => item.encrypted_content === "opaque"));
  assert(
    next.input.some(
      (item) => item.phase === "commentary" && item.id === "msg_1",
    ),
  );
  assert.equal(next.input.at(-1).type, "function_call_output");
  assert.equal(next.input.at(-1).output, "Game contents");
  const restored = providerPayload(connection(), {
    ...body,
    messages: [
      { role: "assistant", content: "Earlier saved answer" },
      ...body.messages,
    ],
  });
  assert.equal(restored.input[0].content, "Earlier saved answer");
});

test("Chat Completions assembles fragmented function calls and accepts final usage frames", async () => {
  const emitted = [],
    c = connection("chat-completions");
  await streamDirect(
    c,
    body,
    undefined,
    (e) => emitted.push(e),
    async (url, init) => {
      assert.equal(url, c.baseURL + "/chat/completions");
      const payload = JSON.parse(init.body);
      assert.equal(payload.messages[1].content[1].type, "image_url");
      return response([
        {
          choices: [
            {
              index: 0,
              delta: {
                tool_calls: [
                  {
                    index: 0,
                    id: call.id,
                    function: { name: "editor_file_", arguments: '{"path":' },
                  },
                ],
              },
            },
          ],
        },
        {
          choices: [
            {
              index: 0,
              delta: {
                tool_calls: [
                  {
                    index: 0,
                    function: {
                      name: "read",
                      arguments: '"Sources/Game.ada"}',
                    },
                  },
                ],
              },
              finish_reason: "tool_calls",
            },
          ],
        },
        { choices: [], usage: { prompt_tokens: 5, completion_tokens: 4 } },
      ]);
    },
  );
  assert.deepEqual(emitted[0].call, call);
  assert.equal(emitted[1].inputTokens, 5);
  assert.equal(emitted.at(-1).type, "complete");
});

test("truncated, failed and malformed provider responses never release tools", async () => {
  const values = [
    [{ type: "response.output_text.delta", delta: "partial" }],
    [{ type: "response.failed", response: { status: "failed" } }],
    [
      complete([
        {
          type: "function_call",
          call_id: call.id,
          name: "editor_shell_execute",
          arguments: "{}",
        },
      ]),
    ],
    [
      complete([
        {
          type: "function_call",
          call_id: call.id,
          name: call.function.name,
          arguments: "[1]",
        },
      ]),
    ],
    [
      complete([
        {
          type: "function_call",
          call_id: call.id,
          name: call.function.name,
          arguments: "{",
        },
      ]),
    ],
    [complete([]), { error: { message: "key must not be echoed" } }],
  ];
  for (const events of values) {
    const emitted = [];
    await assert.rejects(
      streamDirect(
        connection(),
        body,
        undefined,
        (e) => emitted.push(e),
        async () => response(events),
      ),
    );
    assert(!emitted.some((e) => ["tool", "complete"].includes(e.type)));
  }
});

test("provider HTTP/CORS failures redact upstream bodies and never retry paid requests", async () => {
  let requests = 0;
  await assert.rejects(
    streamDirect(
      connection(),
      body,
      undefined,
      () => {},
      async () => {
        requests++;
        return new Response("secret-key", { status: 401 });
      },
    ),
    (error) =>
      /HTTP 401/.test(error.message) && !error.message.includes("secret-key"),
  );
  assert.equal(requests, 1);
  await assert.rejects(
    streamDirect(
      connection(),
      body,
      undefined,
      () => {},
      async () => {
        throw new TypeError("secret-key");
      },
    ),
    /CORS/,
  );
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(
    streamDirect(
      connection(),
      body,
      controller.signal,
      () => {},
      async () => {
        throw new Error("Must not request");
      },
    ),
    { name: "AbortError" },
  );
});
