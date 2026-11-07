# AdaEditor Agent Guide

The [repository rules](../AGENTS.md) apply. Keep this entry point short: read
only the references relevant to the task, and check for a nearer `AGENTS.md`
before editing. Do not load the whole capability inventory by default.

## Shared rules

- `Editor/` is a separate Swift 6.2 SwiftPM package with a local engine dependency.
  Run Swift package commands here or use `--package-path Editor` from the root.
  [Package.swift](Package.swift) owns dependencies/resources;
  [project.yml](project.yml) owns XcodeGen app configuration.
- Shared editor UI uses AdaUI. Native wrappers, mobile screens and browser UI
  have separate boundaries; verify availability on the actual target platform.
- For Studio visual/interaction work, follow the root
  [visual design rules](../AGENTS.md#ada-studio-visual-design-rules) and use
  [adaengine-studio-design](../.agents/skills/adaengine-studio-design/SKILL.md):
  present a visual before implementation and inspect the rendered result before completion.
- Native controls follow [the control design rules](Documentation/Design/Controls.md):
  visible button surfaces/states, themed fields, inline colored axis badges and overflow indicators.
- Every UI change includes English and Russian text in the same change. Native
  UI uses `L10n` and the shared language preference; read the
  [localization rules](Documentation/AgentGuides/localization.md) before changing it.
  Browser localization rules live in [WebUI/AGENTS.md](WebUI/AGENTS.md).
- Keep mocks, fixtures and QA harnesses in test targets or separate executables,
  including for Debug builds; do not add QA launch hooks to the main app.
- Preserve unrelated edits and shared `.build` caches; isolate scratch/module
  caches when needed. Public scripting terminology is **AdaScript**; `Gravity*`
  names are compiler/VM/tooling internals.
- For native build, launch, packaging or platform validation, first read
  [platforms](Documentation/AgentGuides/platforms.md). User validation requires a
  complete staged distribution with its SDK/resources, using the platform launcher.
- Before calling a capability missing, trace its UI entry point, implementation
  and nearest tests. Distinguish engine support, editor authoring, target platform
  and runtime evidence. Build success, plans and test filenames do not prove Play.

## Read by task

The following files are references, not an instruction to read every link.
For cross-area changes, read each affected area; keep inventory details there.

| Task or path | Read |
| --- | --- |
| Browser shell, `WebUI/` | [WebUI instructions](WebUI/AGENTS.md) |
| Package, native platforms, wrappers, installation | [Platforms](Documentation/AgentGuides/platforms.md) |
| Native labels, menus, errors, language switching | [Localization](Documentation/AgentGuides/localization.md) |
| Projects/files, tabs, code, search, input | [Workbench](Documentation/AgentGuides/workbench.md) |
| Scene hierarchy, viewport, terrain, inspector | [Scenes](Documentation/AgentGuides/scenes.md) |
| `.ui` resources, visual design, UI bindings | [UI Designer](Documentation/AgentGuides/ui-designer.md) |
| Images, tiles, models, audio, animation, Shader Graph | [Assets](Documentation/AgentGuides/assets.md) |
| Build targets, Play, Movie Maker, CLI, export, AdaPlayer | [Build and Play](Documentation/AgentGuides/build-play.md) |
| Terminal, tests panel, LLDB, CPU profiling | [Debugging](Documentation/AgentGuides/debugging.md) |
| Agent UI/chat, A2UI, ACP, source control, Studio Tools | [Agent interface](Documentation/AgentGuides/agent-interface.md) |
| MCP/host tools, capture/scenarios, generated assets, bundled skills | [Agent tools](Documentation/AgentGuides/agent-tools.md) |
| Mobile screens, Community, publishing, Cloud accounts/AI | [Mobile and Cloud](Documentation/AgentGuides/mobile-cloud.md) |

## Contributor skills

Use the existing repository skills when their task applies; do not load them all.

- Swift/editor implementation: [adaengine-development](../.agents/skills/adaengine-development/SKILL.md).
- Studio visual design and review: [adaengine-studio-design](../.agents/skills/adaengine-studio-design/SKILL.md)
  with [ui-ux-pro-max](../.agents/skills/ui-ux-pro-max/SKILL.md), using Studio's existing font
  assets and theme. These skills retain UI construction and verification guidance.
- New or extended product behavior: [feature flow](../.agents/skills/adaengine-feature-flow/SKILL.md)
  and its repository-local [requirements interview](../.agents/skills/adaengine-enrich/SKILL.md).
- Testable behavior/fixes: [TDD](../.agents/skills/adaengine-tdd/SKILL.md).
- Before completion: [independent review](../.agents/skills/adaengine-review/SKILL.md)
  and the root [validation workflow](../.agents/knowledge/workflow.md).

Contributor skills govern this repository. Game-authoring skills shipped in
`Sources/AdaEditor/Assets/AgentSkills/` govern Studio agent sessions; discover/read
only the needed skill through `editor.skills.list/read` when working in that host.

When a capability changes, update its owning reference and relevant limits.
Keep proposals separate from implemented behavior and report unverified paths.
