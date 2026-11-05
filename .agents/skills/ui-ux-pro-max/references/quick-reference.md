# UI Construction Guidance

Use only the sections relevant to the requested interface. The root Studio rules own visual choices;
these notes cover practical construction within the existing application.

## Layout and readable content

- Group related controls and align labels, fields, icons, and action rows with neighboring UI.
  Give the main task a clear place without making every action equally prominent.
- Use existing Studio font assets and text roles. Express emphasis through their supported weights,
  sizes, and spacing. Verify English/Russian glyphs and required symbols with the actual fonts.
- Let localized labels and user values wrap or disclose the full value. Use truncation only in
  constrained surfaces with an accessible path to the complete text.
- Make layout children shrink correctly. Long paths, URLs, and identifiers must not widen a panel
  unexpectedly or cover adjacent controls.
- Keep essential actions available in narrow windows and enlarged text. Preserve selection,
  drafts, and navigation context across layout/orientation changes.
- Use scrolling deliberately for lists, inspectors, tables, and code areas. Fixed elements,
  overlays, and the on-screen keyboard must not hide focus or the end of scrollable content.

## Control semantics and state

| Intent | Preferred control | Check |
| --- | --- | --- |
| Execute a command | Button | Label, hover/press/focus feedback, disabled/busy behavior |
| Change an immediate boolean setting | Toggle | Label, current on/off state, usable hit target |
| Select independent items or deferred form values | Checkbox | Checked/unchecked and mixed state when needed |
| Choose one list value | Dropdown/select | Current value, keyboard selection, dismissal, scrolling |
| Search while choosing or allow typed values | Combo box | Input, results, empty state, validation, focus |
| Switch sibling views/modes | Tabs or segmented control | Selection and preservation of each view's state |
| Reveal contextual actions | Menu | Trigger label, item semantics, dismissal, focus return |

Use shared/platform controls rather than clickable generic containers. Hover/press feedback must
not erase selection. Disabled controls need disabled input semantics as well as visual treatment.
Avoid moving surrounding layout as states change.

## Forms and validation

- Provide persistent labels and helper text. Placeholder text does not replace a label.
  Choose value semantics, keyboard type, and ranges appropriate to the field.
- Choose validation timing for the task. Avoid errors on incomplete input still being entered,
  but validate committed/submitted values reliably.
- Place specific actionable errors beside their fields and associate them programmatically.
  Preserve values. For multiple errors, provide a navigable summary on failed submission
  and move focus deliberately without trapping the user.
- Distinguish invalid values from network/server failures. Explain what can be corrected,
  retried, cancelled, or retained as a draft.
- Keep focused fields, caret, selection, and errors visible as layout or keyboard changes.
- Prevent duplicate submissions; show progress and a recovery/cancellation path. Late async
  results must not overwrite newer values or another selection.

## Focus, overlays, and navigation

- Keep keyboard order consistent with the visual task order. Provide visible focus and retain
  platform/system shortcuts.
- Give icon-only controls accessible names; expose applicable selected, checked, expanded,
  and busy states. Hide purely decorative icons from the accessibility tree.
- For modal dialogs, move focus inside, contain navigation while modal, support appropriate
  cancellation, and return focus to a useful trigger on dismissal.
- Test dropdown/menu opening, item navigation/selection, scrolling, Escape, outside dismissal,
  and focus return using the platform's conventions.
- Preserve a predictable back path and edited state across tabs, details, and nested views.
  Tooltips supplement labels; essential actions/help need keyboard and touch paths.

## Pointer, touch, and accessibility

- Hover supplements pressed and keyboard-focus feedback. Touch actions must work without hover.
- On iOS use at least 44 x 44 pt hit areas with enough separation. Expanded hit regions must not
  overlap adjacent actions. Respect safe areas and system gestures.
- Adapt desktop density for touch and enlarged text. Verify actual target units and hit testing.
- Use existing readable text/surface pairs. Check contrast on rendered backgrounds, including
  muted text and overlays. Convey errors/selection with more than color alone.
- Provide alternatives to precision dragging and gesture-only essential actions.
- Respect reduced motion and text scaling. Use motion for a state change and preserve correct
  final state/focus when a rapid interaction interrupts a transition.

## Loading, data, and responsiveness

- Cover relevant empty, loading, partial, offline, and error states. Distinguish empty results
  from request failure and provide an appropriate recovery action.
- Reserve space for async content where movement would disrupt the current task.
- Keep typing, scrolling, and selection responsive. Use existing virtualization, cancellation,
  and update scheduling when relevant; measure representative screens before performance claims.
- In tables, retain readable headers/alignment, selection, and access to off-screen values.
  Expose provided sort/filter state and preserve a useful keyboard position.
