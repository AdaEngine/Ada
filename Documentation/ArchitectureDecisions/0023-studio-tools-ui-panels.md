# ADR-0023: Studio tools use .ui panels

Status: Accepted.

Implementation: Partial (local foundation; not released).

## Context

`@tool` already describes tool identity, API, platforms and permissions, and the
language catalog describes editor contribution APIs. AdaScript `@view` is
currently unavailable. The existing `.ui` resource system supports a visual
Designer, typed data, named actions and reusable AdaUI trees.

## Decision

Keep metadata and behavior in AdaScript and the panel interface in a project-local
`.ui` resource. Each direct subdirectory of project `Tools/` is a module; the host
activates enabled declarations in instance-owned runtimes. The first slice exposes
right-sidebar panels on macOS, exported scalar inputs and synchronous named
actions. It does not require restoring AdaScript `@view`.

UI rendering uses detached data through UIBindingContext. Named actions queue script
execution after the UI event. The first `editor` parameter receives a scoped host
bridge. It collects detached scene operations rather than mutating editor models.
Only a successful callback can commit an atomic batch against the captured active
document revision through existing history. Permission checks live in the bridge;
only declared and explicitly granted supported capabilities are available.

All contributions and queued actions belong to their tool generation. Disabling,
closing a project or replacing a generation retires them automatically. Reload
stages the new runtime and UI before publication. Invalid source/UI preserves the
last working generation. UI reload retains compatible input values. Enablement
is local to a project and permission changes require enabling again.

The project-level Tools directory is excluded from gameplay source collection.
Tool panels do not become game UI or require gameplay entities/worlds.

## Consequences

Reuse UISceneInstance, UISceneView, UIBindingContext, UICatalog and the production
Designer. No independent UI DSL or editor-specific renderer is introduced.

The initial host implements neither general scene-tree execution like Godot's
`@tool` flag nor every API listed in the static catalog. Commands, menus,
formatters, events, settings, async callbacks, richer scene operations and iPadOS
layout are future additive slices. The in-process restricted VM profile and
execution budgets do not constitute a process sandbox.

See [StudioTools.md](../../Editor/Documentation/StudioTools.md) for the API contract
and the executable Level Helper example.

## Validation of the initial slice

2026-10-10: 12 focused Studio tool tests passed, including the real VM/UI event
path, scene history/persistence, reload rollback, permission changes, loop limits,
project-local grants and gameplay source exclusion. Native macOS Generate/Undo,
selection retention and continued panel visibility were exercised in a temporary
project. See the guide for the screenshot and the unrelated compilation/test
limitations of the dirty working tree.

Consent is requested before VM activation and panel construction. The tool sidebar
contains the tool UI; versions, enablement and access revocation live in Project
Settings. Consent includes the displayed declaration snapshot, so a stale dialog
cannot approve changed source. Legacy implicit enable records require explicit
consent. Revocation persists and blocks automatic reactivation on reload.
