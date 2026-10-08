---
name: ada-project-orientation
description: Inspect an Ada project before coding, scene, asset, build, or debugging work.
allowed-tools: files.read, files.write, terminal, editor.project.context, editor.scene.list_open, editor.asset.list, world.list_worlds, ui.list_windows
---

# Ada Project Orientation

Start from the project rather than assumptions.

- Use `editor.project.context` to identify the open project and active document. Use `editor.scene.list_open` to find scene documents already open in the editor.
- Read `.ada/project.json` first. Treat `build.system`, declared source and resource roots, runtime entry, plugins, and run destination as authoritative.
- Use the term AdaScript in user-facing text. `adascript` is the canonical build-system value; `gravity` is legacy compatibility only.
- Read a nearby `AGENTS.md`, project README, and relevant AdaEngine DocC before choosing an API or file format.
- Keep every file operation inside the opened project or an explicitly allowed resource root.
- Prefer structured AdaEditor tools for scenes and assets when available. Preserve `schemaVersion` and unknown fields when editing documents directly.
- Do not claim success from a file write alone. Build or validate the narrowest affected path and use runtime inspection for behavior that can be launched.
