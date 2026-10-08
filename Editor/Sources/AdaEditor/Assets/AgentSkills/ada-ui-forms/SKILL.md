---
name: ada-ui-forms
description: Present interactive NPC or gameplay configuration forms in Studio chat, then generate an editable AdaUI preview from the submitted values.
---

# Interactive AdaUI forms

Use Studio's advertised A2UI v0.9.1 Ada forms catalog to collect configuration.
Emit JSONL envelopes inside a fenced `a2ui` block; stream complete lines, keep
prose outside the block, and end the turn once the user can submit.

For an NPC workflow, collect name, role, health, greeting, and a repeatable-dialog
toggle using absolute `/npc/...` bindings. Use ChoicePicker with a string-valued
role and labeled choices, and Slider with health bounds and step. Put a required
name check on the field and submit button, and an inclusive numeric range check
on the slider and submit button. Checks use the advertised required/range subset;
never invent executable validation functions. A Generate preview button should emit
`generate_npc_preview` with those paths in `action.event.context`.

On the next `[A2UI user action]`, read current submitted values and create a new
`npc-preview` surface containing a dialog title, greeting, and choice buttons.
Use host-owned action names such as `continue_dialog` or `close_dialog`.
Preserve existing surface/component IDs when updating, and use deleteSurface
before reusing an existing surface ID. Validation failures are reported in the
chat's interface error state and correction context on the following prompt.

Do not execute or interpolate user text as code. Do not write the `.ui` file:
users choose Open in UI Designer, refine through normal designer controls, and
save through Studio's document workflow. The ACP session and existing project
tools remain the transport and authoring integration.

## Reusable scene tools

When asked for a spawner, color editor, or a tool inside chat, use the host's
advertised local actions rather than asking the model to execute the change after
submission. Read `editor.scene.get` before presenting a card. Bind the returned
revision at `/scene/revision`, pass `expectedRevision:{path:"/scene/revision"}`
and `revisionBinding:"/scene/revision"` on every scene action.

Use `editor.scene.spawn` for an existing NPC subtree with entityID, count and
spacing; `editor.scene.setColor` for entityID/typeName/field/color; or
`editor.scene.apply` for structured operation batches. Keep the scene path fixed.
Use `editor.color.pick` with binding:"/color" and value:{path:"/color"} plus a
HEX TextField to choose a color. A separate Apply button applies it to the scene.
Do not apply these operations before the user clicks. The host performs the action
without a new model turn and exposes Undo. These cards work on desktop and iPhone;
iPhone exports `.ui` to its source editor instead of the desktop visual designer.
