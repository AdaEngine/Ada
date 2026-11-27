# External Asset Library implementation

Implement the approved [gallery](../Designs/external-asset-library.md) and [Studio plugin AI contract](../Designs/studio-plugin-ai-capabilities.md) for desktop. The independently packaged Store deliverable lives under `Plugins/ExternalAssetLibrary`.

1. Implement the versioned plugin package, validated ZIP installation, project-local discovery and access grants. Prove that invalid packages and disabled or replaced plugins cannot activate contributions.
2. Implement the shared project library and file lifecycle. Test listing identity, title search, source filters, model validation, cancellation, duplicate import recovery and managed deletion against temporary projects.
3. Add the AdaUI workbench tab, grid, thumbnail work and selected-model viewport. Exercise the real runtime with a self-contained GLB and review the rendered desktop panel in both languages and window widths.
4. Add the optional, read-only plugin family to Ada AI, with typed intent discovery, entity references and restricted custom tool handlers. Test the native dispatcher with both the gallery and a second plugin. Check deployment compatibility separately from local tool execution.
5. Update the Editor Guide, Studio Tools guide and Cloud AI guide. Validate the authoring example, generate and verify the offline snapshot, and run contribution validation and independent review before claiming completion. Validate the release ZIP and the live Store listing separately. Verify native macOS and Windows builds, the official Fab and Unity handoff where accounts are available, and a compatible hosted Ada AI turn.
