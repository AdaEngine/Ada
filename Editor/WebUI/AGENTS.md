# WebUI Agent Guide

This guide applies to `Editor/WebUI/`. The [repository rules](../../AGENTS.md)
and [shared editor rules](../AGENTS.md) also apply. Read native editor references
only when changing the corresponding shared contract or integration.

## Working here

- This is the React/DOM browser shell, separate from the Swift editor package.
- Run `pnpm test`, `pnpm run build` and `pnpm run check:localization` from this
  directory as applicable; use the pnpm version pinned in [package.json](package.json).
- For export/build setup and browser acceptance, read
  [StudioWeb.md](../Documentation/StudioWeb.md). For shared value/component codecs,
  inspect `../StudioCore/` and the corresponding native/Player implementation.
- Keep en/ru catalogs and the shared language preference in sync. Native `L10n`
  calls and Swift localization tests belong to the native UI path; this frontend
  uses its existing localization helpers and build-time checks.

## Read by task

- Viewport/Player, undo, cloud recovery, navigation, assistant or Annotate:
  [browser contracts](../Documentation/AgentGuides/browser.md).
- Shared native/browser Cloud account, AI wallet or Community integration:
  [Mobile and Cloud](../Documentation/AgentGuides/mobile-cloud.md).
- Native bundled skills, tools or generated agent resources:
  [agent tools](../Documentation/AgentGuides/agent-tools.md).

## Maintaining these instructions

Keep browser-specific rules here and shared rules in `../AGENTS.md`.
Update only the affected capability and its limits; trace the implementation and
nearest tests before declaring a feature missing. Implementation presence and
test filenames do not prove a hosted deployment or successful runtime validation.
