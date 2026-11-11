# Ada AI Tool Consolidation

Status: Proposed for review.

## Scope

Group hosted Ada AI's model-facing tools by task and use the same action contract on Desktop, Mobile, and Web. The current clients register 85, 55, and 38 functions respectively. Most functions in a group share a workflow, such as inspecting an animation draft, applying edits, and saving it. Existing project services remain responsible for carrying out each operation. ACP, AdaMCP, the mobile external-provider runtime, and Web BYOK keep their existing tool interfaces.

The consolidation also addresses three contract mismatches in the current source. Native Build advertises mixed-case animation tool names that fail the server's lowercase name check. Desktop Ask and Plan advertise internet reads outside the server's native Plan allowlist. Web advertises three operations outside its server allowlist. These mismatches are source findings, with deployed versions to be verified separately.

## Model-facing catalog

Each function has a lowercase name, a required `action`, and arguments validated against that action's schema. Desktop, Mobile, and Web use the same action ID, argument meaning, and core result fields when they support the same operation. Adapters can add typed platform details. Each host advertises only actions available for the current platform, mode, and provider. A function with zero available actions is omitted.

The proposed ceiling is **17 function families across all hosts**. The table shows representative actions and host-specific differences. Implementation must map every existing in-scope action to the catalog.

| Function | Actions and scope |
| --- | --- |
| `editor_project` | Read context, configure settings, inspect input bindings and selection, apply a project transaction or import an example on hosts that support those actions. |
| `editor_files` | List, search, read, create, patch, replace, and delete. Native create retains its collision check. Web replacement and deletion stay Web-only. |
| `editor_scene` | List with an explicit scope, read, validate, apply revisioned operations, undo, and bind an asset where supported. Desktop listing can be limited to open scenes. |
| `editor_task` | Build, test, inspect status, stop, and read build or editor output. Build results indicate whether the host returns a completed result or a task to poll. |
| `editor_play` | Start, stop, inspect diagnostics, send input, capture a camera frame, or run a scenario. Capture reports the frame source and scenario results carry their verification limits. |
| `editor_simulation` | Start, step, inspect, and stop the Mobile isolated simulation. |
| `editor_docs` | Search and read reference articles. |
| `editor_catalog` | Inspect API and component metadata, list and read skills, and list and read examples. |
| `editor_adascript` | Diagnostics, completion, hover, and definition through native AdaScript LSP. |
| `editor_web` | Search, fetch, and download through native hosts with the existing URL and destination checks. |
| `editor_assets` | List, validate, render a procedural texture, generate a sprite or voxel asset, and inspect an image when the selected host and provider support vision. |
| `editor_model` | Inspect, validate, import, generate, edit a material, and assign a texture. |
| `editor_atlas` | Read, write, and pack atlas resources. |
| `editor_tiles` | Read, create, and edit tilesets and tile maps. Action names identify the resource being changed. |
| `editor_audio` | Generate and inspect audio resources. |
| `editor_animation` | Inspect, edit, sample, save, and preview clips, graphs, and IK modifiers on Desktop. Names such as `graph_inspect` and `modifier_apply` identify the operation. |
| `editor_progress` | Update Web conversation progress. |

For example, a Desktop agent can call `editor_animation` with `{"action":"inspect","path":"Assets/Walk.animlib"}` to obtain the draft revision and stable IDs. A later `apply` uses that revision and the existing edit operations. Each action has its own schema and permission policy. Prefer explicit typed arguments wherever the provider can carry them. Keep an existing bounded JSON payload at the adapter boundary where that is necessary to preserve the underlying contract. Verify the serialized schemas against Coder Next and measure their total size as well as the function count.

## Contract and permission ownership

Keep a versioned action catalog in AdaEngine. Each entry defines its tool family, action ID, argument schema, supported hosts, Ask/Plan eligibility, and approval policy. Swift and Web adapters use those entries to advertise and dispatch operations. Ada Cloud consumes a pinned artifact from the same catalog for validation. Verify parity in CI. The Cloud request must declare the contract version and the server must validate tool names and action schemas against that version and mode before provider submission.

Dispatch resolves and validates the exact action before requesting approval or touching the project. Plan advertises only its authorized actions and rejects fabricated Build actions during dispatch. Approval and any session grant are keyed by action and project, with any narrower scope required by the existing policy. A grant for `patch` cannot authorize `delete`. Preserve revision and undo rules, project ownership, dirty-document checks, path and network limits, cancellation, and successful change notifications. Transcript activity names the action and target so that a grouped tool call remains reviewable.

## Compatibility and rollout

Introduce the grouped catalog as an additive version of the hosted Ada AI contract. The service continues to accept legacy clients while clients adopt the new version. Cover the three legacy validation mismatches with exact allowlist entries and retain the mode policy for each legacy action. Advance the service before enabling the new client contract. Keep an existing in-flight turn on its selected contract. Keep older activity records visible and carry completed legacy turns forward as conversation context without replaying their operations under the new contract.

Update Ada AI's system guidance and bundled workflow references to resolve operation names for the current host. Maintain compatibility with existing dot-name guidance used by ACP and AdaMCP. The design reuses the existing animation revision model and [scripted asset generation rules](../ArchitectureDecisions/0026-scripted-asset-generation-and-autonomous-studio.md).

## Acceptance and documentation

1. Inventory parity checks account for every legacy hosted operation and show at most 17 model-facing families across the supported hosts. Unsupported actions are omitted. Build and Plan requests assembled by each applicable client pass the production service validator.
2. Production dispatch tests prove that invalid arguments, unknown actions, unavailable actions, and disallowed Plan actions cause no side effects. Cover permission denial, session-grant isolation between actions, and existing file, scene, and asset protections.
3. Exercise a representative context, edit, build, and Play flow on Desktop, Mobile, and Web, using each host's available editing operations. Also verify native internet reads, an animation edit with a stale revision, browser project transactions, legacy clients, and a saved conversation across the contract upgrade. Report platform or provider checks that remain unavailable.
4. Record tool schema bytes and tool-selection outcomes on fixed representative prompts before and after consolidation. Exercise tool calls with Coder Next before rollout. A lower function count alone does not establish lower context use or reliable selection.
5. Update the user-facing [Cloud AI guide](../../Editor/Documentation/CloudAI.md) and link it from the [agent catalog guide](../../Editor/Documentation/AgentCatalog.md). Explain which actions are available by host and mode. Include a verified file read, patch, and build example, plus the Plan restriction. Check navigation, relative links, and offline documentation freshness for any bundled guide or workflow that changes.
