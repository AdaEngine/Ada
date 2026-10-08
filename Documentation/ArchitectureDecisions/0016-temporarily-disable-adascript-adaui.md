# ADR-0016: Temporarily disable AdaUI views in AdaScript

- Status: Accepted
- Date: 2026-09-25
- Implementation: Partial (disablement shipped; redesign planned)
- Supersedes: the implementation direction of [ADR-0006](0006-ada-script-adaui-integration.md)

## Context

The current AdaScript-to-AdaUI path relies on a source-rewriting lowerer with a
closed list of view constructors, incomplete modifier validation, generated
action methods, and separate paths for compilation, runtime mounting, and
Editor Preview. This implementation is not a maintainable or releasable basis
for AdaUI in AdaScript. [ADR-0010](0010-adascript-native-adaui-extension-registry.md)
already records the intended descriptor catalog and detached view description,
but that design has not been implemented.

## Decision

AdaUI-backed views are unavailable from AdaScript until the compiler and runtime
are rebuilt around a shared typed representation. AdaUI written in Swift and
native AdaUI scenes remain available.

Every AdaScript entry point fails closed with a clear diagnostic: `@view`
declarations, the view builder lowerer, source-backed `UIComponent` scripts,
the AdaScript view registry, portable-project entry views, and AdaEditor
AdaScript Preview. Existing public entry points may remain temporarily for
source compatibility, but must not evaluate scripts or construct an AdaUI
tree. AdaEditor must not offer an AdaScript UI-view file template or imply that
such views can be previewed.

User-facing documentation and starter projects must not advertise or generate
AdaScript `@view`, `@previewable`, AdaScript view state, or AdaScript-powered
AdaUI Preview. Historical ADRs may retain their original decision text, but
must identify this ADR as the current implementation status. Project manifest
fields retained for compatibility must not activate the disabled behavior.

## Follow-up implementation plan

1. Specify and test the supported AdaScript UI grammar and diagnostic rules.
2. Parse view expressions into source-located compiler AST nodes using the
   language parser rather than a second source-rewriting parser.
3. Resolve built-in and custom UI symbols through versioned, platform-neutral
   signatures. Validate names, argument labels and types, content shape, and
   availability before runtime.
4. Lower calls to a detached view-description tree that preserves structural
   identity and the source order and repetition of modifiers.
5. Resolve descriptors through an immutable, host-scoped catalog of native
   `@MainActor` factories. Pass only validated detached values and scoped
   action or binding tokens across the runtime boundary.
6. Add state, nested script views, collections, and control flow as explicit
   language/runtime slices. Preserve independent identity, state, and callback
   routing for nested views.
7. Make compiler diagnostics, AdaEditor completion, Preview, and runtime use
   the same signatures and resolution rules.
8. Re-enable entry points only after end-to-end compiler, runtime, and Editor
   Preview paths satisfy the shared contract; remove the legacy source
   lowerer rather than extending its constructor and modifier tables.

Until a new ADR records that acceptance and the implementation is complete,
AdaScript UI views remain disabled.
