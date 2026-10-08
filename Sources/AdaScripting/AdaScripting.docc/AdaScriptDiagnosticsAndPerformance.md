# Ada Script Diagnostics and Performance

Understand annotation, setup, and runtime failures and keep ECS work on the
native chunk path.

## Compilation diagnostics

``AdaScriptPlugin`` compiles the source and reads declaration metadata
without executing a `main()` manifest. Initialization throws
``AdaScriptError/compilation(_:)`` for syntax or semantic errors and
``AdaScriptError/invalidManifest(_:)`` for invalid AdaEngine annotations.

Examples include `@system` on a non-class declaration, duplicate system
identifiers, `@query` outside a system class, a query with no fetched
components, and a system class that cannot be initialized.

## Setup diagnostics

Native component identifiers are resolved during plugin setup so earlier
plugins can register game components. Unknown or ambiguous component names skip
the affected system and append a diagnostic.

## Runtime diagnostics

Runtime diagnostics include unknown component aliases, unknown fields,
unsupported values, invalid numeric conversions, and query capabilities used
outside their callback lifetime.

Inspect ``AdaScriptPlugin/diagnostics`` after setup and during development.
System `update(context)` callbacks are command-style; their return values are
ignored. Tests should assert observable ECS state and diagnostics.

## Performance model

Ada Script query execution traverses native archetypes and chunks. Component
columns are bound once per chunk, and field access advances a typed pointer by
row stride. A successful write mutates the component in place and updates its
change tick.

The hot path avoids arrays of matched entity identifiers, one Swift bridge
object per entity, repeated entity-location lookups, existential component
copies, and whole-component reinsertion.

The current embedded C runtime is globally shared and non-reentrant, so runtime entry remains
serialized. Scalability comes from native filtering, column iteration, cached
metadata, and narrow bridge calls rather than multiple concurrent VMs.

Benchmark scripting changes with multiple archetypes and chunks and compare
them with a typed Swift query. Validate semantics before drawing performance
conclusions.
