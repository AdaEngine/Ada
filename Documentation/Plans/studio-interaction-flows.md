# Studio interaction flow MVP

Approved design [Studio interaction flows](../Designs/studio-interaction-flows.md). The contributor approved the design on 2026-11-07 and prioritized the X gizmo, undo, cancellation, then hierarchy drag.

1. Create a separate macOS test executable using the production workbench and the existing AdaMCP plugin. Expose the versioned YAML runner through an additional MCP tool and a CLI entry to the same runner. Validate the entire flow before injecting input and keep the legacy AdaMCP automation schema compatible.
2. Exercise a 2D X-axis move against a disposable scene. Resolve the handle against presented geometry, drive the window input path and acknowledge viewport processing. Verify preview versus committed state, one undo and mid-gesture cancellation.
3. Use the same drag command with row IDs and verify hierarchy reparent, undo and invalid drop through the real document.
4. Publish the fixture and user guide, update navigation and offline documentation, and exercise the same saved fixture through both entry points. Record negative assertion, missing target and teardown evidence. Use the shared validation runner and independent review.

The harness is macOS-first. Windows and other platforms require their own runtime verification. Report the exact build, renderer, window sizes, languages and entry points exercised.
