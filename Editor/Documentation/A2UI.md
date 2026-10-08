# Interactive agent UI

Studio's macOS ACP and iPhone SloppyRuntime chats display native AdaUI forms and previews using the
A2UI v0.9.1 Ada forms catalog. Use **Run Studio A2UI** in this worktree or
`./script/run_studio_a2ui.sh`, open a project, and connect an ACP agent normally.

## NPC configuration workflow

Ask: “Create an interactive NPC configuration form, then generate an editable
dialog preview from my submitted values.” The bundled `/ada-ui-forms` skill
provides the workflow to agents that need more explicit guidance.

1. The assistant streams a form inside its reply. Edit its fields and toggles.
2. After the agent's turn finishes, submit the form. Submission returns the
   current values to the same ACP session; an unsent composer draft is preserved.
3. The agent returns a new preview surface. Click **Open in UI Designer** to
   create a new project-local `.ui` asset and open it in the normal workbench.
4. Refine through the designer's controls or YAML view, use undo/redo, and save.

Export paths are `Assets/UI/AgentPreviews/<surface>-<unique-id>.ui`; each export
creates a new file, and symlinked destination directories are rejected. The
snapshot retains native components, bindings with current defaults, and named
host actions. It does not serialize the agent transport or action-context mapping.

## Transport contract

Studio advertises its custom catalog and compact component contract in ACP prompt
context. Ordinary assistant text remains Markdown. A fenced `a2ui` block contains
one complete JSON envelope per line; complete lines render progressively.
An exact opening fence at the end of a prose line is accepted too, because some
ACP agents concatenate planner and final replies without an intervening newline.
Fences inside ordinary code blocks remain ordinary text.
ACP embedded resources using `application/vnd.a2ui+json` or
`application/a2ui+json` are also accepted. This is an ACP text/resource binding;
it does not require a new ACP extension or a second MCP server.

The catalog supports Text, Row, Column, Button, TextField, Toggle, a single-string
ChoicePicker, and numeric Slider, with absolute JSON Pointer bindings and server
event actions. Required/range checks show inline errors and disable invalid
submit buttons. Checks and controls survive the `.ui` authoring handoff.
It does not advertise the Basic Catalog, executable code, general/local functions, collection templates, or
arbitrary modifiers. See the engine's `Documentation/A2UI.md` for schema details.

Button actions become an `[A2UI user action]` context block on the next prompt
in the owning conversation, including the envelope and its transport metadata.
`sendDataModel` sends only the originating surface's model. Other conversations
and other configured agents cannot receive a surface's submission. Changing
providers disables older forms until their original agent is reconnected.

Malformed interfaces show an inline error while retaining the previous working
surface. Correction feedback accompanies the following prompt. Interrupted or
failed runs have explicit surface states. Updates to a submitted surface can
make it ready for another interaction; a completed one-shot form stays submitted.

The ACP adapter waits for all session notifications preceding a prompt response
to reach the transcript before marking the turn complete. This handles bursty
streams and slow UI rendering without a timing-based completion delay.

## Persistence and scope

Compact surface state, including locally edited values, is saved in the existing
project chat session store. Switching chats preserves each live surface instance;
reopening Studio reconstructs surfaces without replaying server defaults over
local edits. Incomplete in-flight forms reopen as interrupted. Existing sessions
without the new optional field remain readable.

Desktop uses `EditorAgentViewModel`/ACP; iPhone uses its project-scoped SloppyRuntime chat.
Both render the same cards; see the local scene-tool contract below.
A designer snapshot is a one-way handoff; subsequent designer edits are not sent
back to the agent automatically. The host owns gameplay effects of exported actions.

## Validation

Run the test targets from the repository root:

```sh
ADAENGINE_DISABLE_SWAN=1 swift test --package-path Editor --disable-sandbox \
  --scratch-path /private/tmp/adaeditor-a2ui-build \
  --filter 'EditorAgentA2UITests|EditorAgentA2UITransportTests|EditorLoadingAnimationTests'
```

QA objects and mocks belong under `Editor/Tests`, not the app target. The Python
ACP fixture remains in `Editor/Tests/AdaEditorTests/Fixtures` and is excluded
from package resources. Transport tests launch it through the production adapter,
exercise burst delivery with a slow UI sink and file callbacks after setup, and
check child-process cleanup after failed connections. UI tests mount real chat
cards, submit edits, export previews, and exercise the normal designer model.

For manual native verification, launch Studio normally with
`./script/run_studio_a2ui.sh`, connect your configured agent, and follow the NPC
workflow above. No fixture launch modes or QA-specific app state are installed.

## Inspection memory

Large Swift generic view types can expand into huge diagnostic names. UI inspection
now reports a bounded nominal type name from immutable Swift runtime descriptors,
with generic arguments omitted. This avoids constructing the reflected/mangled
name tree. In the development fixture run, sampled RSS ranged from 333 to 567 MiB and settled near 337 MiB;
this is macOS workflow evidence, not a universal leak or performance guarantee.

## Configured-agent context limits

A Sloppy `protectedContextExceedsBudget` failure can happen before UI generation
when the selected model has no context-window metadata and the runtime falls back
to its smaller generic budget. Resolve the selected model against the active
provider catalog and configure its reported `contextWindowTokens`; use the same
supported model for the agent and planner. Do not raise limits based on an
unverified model name. The task's configured-provider workflow was verified with
`openai-oauth:gpt-5.5` and the provider-reported 272,000-token window. This is
provider/session evidence, not a guarantee for every agent or model.

## Tools inside chat (desktop and iPhone)

Ask the agent to **create an NPC spawner tool in chat** or **create a color tool for
this entity**. It reads the scene and presents a configurable card. Reserved
`editor.*` button events run in the host immediately; they do not start another
model turn. Other button events still submit data to the owning agent session.

Supported local actions:

| Event | Context | Effect |
| --- | --- | --- |
| `editor.scene.spawn` | `path`, `expectedRevision`, `revisionBinding`, `entityID`, `count`, `spacing` | Duplicate a non-root NPC subtree; count 1–100, X spacing per copy, at most 100 created entities including children. |
| `editor.scene.setColor` | scene/revision fields, `entityID`, `typeName`, `field`, `color` | Set a registered color field from HEX/named color, preserving other component fields. |
| `editor.scene.apply` | scene/revision fields, `operations` | Apply the existing structured scene-operation vocabulary as one transaction. |
| `editor.color.pick` | `binding` (absolute data path), `value` | Open the system color palette; update the card's HEX value without changing the scene. |

Initialize `/scene/revision` from `editor.scene.get`. Scene action contexts must
use `expectedRevision:{"path":"/scene/revision"}` and
`revisionBinding:"/scene/revision"`. The host updates that binding after Apply or
Undo, allowing repeat use. A change outside the card rejects its stale revision;
ask the agent to refresh the card. Unknown reserved actions produce an inline
error. Cards are disabled while an agent turn is running or their original
provider is unavailable.

Desktop actions operate on the open scene document and its normal Undo/Redo
history. On iPhone they operate on the saved project scene through the existing
atomic scene service and durable change records. **Undo** on the card reverts its
latest application only if the scene still matches that result. Card input,
current revision and latest Undo record persist in `.ada/chat-ui`; restoring
provider history rebinds card message IDs without replaying old form defaults.

The iPhone SloppyRuntime chat streams these same native cards and advertises the
same action contract. Ordinary submissions preserve the composer draft and
attachments. **Open UI Source** exports an editable `.ui` snapshot and opens its
YAML source in the mobile file editor; the desktop **Open in UI Designer** handoff
continues to use the visual designer. Applying a scene tool affects authored scene
content, not an already running Play world's entities; restart Play to see it.
