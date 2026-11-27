# Intents and tools for Studio plugins

Status — Proposed for approval

## User outcome

An installed Studio plugin can expose optional actions to Ada AI in the active project. Users can grant access in Project Settings → Studio Tools, see which plugin would run an action, and revoke access at any time. Plugins can contribute both intents and tools. Ada Studio supplies the discovery, permissions and invocation runtime on Windows and macOS.

Follow the App Intents model of describing a discoverable action with typed inputs and returning a reference to an entity another action can use. Apple defines domain schemas for semantic discovery. Ada Studio defines its own schemas for project operations and uses them in Ada AI across the supported desktop hosts. [Apple WWDC26 App Intents and App Schemas](https://developer.apple.com/videos/play/wwdc2026/240/).

## Plugin contract

| Contribution | Declared by the plugin | Interpreted by Studio |
| --- | --- | --- |
| Intent | Stable action ID, a Studio intent kind, localized title and an implementation binding. | The intent kind supplies a fixed input and result shape, an effect and semantics shared by providers. |
| Tool | Stable tool ID, localized title and concise description, bounded input and output schemas, effect class and an implementation binding. | Studio validates the schemas and exposes the tool under the plugin's namespace. |
| Entity reference | The supported intent or tool result returns a display label and an opaque reference. | Studio binds the reference to its active project, issuing plugin and entity type, and resolves it for authorized calls. |

The installer validates the versioned declaration and its bindings before enablement. Names are unique within a plugin and action identity includes the plugin ID. The first intent kind is asset search by title and optional source. It returns a bounded list of typed asset references. Studio resolves the kind to a currently enabled provider. When more than one provider is eligible, Ada AI can select a specific provider based on the user's source or plugin choice. The user chooses when the target remains ambiguous.

The External Asset Library contributes the asset-search intent and a read-only details tool which accepts one of its asset references. Example request — “Find my Fab benches and tell me which ones I already have on disk.” Ada AI can call search, then details for a matching asset. Other plugins can declare their own typed tools without adding a new Cloud function. The first release includes a runnable example plugin with a custom read-only tool which returns a validated structured result.

## Host and permissions

- The project-local Studio Tools host owns registration and lifecycle. A contribution binds to an allowlisted native operation or a declared handler in the restricted Studio Tools AdaScript runtime. Add bounded schema-validated value conversion for custom handlers, including structured results. Use existing VM CPU, stack and allocation limits and the runtime's capability checks. Do not load native binaries from the plugin or give handlers process, raw filesystem or network access through this contract.
- Use separate gates for enabling a plugin, allowing its AI contributions and approving a modifying invocation. A read-only call runs after opt-in in Ask, Plan or Build. Its handler receives the read-only host capability set. Marking an action read-only cannot grant access to mutation. The first release supports read-only plugin contributions and validates that a modifying declaration is unavailable. Any later modifying actions require Build mode, a preview of the specific effect and arguments, user approval per call and a host operation that enforces the approved capability.
- Revalidate the project, plugin revision, binding, entity scope, schema and grant immediately before invoking. Revoking access, updating a contribution's schema or permissions, uninstalling, and switching projects retire the affected handles and reject stale results. Permission settings list the contributions and describe the data shared with the selected AI provider.
- Keep a fixed, versioned Studio-owned tool family in the hosted catalog for discovery, description and bounded invocation. Separate the read-only envelope from any future modifying envelope. Cloud validates the supported operations and mode policy. Studio resolves plugin descriptors and validates their schemas and permissions locally. Unknown plugin schemas never become authoritative Cloud function definitions. Provide a compatibility fallback that omits the family on older Cloud versions. The current [desktop external MCP contract](ada-ai-external-mcp.md) keeps its existing Build approval behavior.
- Treat text from plugin metadata, tool results and external assets as untrusted data. Expose only documented fields to the model and bound the depth, number and size of values. Keep internal project file paths out of references. The asset library sends titles entered by the user, store labels and availability. It keeps its preview images and source files in Studio.

## Acceptance and documentation

- Install the External Asset Library and the example plugin in the same project on Windows and macOS. Discover asset search and both tools from Ada AI on a compatible hosted deployment. Run search followed by a details lookup and run the example tool through the production sandbox. Verify the correct plugin receives each call and that a declared modifying tool is unavailable in this release.
- Exercise undocumented action IDs, incompatible package versions, unknown schema fields, oversized results, wrong entity types, other-project and other-plugin references, duplicate IDs, disabled plugins, revoked consent, plugin update during a call, project switching and older Cloud contracts. Real host tests must verify that read-only handlers cannot cause writes even with a misleading manifest.
- Update [Studio Tools](../../Editor/Documentation/StudioTools.md) with the authoring contract and a verified example under `Editor/Documentation/Examples/StudioTools/`. Update [Cloud AI](../../Editor/Documentation/CloudAI.md) with opt-in, discovery and revocation, link it from [the Editor Guide](../../Editor/Documentation/EditorGuide.md), and include the relevant changes in the bundled offline guide. Build or validate the example and run the offline docs generator with its freshness check.
