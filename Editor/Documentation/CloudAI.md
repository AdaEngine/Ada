# Ada AI in Cloud Pro

Cloud Pro includes 500 AI credits per account per month. Browser and native Studio
share the same balance and billing anniversary. There are no separate AI purchase
tiers. Token usage is charged by the server's versioned credit tariff; a credit is
not a message or an OpenRouter dollar.

## Connection

The backend owns `STUDIO_OPENROUTER_API_KEY` and selects `qwen/qwen3-coder-next`.
Enable `AI_ENABLED`, the `llm` capability and approved countries on AIService.
Clients use their existing Ada Cloud session and never receive the provider key.

Browser Studio selects Ada AI in Assistant settings. Native Studio selects the
built-in Ada AI entry in the agent catalog; iPhone Providers has the same choice.
Cloud settings show available, used and reserved credits and the next cycle.
Missing service is distinct from a real zero balance. Cloud Pro purchase/restore
uses the existing subscription flow and SKU.

Coder Next is text-only. Image attachments require another compatible provider.
When the server advertises tool contract 2, Ada AI uses a shared catalog of up to
17 tool families. Each call names a family and provides an `action` and an
`arguments` object. The model sees only the actions supported by the active host
and mode. Studio falls back to the legacy contract for servers that have yet to
advertise version 2. Existing clients can still use the legacy contract with
updated servers.

## Working with project tools

For an edit, ask Ada AI to read a project file, change one known occurrence, and
build the project. A typical sequence for a project with `Sources/Game.ada` is:

| Tool | Arguments sent to the tool |
| --- | --- |
| `editor_files` | `{"action":"read","arguments":{"path":"Sources/Game.ada"}}` |
| `editor_files` | `{"action":"patch","arguments":{"path":"Sources/Game.ada","oldText":"// original","newText":"// edited"}}` |
| `editor_task` | `{"action":"build","arguments":{}}` |

Choose `oldText` from the read result. The patch fails when the text is absent or
ambiguous. Desktop reports a started build. Use `editor_task` with `status` and
`output` to check its result. Mobile and Web return the compilation result in the
build call. Verify gameplay separately in Play.

In Ask or Plan, Studio offers inspection actions such as `editor_files/read`
and omits `editor_files/patch`. In Build, approval identifies the action and
its target. A Web session grant for a patch does not grant permission to replace
or delete files. Native file tools reject traversal, symbolic links and silent
overwrites. Save dirty native documents before editing them through Ada AI.

The desktop agent can edit animation drafts, run project tests, and replay Play
scenarios. Mobile offers isolated simulation and scene validation. Web can
apply a project transaction or import a bundled example. Native hosts can
search and fetch public web references, and approved Build actions can download
assets. The external agent and Web BYOK catalogs use their own contracts.

## Accounting and recovery

The server reserves a bounded request before calling OpenRouter, rechecks Billing
before execution, then settles measured input/output tokens. Each model/tool round
is a new metered operation. Completed operation replays never submit again.
Definitive provider rejections release funds; uncertain/missing usage retains a
reservation for reconciliation. A client disconnect does not make admitted work
free or trigger a paid retry. Native account/server changes invalidate a running
transport before another model round.

Mobile Cloud conversations use `cloud-` session IDs in the native agent store.
Provider changes start a new conversation; existing external runtime histories
remain accessible in their provider's session list.

## Local builds

Studio prefers an adjacent AdaMCP checkout when present; `ADA_MCP_LOCAL_PATH`
overrides that path. The current source uses MCP tool `_meta` verification data.
The companion AdaMCP change adds flat Codable metadata support; keep it with this
integration when preparing the dependency release. A copy of that patch and the
backend validation report live in adaengine-service/docs.

Focused tests: `EditorCloudAgentTests`, `EditorAICreditsTests`,
`EditorLocalizationTests`, and WebUI `ai-credits.test.mjs`.
