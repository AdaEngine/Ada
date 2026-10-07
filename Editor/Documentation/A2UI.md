# Interactive agent UI

Studio's macOS ACP chat can display native AdaUI forms and previews using the
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

This integration uses the shared `EditorAgentViewModel`/macOS ACP sidebar.
The iPhone's separate SloppyRuntime chat path is not wired to these cards.
A designer snapshot is a one-way handoff; subsequent designer edits are not sent
back to the agent automatically. The host owns gameplay effects of exported actions.

## Repeatable validation

```sh
./script/verify_studio_a2ui.sh --fixture
./script/verify_studio_a2ui.sh
```

The fixture mode launches a deterministic Python ACP process through the production
adapter. The default uses Studio's saved agent configuration through an isolated
in-memory settings copy. Both launch a disposable project, operate the actual
window, clear a required field and verify blocked submission, choose a role,
set health through the slider, submit the corrected form, open the returned preview, edit/undo/redo/save it, and
restore the persisted chat. Proof artifacts and logs are printed on completion.
Neither mode changes the saved global agent settings.

Focused suites: `EditorAgentA2UITests`, `EditorAgentA2UITransportTests`.
The transport suite sends a real subprocess burst into a deliberately slow UI sink
and requests an actual file read after connection setup, checking that the ACP
callback delegate remains alive for the session. Cold session creation allows
60 seconds independently of prompt generation.


## Inspection memory

Large Swift generic view types can expand into huge diagnostic names. UI inspection
now reports a bounded nominal type name from immutable Swift runtime descriptors,
with generic arguments omitted. This avoids constructing the reflected/mangled
name tree. The native QA snapshots also use a bounded subtree. In the task's
fixture run, sampled RSS ranged from 333 to 567 MiB and settled near 337 MiB;
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
