---
name: ui-ux-pro-max
description: Build and review Ada Studio UI using existing components, theme, and fonts. Covers layout, control semantics, interaction states, form validation, accessibility, responsive behavior, and rendered verification. Use for practical interface work, not branding or choosing a new visual style.
license: MIT
---

# Studio UI/UX Practice

Apply the [Studio rules](../../../AGENTS.md#ada-studio-visual-design-rules) and
[Studio workflow](../adaengine-studio-design/SKILL.md).
This is a curated adaptation of upstream guidance; [provenance](../design-skills-provenance.md)
records its scope.

## Start from the application

Inspect the affected screen, neighboring controls, platform, and theme owners. Use only Studio's
existing font assets and text roles, semantic colors, icons, and shared component styles.
Build hierarchy with those text roles, alignment, spacing, and grouping. Check long labels,
glyph coverage, text scaling, and font metrics using the actual Studio fonts.

Choose controls by behavior. Buttons execute actions; toggles change immediate boolean settings;
checkboxes represent selections; dropdowns select values; tabs/segmented controls switch views
or mutually exclusive modes. Preserve each control's input and accessibility semantics.
AdaUI, native wrappers, and the browser frontend have different implementation owners:
verify the actual stack and available APIs before coding.

## Plan the interaction

Read the relevant sections of [UI construction guidance](references/quick-reference.md).

- Establish the main task, information hierarchy, labels, navigation, and panel boundaries.
- Cover default, hover, pressed, focused, selected, disabled, expanded, loading, empty, and error
  states where applicable. Keep persistent selection separate from transient pointer feedback.
- Decide when values commit, how validation appears, how async work is cancelled/retried,
  and where focus goes after opening, submission, dismissal, or failure.
- Adapt layout and target sizes to the actual input platform, window, safe areas, keyboard,
  and text scaling. Preserve access to essential actions as space decreases.

Present the visual proposal required by the Studio workflow before production UI edits.

## Implement and validate

Reuse theme roles and controls; extend shared components only for the requested behavior.
Keep focus, selection, and entered values stable across rebuilds and async updates.
Provide labels and actionable errors, keyboard operation, accessible names/state,
and a touch path to essential help. Test changed interactions through production paths.

Before handoff, use [rendered UI verification](references/pro-rules.md). Record screenshots or
previews, platforms, states, and layouts actually exercised. Fix discrepancies and report
unavailable runtime checks as blocked. Build success and source review do not prove visual quality.

The guidance is maintained directly in Markdown. There is no font/style catalog, palette or
design-system generator, search CLI, framework installer, or external generation service.
