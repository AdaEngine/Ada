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
Use only the font assets and text roles already used by Studio. Verify readability, glyph coverage,
wrapping, and scaling using those fonts; do not select a new font family or visual style.

Use [ui-ux-pro-max](../ui-ux-pro-max/SKILL.md) and its
[construction guidance](../ui-ux-pro-max/references/quick-reference.md) for layout,
control choice, states, validation, focus, accessibility, and responsive behavior.
The retained skill is Markdown guidance; there is no search or design-system generation step.
Reuse the current theme/component owners instead of generating a competing token system.
Inspect actual APIs and browser dependencies; do not apply SwiftUI or web-framework advice to AdaUI.

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
