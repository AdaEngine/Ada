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

## Connect a local MCP server

On Windows or macOS, open **Settings → Agents → Local MCP servers** and choose
**Add MCP server**. Give it a unique name and enter the full path to its
executable. Add one row for each argument and keep the launch order. For a local
Python MCP server, use the path to the Python executable and add the full path
to the server script as the first argument. Studio launches the executable
directly over stdio with a separate working directory and a minimal environment.
The process runs with your operating-system account's permissions, so connect
commands you trust.

Choose **Connect**, open **Input details** to inspect a tool's schema, and check
the tools you want Ada AI to use. Tools start unchecked. Tool schemas that Studio
cannot validate are disabled. The settings support up to 12 saved servers and 32
selected tools. Disconnect stops the connection and keeps selections for a later
reconnect to the same executable, arguments and tool schemas. Changed tools
require another review. Studio starts no saved servers automatically.

With an Ada Cloud server that supports the desktop tool contract v3, Ada AI in
Ask and Plan can look up selected tools. In Build, each call shows the project,
server, tool and arguments in a permission card. Results can contain bounded
text and structured JSON. Keep private data out of tools you intend to use with
Ada AI. For the Blender workflow, use the existing preset below.

## Export a model from Blender on Windows

The Windows Blender preset requires the hosted tool contract version 3 and a
local MCP for Blender installation. The first verified local configuration uses
MCP for Blender 2.2.4, add-on 1.8 and Blender 5.3.0. Open Blender and start its
MCP add-on on the default loopback port. In Studio open **Settings → Agents →
Blender MCP**, enter the full path to the trusted `mcp-for-blender.exe`, and
choose **Connect**. The executable runs with your Windows account permissions.

Enable **Allow Ada AI to create and export GLB models**. Select Ada AI and Build
mode, then follow the [Blender example](Agent3DWorkflow.md#export-from-blender-on-windows).
You approve each export in the conversation. Ask and Plan can describe the
selected tools. The preset creates static models from colored primitives and
saves a GLB in the project's `Downloads/Blender` folder. Use the returned job ID
to import, place, and verify the model in visible Play. Disconnect in Settings
to revoke calls to Blender. You can still finish a job whose export completed.
Reconnect when you need a new export after closing Blender or after an MCP timeout.

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

## Studio plugin intents and tools

On macOS and Windows, installed Studio plugins can add read-only actions to the
Ada AI catalog for the open project. Enable the plugin, then turn on **Allow Ada AI
to use this plugin** in **Project Settings → Studio Tools**. The permissions page
shows which actions become available. Turn the option off to withdraw access.

With the [External Asset Library](EditorGuide.md#asset-store), try “Find my Fab
benches and tell me which ones I already have locally.” Ada AI can search your saved
titles and look up a result through its asset reference. The search shares titles,
store labels and file availability with the AI provider. Images and model files
stay in Studio. Use the gallery to add, import or remove a managed file.

The hosted connection must advertise tool contract version 4 for plugin actions.
Earlier connections can continue using their existing tools. For manifest and
handler details, see the [Studio Tools guide](StudioTools.md#offer-read-only-actions-to-ada-ai).
