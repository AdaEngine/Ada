import { LocalizedError } from "./localization.js";

const instruction =
  "You are the Ada Studio game-building assistant. Follow the browser host context. Use only the supplied tools and report only verified results.";
const limit = 2 * 1024 * 1024;

function responseKey(message) {
  return JSON.stringify([
    message.content || "",
    (message.tool_calls || []).map((call) => call.id),
  ]);
}

function inputMessages(messages) {
  return messages.map((m) => ({
    role: m.role,
    content: m.images?.length
      ? [
          { type: "text", text: m.content || "" },
          ...m.images.map((url) => ({ type: "image_url", image_url: { url } })),
        ]
      : m.content || "",
    ...(m.toolCallID ? { tool_call_id: m.toolCallID } : {}),
    ...(m.toolCalls?.length ? { tool_calls: m.toolCalls } : {}),
  }));
}

export function providerPayload(connection, body) {
  const messages = inputMessages(body.messages);
  if (connection.protocol === "chat-completions")
    return {
      model: connection.model,
      messages: [{ role: "system", content: instruction }, ...messages],
      tools: body.tools,
      stream: true,
      stream_options: { include_usage: true },
    };
  const input = [];
  for (const message of messages) {
    if (message.role === "tool") {
      input.push({
        type: "function_call_output",
        call_id: message.tool_call_id,
        output: message.content,
      });
      continue;
    }
    // Replay the actual items from this turn, preserving message phase, output
    // IDs and encrypted reasoning. Persisted older history uses easy inputs.
    const output =
      message.role === "assistant" &&
      connection.responses.get(responseKey(message));
    if (output) {
      input.push(...output);
      continue;
    }
    if (message.content) {
      const content = Array.isArray(message.content)
        ? message.content.map((item) =>
            item.type === "text"
              ? { type: "input_text", text: item.text }
              : { type: "input_image", image_url: item.image_url.url },
          )
        : message.content;
      input.push({ role: message.role, content });
    }
    for (const call of message.tool_calls || []) {
      input.push({
        type: "function_call",
        call_id: call.id,
        name: call.function.name,
        arguments: call.function.arguments,
      });
    }
  }
  return {
    model: connection.model,
    instructions: instruction,
    input,
    tools: body.tools.map(({ function: fn }) => ({
      type: "function",
      name: fn.name,
      description: fn.description,
      parameters: fn.parameters,
      strict: false,
    })),
    stream: true,
    store: false,
    include: ["reasoning.encrypted_content"],
  };
}

// Normalize both wire protocols to the existing browser agent events. Tools are
// released only after a successful terminal event and complete argument JSON.
export class ProviderStream {
  constructor(connection, tools, emit) {
    this.connection = connection;
    this.names = new Set(tools.map((t) => t.function.name));
    this.emit = emit;
    this.pending = "";
    this.data = [];
    this.calls = new Map();
    this.complete = false;
    this.text = "";
    this.received = 0;
  }
  append(text) {
    this.received += text.length;
    this.pending += text;
    if (this.pending.length > limit || this.received > 8 * limit)
      throw new LocalizedError("The provider response is too large");
    let end;
    while ((end = this.pending.indexOf("\n")) >= 0) {
      const line = this.pending.slice(0, end).replace(/\r$/, "");
      this.pending = this.pending.slice(end + 1);
      if (!line) this.dispatch();
      else if (line.startsWith("data:")) {
        this.data.push(line.slice(5).trimStart());
        if (this.data.reduce((n, value) => n + value.length, 0) > limit)
          throw new LocalizedError("The provider response is too large");
      }
    }
  }
  dispatch() {
    const data = this.data.join("\n");
    this.data = [];
    if (!data || data === "[DONE]") return;
    let value;
    try {
      value = JSON.parse(data);
    } catch {
      throw new LocalizedError(
        "The provider returned an invalid streaming response",
      );
    }
    if (
      value.error ||
      ["error", "response.failed", "response.incomplete"].includes(value.type)
    )
      throw new LocalizedError(
        "The provider could not complete the response. Check its model, limits and API key.",
      );
    if (this.connection.protocol === "responses") this.responses(value);
    else this.chat(value);
    if (this.calls.size > 96)
      throw new LocalizedError("The provider response is too large");
  }
  delta(text) {
    if (typeof text !== "string" || !text) return;
    this.text += text;
    this.emit({ type: "text", text });
  }
  responses(value) {
    if (
      ["response.output_text.delta", "response.refusal.delta"].includes(
        value.type,
      )
    )
      this.delta(value.delta);
    if (value.type !== "response.completed") return;
    const response = value.response;
    if (
      !response ||
      response.status !== "completed" ||
      !Array.isArray(response.output)
    )
      throw new LocalizedError(
        "Response interrupted. You can continue from the saved step.",
      );
    this.output = response.output.filter(
      (item) =>
        ["message", "function_call"].includes(item.type) ||
        (item.type === "reasoning" && item.encrypted_content),
    );
    for (const item of response.output) {
      if (item.type === "function_call") {
        if (this.calls.has(item.call_id))
          throw new LocalizedError(
            "The provider returned an invalid tool call",
          );
        this.calls.set(item.call_id, {
          id: item.call_id,
          type: "function",
          function: { name: item.name, arguments: item.arguments },
        });
      }
    }
    if (!this.text)
      for (const item of response.output)
        for (const content of item.content || [])
          if (content.type === "output_text") this.delta(content.text);
    this.usage = response.usage;
    this.complete = true;
  }
  chat(value) {
    if (value.usage) this.usage = value.usage;
    const choice =
      value.choices?.find((c) => c.index === 0) || value.choices?.[0];
    if (!choice) return;
    this.delta(choice.delta?.content);
    for (const delta of choice.delta?.tool_calls || []) {
      if (
        !Number.isInteger(delta.index) ||
        delta.index < 0 ||
        delta.index >= 96
      )
        throw new LocalizedError("The provider returned an invalid tool call");
      const call = this.calls.get(delta.index) || {
        id: "",
        type: "function",
        function: { name: "", arguments: "" },
      };
      if (delta.id) call.id = delta.id;
      call.function.name += delta.function?.name || "";
      call.function.arguments += delta.function?.arguments || "";
      this.calls.set(delta.index, call);
    }
    if (choice.finish_reason) {
      if (!["stop", "tool_calls"].includes(choice.finish_reason))
        throw new LocalizedError(
          "The provider could not complete the response. Check its model, limits and API key.",
        );
      this.complete = true;
    }
  }
  finish() {
    if (this.pending) this.append("\n");
    this.dispatch();
    if (!this.complete)
      throw new LocalizedError(
        "Response interrupted. You can continue from the saved step.",
      );
    const ids = new Set();
    for (const call of this.calls.values()) {
      let args;
      try {
        args = JSON.parse(call.function.arguments);
      } catch {
        /* Validate below. */
      }
      if (
        !call.id ||
        ids.has(call.id) ||
        !this.names.has(call.function.name) ||
        !args ||
        typeof args !== "object" ||
        Array.isArray(args)
      )
        throw new LocalizedError("The provider returned an invalid tool call");
      ids.add(call.id);
    }
    if (this.output) {
      this.connection.responseBytes =
        (this.connection.responseBytes || 0) +
        JSON.stringify(this.output).length;
      if (this.connection.responseBytes > 8 * limit)
        throw new LocalizedError("The provider response is too large");
      this.connection.responses.set(
        responseKey({
          content: this.text,
          tool_calls: [...this.calls.values()],
        }),
        this.output,
      );
    }
    for (const call of this.calls.values()) this.emit({ type: "tool", call });
    if (this.usage)
      this.emit({
        type: "usage",
        inputTokens: this.usage.input_tokens ?? this.usage.prompt_tokens ?? 0,
        outputTokens:
          this.usage.output_tokens ?? this.usage.completion_tokens ?? 0,
      });
    this.emit({ type: "complete" });
  }
}

export async function streamDirect(
  connection,
  body,
  signal,
  event,
  request = fetch,
) {
  signal?.throwIfAborted();
  const requestSignal = signal
    ? AbortSignal.any([signal, AbortSignal.timeout(180000)])
    : AbortSignal.timeout(180000);
  const endpoint =
    connection.protocol === "responses" ? "/responses" : "/chat/completions";
  let response;
  try {
    response = await request(connection.baseURL + endpoint, {
      method: "POST",
      mode: "cors",
      credentials: "omit",
      redirect: "error",
      referrerPolicy: "no-referrer",
      cache: "no-store",
      signal: requestSignal,
      headers: {
        "Content-Type": "application/json",
        Authorization: "Bearer " + connection.apiKey,
      },
      body: JSON.stringify(providerPayload(connection, body)),
    });
  } catch (error) {
    if (signal?.aborted) throw error;
    throw new LocalizedError(
      "Could not connect to the provider. Check the Base URL and allow CORS requests from this Playground origin.",
    );
  }
  if (!response.ok) {
    await response.body?.cancel();
    throw new LocalizedError(
      "Provider returned HTTP {0}. Check the model, API key and provider limits.",
      response.status,
    );
  }
  if (
    !response.body ||
    !response.headers.get("Content-Type")?.includes("text/event-stream")
  ) {
    await response.body?.cancel();
    throw new LocalizedError(
      "The provider must support streaming responses and tool calls",
    );
  }
  const reader = response.body.getReader(),
    decoder = new TextDecoder(),
    parser = new ProviderStream(connection, body.tools, event);
  try {
    for (;;) {
      requestSignal.throwIfAborted();
      const { value, done } = await reader.read();
      parser.append(decoder.decode(value, { stream: !done }));
      if (done) break;
    }
    requestSignal.throwIfAborted();
    parser.finish();
  } finally {
    await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}
