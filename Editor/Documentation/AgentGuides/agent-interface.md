# Agent Interface, Source Control and ACP

Read this reference only when the task touches this area. Return to [the editor guide](../../AGENTS.md) for routing and shared rules.

Paths in code spans and commands retain their original `Editor/` working-directory context unless explicitly repository-relative; Markdown links resolve from this file.

This inventory was originally recorded on **2026-10-04** and subsequently maintained. Implementation and test links identify existing coverage, not a validation run or platform acceptance.

### Git and agents

Project-local AdaScript `@tool` extensions can mount right-sidebar `.ui` panels
in the macOS workspace's Studio Tools section. An explicit access dialog grants the
declared document read/write permissions before activation. Project Settings →
Studio Tools owns enablement and immediate access revocation. Exported scalar inputs and synchronous
named actions use detached UI data; successful entity batches enter scene Undo/Redo.
Disable/close removes contributions, and invalid reloads retain the previous
working version. iPadOS activation and command/menu/formatter/settings/event
registrations remain unavailable in this initial host.
Guide: [StudioTools.md](../../Documentation/StudioTools.md).
Coverage: [EditorStudioToolsTests.swift](../../Tests/AdaEditorTests/EditorStudioToolsTests.swift).

Desktop and visionOS Studio offer an **Editor / Agent** interface switch in the top
bar. Agent Interface uses a project session tree, conversation tabs, the existing
agent transcript/composer and a document workspace opened on demand. Its right
activity strip exposes Files, Workspaces (existing open editors/previews) and
Source Control without changing the standard editor panel preferences. File and
diff selection reveal the document workspace. The conversation/document divider
has a visible grip and supports dragging; the rounded document panel clips its
contents. The session list shows an overflow scrollbar and keeps its header and
Settings fixed. Conversation
content uses a centered column up to 800 points wide; Retry/New Session stay at
the right edge of the full-width tab toolbar. Completed
agent diff events expose changed files; opening one uses the production document
loader. Both interfaces share document state, panel preferences and agent service;
mode selection restores per project. Switching sessions retains in-memory drafts,
attachments, selected-code context and chat mode. Running turns stay attached to
their originating session; one turn runs at a time per project window.
The dedicated iPhone flow is unchanged. visionOS hides editor panel/tab ornaments
in Agent mode and restores the last normal window size after leaving immersion.
Guide: [AgentInterface.md](../../Documentation/AgentInterface.md).
Coverage: [EditorAgentWorkspaceTests.swift](../../Tests/AdaEditorTests/EditorAgentWorkspaceTests.swift).

Native scene toolbars expose Annotate for the shared desktop workbench. 2D/3D
viewport and hierarchy picks create numbered notes in the originating chat's
editable composer, without scene edits or an automatic agent request. Up to
eight notes can be collected, edited or removed before Send. Object references
travel with the request and persist with sent messages; unsent notes remain in
memory with native session drafts. Picking suppresses transform gizmos; camera
navigation remains available. Play, model previews and individual rendered UI
widgets are outside this path. Coverage: `EditorSceneAnnotationTests` and the
mounted annotation editor check in `EditorLocalizationTests`.

Desktop Source Control offers Git and Lore, including at project creation
(None / Git / Lore). New projects preselect Lore where it is supported, with Git
as the fallback. The Lore selection includes an introduction and official documentation link.
The choice persists per project. Both providers support
status, staging, commit, pull/push, branches, history and diff review; Stash is
Git-only. Lore uses native bindings on macOS Apple silicon, Windows x64 and Linux
x86_64/ARM64. Windows and Linux preparation include the pinned C SDK; packaging
bundles `lore.dll` or `liblore.so` with license notices. The Linux launcher selects
the prepared library through `LD_LIBRARY_PATH`. See
[SourceControl.md](../../Documentation/SourceControl.md) and `../Tools/Lore/README.md`.
Core Windows repository lifecycle, binary diff and preference tests are present;
these do not establish packaged Studio UI validation. Linux SDK staging and ELF
linking are checked; the bindings' runtime and Studio UI still need a Linux run.
Agent Chat includes transcript/session persistence,
attachments, context selection, permissions, skills and agent settings.
Shared native transcripts render Markdown code blocks, quotes and tables with
native block layout, selectable text and clickable links. Parsing is cached per
mounted message. Text deltas and snapshots coalesce for up to 33 ms and flush before control or
terminal events; transcript rows and A2UI display text use per-message observation.
Keep session chrome independent of the observed event array. Coverage:
`EditorAgentTranscriptTests`, `EditorAgentEventBatcherTests` and `TextMarkdownBlockTests`.
The shared sidebar/workspace composer offers a debounced, full-draft completion
while typing and up to three next-message suggestions after a successful saved
reply. Chips fill an editable draft without sending; Enter retains ordinary
submission and slash/@ completion behavior. Suggestions can be dismissed and
refresh with context changes. Next-message hints come from a hidden `ada-next`
JSON fence authored by the active agent in the normal reply, using its conversation,
project context and tool results. Raw reply events persist the hints for reopen;
only the latest successful saved turn enables them. Missing/invalid hints leave
this area empty, without canned follow-ups or a second model request. Draft
completion still uses Foundation Models on supported Apple systems and a local
history/intent fallback.
Coverage: [EditorAgentSuggestionUITests.swift](../../Tests/AdaEditorTests/EditorAgentSuggestionUITests.swift).
Suggestion rows highlight across their full width on pointer hover and keyboard
focus, restoring their normal background on leave without changing the draft.
Windows text uses cached system-font fallback atlases for symbols absent from
Open Sans, including arrows in regular and bold replies. Coverage:
`WindowsFontFallbackTests` in the engine text target.
The shared prompt editor wraps drafts at the available composer width and scrolls
vertically. Reflow on resize preserves the draft and selection, including words
without spaces and Unicode. Coverage: `EditorAgentChatSizingTests`.
macOS/Windows ACP and iPhone SloppyRuntime replies stream native A2UI cards. Ordinary
submissions return to the owning session; reserved local actions apply scene tools
without a new model turn. NPC subtree spawning, color-field editing, structured
scene batches and the system color palette are available. Scene revisions guard
repeat Apply/Undo; desktop uses document history, iPhone uses atomic saved-scene
changes with durable Undo. Card inputs and ownership persist. Desktop Open in UI
Designer creates a project-local `.ui`; iPhone Open UI Source opens its YAML.
Coverage: [EditorChatToolTests.swift](../../Tests/AdaEditorTests/EditorChatToolTests.swift).
Guide: [A2UI.md](../../Documentation/A2UI.md).
Entry points: [EditorAgentA2UIController.swift](../../Sources/AdaEditor/Agent/EditorAgentA2UIController.swift),
[EditorAgentA2UISurfaceCard.swift](../../Sources/AdaEditor/UI/Editor/EditorAgentA2UISurfaceCard.swift).
Coverage: [EditorAgentA2UITests.swift](../../Tests/AdaEditorTests/EditorAgentA2UITests.swift),
[EditorAgentA2UITransportTests.swift](../../Tests/AdaEditorTests/EditorAgentA2UITransportTests.swift).
macOS/Windows ACP catalog discovers/installs/connects agents; mobile uses an in-process
SloppyRuntime path when available. Windows reuses ACPModel and the shared editor service
with native stdio JSON-RPC, suspended process/job startup, explicit inherited handles,
literal argv, file/terminal callbacks and MCP stdio bridging. Native Windows registry
binaries are preferred; npm launchers resolve to Node.js without a command shell.
Node.js/uv remain prerequisites for their package distributions. Windows agent
discovery rereads persisted PATH and Codex Desktop's versioned executable
folders on Refresh; adapter launches supplement stale saved paths with current
host tools. Empty Codex version folders left by updates are ignored.
Windows process-backed coverage includes session/model state, streaming, cancellation, permissions, files,
terminals, MCP and A2UI. Provider account authentication requires the agent's own setup.
Windows ACP pipes read on demand in chunks of at most 64 KiB, letting the kernel
apply backpressure without dropping messages during output bursts. Keep stdout and
stderr draining independently. Coverage: `EditorWindowsACPTransportTests`.
The macOS catalog shows bundled ACP Registry logos
and Sloppy branding for installed, discovered and registry agents. New registry logos
load from HTTPS metadata with a shared cache and a generic fallback; icon URLs persist
with managed installations. Editor MCP/host tools expose project/docs/API
context, scene edits, diagnostics, build, simulation, visible Play, frame capture,
web access and asset/image operations. Model texture assignment tools also exist;
they do not constitute a visual 3D asset editor.
