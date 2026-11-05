---
name: adaengine-studio-design
description: Propose, implement, or review Ada Studio visual and interaction changes across desktop, web, and iOS using the Studio design rules, existing theme, and rendered evidence. Use for editor controls and screens, not game-authored art direction or non-visual engine work.
---

# Ada Studio Design

Read [Ada Studio Visual Design Rules](../../../AGENTS.md#ada-studio-visual-design-rules).
That section is the source of truth for control appearance, references, icons, touch, and verification.
Read the nearest platform instructions and only the relevant
[UI/editor reference](../adaengine-development/references/ui-editor.md).

## Establish the visual

Inspect the current screen and its shared controls before proposing a change. In shared AdaUI editor
screens, start with [Theme.swift](../../../Editor/Sources/AdaEditor/UI/Editor/Theme.swift),
`Theme.adaEditor`, and `theme.editorColors`; trace the current Material Symbols/font helper and
control styles in the owning source. Browser and mobile surfaces may have different theme owners.

Use [ui-ux-pro-max](../ui-ux-pro-max/SKILL.md) for focused research. Run its search script from
the repository root, using the Python interpreter available on the host:

```text
python .agents/skills/ui-ux-pro-max/scripts/search.py "keyboard focus dropdown" --domain ux
python .agents/skills/ui-ux-pro-max/scripts/search.py "touch target spacing" --domain web
```

For a new screen or broader visual direction, also run:

```text
python .agents/skills/ui-ux-pro-max/scripts/search.py "developer IDE dark compact" --design-system -p "Ada Studio"
```

Treat generated palettes/layouts as research to reconcile with Studio's existing theme and references.
Do not persist a competing theme system. AdaUI is not a supported search stack: use domain guidance
and actual AdaUI APIs. Use `--stack swiftui` only for actual SwiftUI surfaces; inspect browser
dependencies before choosing web stack guidance. Load [design-system](../design-system/SKILL.md)
for token/component work and [ui-styling](../ui-styling/SKILL.md) only for matching web tooling.

Before production UI edits, present a rendered mockup, annotated screenshot, or runnable preview.
Show the affected screen/control, important states, and touch adaptation when applicable. Identify
which reference informed the proposal and how it fits neighboring Studio UI. Reuse approved visuals
when applicable; handle new direction approval in the existing
[feature flow](../adaengine-feature-flow/SKILL.md), without adding a second approval process.

## Implement and inspect

Use shared semantic controls and theme roles. For missing states or styling, improve the reusable
control/theme layer when appropriate instead of patching only a single instance. Keep scope tied
to the requested screen; report an engine capability gap rather than inventing unsupported modifiers.
Apply [TDD](../adaengine-tdd/SKILL.md) to testable interaction behavior and the normal contribution
checks. A screenshot complements behavioral tests; neither replaces the other.

Review the rendered screen with the root design checklist and the relevant upstream
[professional rules](../ui-ux-pro-max/references/pro-rules.md). Exercise pointer/keyboard and touch
on the actual affected surfaces, including dropdown dismissal, caret visibility, tooltip access,
selection persistence, long localized labels, narrow layouts, and enlarged text.

For handoff, provide the proposal and result paths, platforms/states inspected, discrepancies fixed,
and checks that remain blocked. Supply these artifacts to
[independent review](../adaengine-review/SKILL.md). Do not describe an unlaunched interface as visually verified.
