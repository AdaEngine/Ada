# Ada Studio Control Design

Status: required visual rules, specified by the human's annotated screenshots on 2026-11-06.
Applies to native Studio controls, including animation assets, Inspector, Animator and Graph.
The existing scene Transform Inspector is the reference for vector fields. These rules
correct the agreed workspace presentation; they do not alter animation semantics or approve IK.

## Buttons and actions

- An action must look interactive before hover: use a contrasting themed surface, a subtle
  border and rounded corners. Bare text is not an acceptable Save, Reload, Extract, Insert
  Key, Preview Pose, Apply, graph Add/Remove, Undo/Redo, Fit or Pan button.
- Use the editor's blue accent for the primary action and for active toggles/modes. Active
  tabs and Auto Key/Loop/Pan states need a filled or bordered accent treatment in addition
  to their label. Do not communicate state through text alone.
- Secondary actions retain a neutral button surface. Hover, pressed and keyboard focus
  must be visible; disabled controls keep their shape and use reduced emphasis.
- Icon-only viewport and playback buttons follow the same surface/state rules. Preserve
  their existing identifiers, readable hover help and keyboard/input behavior.
- A hierarchy row may use the existing full-row hover/selection treatment instead of
  separate button boxes. Disclosure arrows stay aligned with their row. This exception
  does not permit bare toolbar or Inspector action text.
- Use theme tokens for surfaces, borders, foregrounds and accents. Do not rely on a
  platform-default white input background or a transparent default button style.

## Text and number fields

- Text, search and scalar number fields use a themed surface, thin visible border,
  rounded corners and horizontal padding. Keep a consistent compact height of 26–32
  logical points appropriate to the surrounding toolbar or Inspector.
- Label fields clearly. A static value/path must be distinguishable from editable input.
  Long paths, intermediate numeric drafts, negative values and scientific notation remain
  supported. Styling must not parse or commit edits earlier than the owning control.
- Vector/quaternion rows match the scene Transform Inspector: an inline colored axis
  badge at the leading edge of each numeric field, with X red, Y green, Z blue and W purple.
  Keep the axis letter visible as well as color. Axis labels above plain boxes are insufficient.
- Give every component the same height, padding and border. Share available width and
  preserve readable values when the Inspector is resized; constrain each cell rather
  than letting a long value expand the entire row beyond the panel.
- Preserve selection, caret, focus and keyboard editing. A decoration must not intercept
  input or make only a small part of the visible control clickable.

## Scrolling and resizing

- Any overflowing Inspector, hierarchy or graph-properties list shows a scroll indicator.
  Indicators track the content offset and resize with the viewport; no indicator is needed
  when the whole content fits.
- Reserve padding so the indicator does not cover field values or action labels. The
  scrollbar belongs to the panel viewport and must not scroll away with its content.
- Keep the Model panel and outer panels resizable. Check controls at narrow and wide
  widths and with longer Russian labels. Scrolling must reach the final field/action.

## Implementation and visual acceptance

Reuse common themed action/field/axis components within a workspace; do not apply one-off
background fixes to individual screenshots. `DefaultButtonStyle` only forwards its label
and therefore is suitable only when the label already supplies the complete row/card
appearance. AdaUI `ScrollView` indicators must be enabled explicitly.

Check idle, hover/focus, pressed, selected and disabled states in the actual editor. Cover
both asset animation and the scene Animator Graph. Inspect Save/Reload, pose controls,
preview toolbar, timeline controls, graph toolbar and graph properties. Verify that no
white default fields or bare action labels remain. Rendered control and overflow regressions
belong in the owning UI tests; screenshots provide additional native visual evidence.

User workflow: [Animation authoring](../AnimationAuthoring.md).
