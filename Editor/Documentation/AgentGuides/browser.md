# Browser Studio and Playground

Read this reference for browser runtime, saving, navigation and assistant contracts.
Follow [WebUI instructions](../../WebUI/AGENTS.md) when editing the frontend.
Code-span paths below are relative to `Editor/` unless explicitly repository-relative.
Implementation and coverage descriptions do not establish runtime or hosted acceptance.

### Browser Studio

`WebUI/` is the default React/DOM browser shell, with inset floating panels over
a full-width viewport: a full-height assistant on the left, scene panels on the
right, a bottom log console and native text inputs. The scene viewport and Play use one isolated fixed AdaPlayer
with authored cameras, materials and lighting. Opening a project loads the engine;
document/mode changes replace its world without recreating WASM or the GPU device.
There is no separate SVG scene renderer. Editor mode disables gameplay, physics
and autoplay. Hierarchy/viewport bounds picking, move/rotate/scale gizmos, snapping,
duplicate/delete and a transient free camera are available. Gizmo gestures commit
one undo transaction; navigation never changes authored cameras. CodeMirror provides
AdaScript highlighting, indentation and search. It implements the existing
portable snapshot/scene/API contracts with transactions/undo, cloud recovery, ZIP
interchange and an in-tab agent. The entry library uses
Games/Create/My projects/Account navigation and the public catalog independently
of Studio sign-in. Opening a workspace switches the rail
to overview, scene, assets, code and assistant within that project. The Ada mark
returns to Games through the same save/recovery path as All Projects. The overview
button opens the project overview; All Projects waits for cloud save and retains the current document, undo, selection and Player for Continue.
Save failure offers Stay, retry, ZIP or an explicit IndexedDB-backed local exit;
failed local writes keep the project open. Closing a tab with unsaved changes or
an active agent requests browser confirmation. `Web/` retains the prior AdaUI/WASM application
(`AdaEditorWeb`) behind `--legacy-wasm-editor`, including its UGC publication UI;
publication controls are not yet ported to DOM. Native Studio uses the shared
`StudioCore/` value codec and supported runtime component contract. The browser does
not use native ACP, processes, SourceKit, key storage or file dialogs. See
[Documentation/StudioWeb.md](../../Documentation/StudioWeb.md) for export, service
boundaries and the browser release gate; source presence is not acceptance of a
hosted deployment or a live paid provider.

The browser assistant exports native bundled skills, documentation, examples and
the A2UI prompt at build time. Conversations, drafts, attachments, selected skills,
progress and interactive forms persist with the project. Hosted Ada AI uses a
shared grouped catalog with per-action availability and approval when the server
advertises contract 2. BYOK and local development agents use the legacy registry.
A2UI uses validated DOM
controls and native action envelopes; local scene actions and their durable Undo
are atomic and revision checked. The isolated Player runs native procedural asset
generators and exports `.ui` through AdaA2UI. Browser chrome, inspector, source search and embedded Cloud panels use the shared
en/ru catalogs and language preference enum. Language changes preserve mounted input;
the frontend build rejects hardcoded Russian UI literals and missing translations. OS/process,
external MCP, search, TestWorld and publication tools remain unavailable here.

Web Annotate selects entities via hierarchy/native viewport, A2UI components, or
canvas UI via a marked frame/point. Its popup adds context to the originating
conversation's persistent composer; only Send invokes the agent. Selection
stays active after Add for collecting multiple notes. Numbered chips and current
viewport pins reopen the note for editing; numbers remain stable when other notes
are removed, and one Send includes all pending notes in the same request. Pins
are scoped to the current selection session so camera movement cannot leave stale
screen markers. Selection suppresses form actions and gizmos. Notes survive Cloud reopen; manually edited
composer text remains authoritative. Canvas UI has no semantic native hit tree.

### Unified Playground web entry

`Editor/WebUI` owns Games/Create/My projects and the editor in one shell. Robot
artwork stays in `assets/playground`. Canonical routes include `/games`, `/create`,
`/projects/:id`, `/account` and `/publications/:id`; `/studio/` is a compatibility
entry and `/studio/*` serves static assets. Shared account/auth/legal/publication
panels are built from adawebsite (`npm run build:panels`) and embedded without an
iframe. Every navigation uses the existing save/leave guard. Keep publication
page IDs separate from private workspace IDs and retain native/Store auth callbacks.
