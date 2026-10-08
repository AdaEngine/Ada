# ADR-0009: Configure AdaScript runtime composition in project metadata

- Status: Accepted
- Date: 2026-09-05
- Implementation: Partial (foundation shipped)

## Context

Portable AdaScript projects execute inside a precompiled AdaEditor host. They
cannot add arbitrary Swift plugins at runtime, and they do not own a process
`@main`. The initial runtime therefore hard-coded one mixed 2D/3D plugin list,
required a root AdaUI view, and ignored the optional startup-scene field already
present in project metadata.

Project authors need to choose the startup scene and view, select a one-shot
startup system, enable native engine capabilities, configure supported plugin
parameters, and control basic runtime-window presentation without editing Swift.

## Decision

### Project metadata owns composition

Schema version 3 adds a declarative runtime entry plan, plugin configuration,
and window settings beneath `runtime`. AdaScript source continues to own game
behavior. It does not regain plugin assembly or a `main()` function.

An entry plan may contain any useful combination of:

- `scene`: a project-relative scene path;
- `view`: a stable AdaScript `@view` identifier;
- `startupSystem`: a stable `@system` identifier whose scheduler is `startup`.

At least one entry is required. This permits UI-only, scene-only, and scene plus
HUD projects. Runtime startup order is fixed: validate the entry and plugin
graph, compile AdaScript, initialize the runtime world and assets, install
feature plugins and AdaScript systems, load the scene, run the startup
scheduler, publish the root view, then enter normal frame updates.

The `view` field remains for manifest compatibility only. It is rejected while
AdaScript views are disabled by [ADR-0016](0016-temporarily-disable-adascript-adaui.md).

`editor.startupScene` remains editor-owned. It selects the fallback scene for
in-editor play. `runtime.entry.scene` selects the scene used by the standalone
game runtime.

### Resolve native plugins by stable identifiers

Project metadata uses stable identifiers such as `physics2d`, `audio`, and
`tilemap`, never Swift type names. A precompiled registry maps identifiers to
native plugin factories, display metadata, dependencies, platform availability,
and supported settings.

Configuration uses a versioned preset plus explicit overrides:

```json
{
  "preset": "game2d",
  "presetVersion": 1,
  "enable": ["audio", "tilemap"],
  "disable": ["light2d"]
}
```

The resolver computes a deterministic dependency order. JSON array order does
not control setup. Disabling a plugin required by another enabled capability is
a validation error. Unknown plugins and unsupported preset versions fail before
the runtime window opens.

The initial presets are `ui`, `game2d`, and `game3d`. Platform/application host
plugins remain controlled by AdaEditor and cannot be disabled by projects.

### Keep settings typed

Plugin settings are decoded into plugin-specific value types. The first shipped
setting is the two-component finite gravity vector for `physics2d`. Arbitrary
untyped dictionaries are not passed into plugins.

Window title, initial size, and resizability are project settings. On platforms
such as iPadOS these values are hints subject to system window-scene policy.

### Preserve one startup-system ordering point

AdaScript systems remain annotation-discovered. When `startupSystem` is set, the
matching system must use the `startup` scheduler and is inserted first in that
scheduler. Other systems continue to follow scheduler dependency ordering.

### Read schema version 2 without parallel runtime paths

The decoder maps legacy `runtime.entryView` and `runtime.startupScene` fields
into the version 3 entry plan. New metadata writes only the entry-plan shape.
Runtime execution consumes one normalized representation.

## Implementation status

- [x] Schema version 3 entry, plugins, typed Physics2D settings, and window data.
- [x] Backward decoding for schema version 2 entry fields.
- [x] Versioned `ui`, `game2d`, and `game3d` presets.
- [x] Stable plugin registry, dependency resolution, and validation.
- [x] Scene-only runtime builds and startup-scene loading.
- [x] Optional root view and prioritized startup system.
- [x] Project Settings controls for entry, presets, plugins, Physics2D, and window.
- [ ] Per-platform plugin availability and runtime overrides.
- [ ] Settings schemas for rendering, audio, 3D physics, and asset preloading.
- [ ] Persist and display the fully resolved runtime manifest for diagnostics.
- [ ] Device validation of scene plus HUD startup from a cloud-backed project.

## Consequences

- AdaScript projects can express common application composition without Swift.
- Plugin configuration remains limited to capabilities compiled into the host.
- Preset versions make default changes explicit and reviewable.
- Scene-only projects no longer need a placeholder AdaUI view.
- Invalid plugin graphs fail as project diagnostics instead of assertions during
  plugin setup.

## Rejected alternatives

### Store Swift plugin type names

Rejected because names are not stable API and the iPadOS host cannot discover or
load arbitrary project binaries.

### Let JSON array order define plugin setup

Rejected because it exposes engine implementation ordering and permits invalid
dependency graphs.

### Restore an AdaScript `main()`

Rejected because the native host owns process startup. The runtime entry plan and
startup scheduler provide dynamic project initialization without a second app
lifecycle.
