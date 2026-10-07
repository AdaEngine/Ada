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
