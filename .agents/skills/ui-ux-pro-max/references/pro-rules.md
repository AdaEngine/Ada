# Rendered UI Verification

Compare the affected surfaces with the approved proposal, root Studio rules, and
[construction guidance](quick-reference.md). Apply checks to changed controls and supported platforms.
This checklist is not proof that existing Studio controls already comply.

## Theme and layout

- [ ] Only existing Studio font assets/text roles are used; no font files, CDN imports,
  font-pairing recommendations, or substitute families were introduced.
- [ ] Shared semantic colors and control styles are used. Borders, dark inputs, white dark-theme
  caret, icons, labels, and selection are visible at the actual display scale.
- [ ] Alignment, heights, spacing, grouping, and density match neighboring Studio controls.
- [ ] Material Icons/Symbols have consistent size/weight/alignment, appropriate localized action
  tooltips, and accessible names for icon-only controls.
- [ ] Long English/Russian labels, paths, and user values remain available without clipping,
  overlap, broken layout, or inaccessible truncation.
- [ ] Supported themes, narrow/normal sizes, scaling, and relevant orientations were inspected.
  Text and state remain readable against the composed background.

## Interaction and forms

- [ ] Applicable default, hover, pressed, focused, selected, disabled, expanded, busy, and error
  states were exercised. Selection survives pointer exit and rebuilds.
- [ ] Actions fire as intended; disabled controls do not fire.
- [ ] Dropdowns open, select, scroll, dismiss, and return focus on affected input paths.
- [ ] Fields support visible caret, selection, editing, labels, and appropriate validation timing.
- [ ] Invalid submission preserves values and gives actionable field errors. Multi-error forms
  provide an appropriate summary and focus path.
- [ ] Loading, empty, partial, and failed operations give relevant feedback/recovery.
  Cancellation, retry, repeated input, and late async results preserve correct state.
- [ ] Dialog/menu opening and dismissal preserve predictable focus/navigation.

## Keyboard, touch, and accessibility

- [ ] Keyboard navigation, visible focus, shortcuts, accessible names/state, and reading order work.
- [ ] Focused controls/errors remain visible with overlays, scrolling, and the on-screen keyboard.
- [ ] Essential actions/help work without hover; gesture/drag interactions have alternatives.
- [ ] iOS hit areas are at least 44 x 44 pt without overlap; safe areas/system gestures work.
- [ ] Enlarged text/reduced motion preserve layout, operation, focus, and final state.
- [ ] Errors, selection, and status convey meaning through more than color alone.

## Evidence

- [ ] Compare the rendered result with the approved visual at representative sizes.
- [ ] Test changed testable interactions through real production paths.
- [ ] Supply screenshots/preview paths and identify platforms, layouts, and states exercised.
- [ ] Report failed checks as failures and unavailable runtime/device checks as blocked.
  Builds, source inspection, and unit tests alone are not visual verification.
- [ ] Fix discrepancies and supply the result/evidence to independent review.
