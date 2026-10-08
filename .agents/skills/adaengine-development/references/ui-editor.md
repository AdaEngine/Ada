# AdaUI and AdaEditor Work

Read this reference before changing declarative UI behavior, view nodes, controls, text input, native representables, editor workflows, SourceKit/tooling, or the editor app wrapper.

## AdaUI Ownership

- Public declarative API belongs in `Sources/AdaUI/DSL` or the appropriate public UI surface.
- Persistent runtime state, layout, hit testing, focus, input routing, and rendering live in the view-node/runtime layers. A modifier declaration alone does not prove runtime behavior.
- Keep view identity and state stable across rebuilds. Avoid recreating heavy render/layout resources when only values change.
- Input and focus fixes must trace the full path: platform event -> AdaInput/platform bridge -> hit testing/focus -> view node -> public control callback/state.
- Native AppKit/UIKit integration should be narrow and conditionally compiled. Keep shared AdaUI semantics platform-neutral.
- Rendering changes should be validated with actual layout/viewport/scale conditions, not only isolated geometry helpers.

## AdaEditor Boundary

`Editor/` is a separate SwiftPM package. Run package commands from `Editor/` or use `--package-path Editor`. It depends on the root engine by local path, so editor tests may rebuild engine targets.

The editor also has `Editor/project.yml`, which generates a macOS `.app` wrapper around the SwiftPM executable. If target resources, app metadata, staging behavior, or generated-project inputs change:

1. Update the source manifest/configuration.
2. Run `xcodegen generate` from `Editor/` when XcodeGen is available.
3. Build the generated `AdaEditor-macOS` scheme when the app wrapper matters.
4. Confirm the staged `.app` contains an executable and resource bundle; launch or smoke-test it when safe and relevant.

Do not manually patch generated Xcode project content as the primary fix when `project.yml` owns it.

## Real-Path Validation

- Filesystem/project browser changes: use a temporary real directory or SwiftPM project with real files.
- Package manifest/tooling changes: exercise the real parser/tool process and resulting model.
- SourceKit-LSP changes: open a real SwiftPM target, establish build settings, send versioned document updates, and inspect the actual protocol response.
- Focus, shortcuts, context menus, text editing, and hit testing: exercise the real view-node/event path; add focused tests around the runtime behavior.
- Persistence and selection: verify state survives the lifecycle boundary the feature promises.

Source-string tests are useful guardrails for generated configuration, but they do not replace an executable or interaction test.

## UI Performance

Watch for recursive layout invalidation, per-frame tessellation, texture or glyph recreation, full-tree updates for local state, oversized hit-test regions, and display-link/frame-pacing errors. Profile a representative large interface before claiming the issue is globally resolved.
