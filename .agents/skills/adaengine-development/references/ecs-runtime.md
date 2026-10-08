# ECS and Runtime Work

Read this reference for changes involving components, entities, worlds, queries, systems, schedulers, plugins, scripting bridges, or per-frame performance.

## Data Model

- `World` owns entities, archetypes/chunks, resources, schedulers, ticks, and change state.
- Components are value-oriented data identified by `ComponentId`. Prefer `@Component`; use required components only for true invariants.
- Archetypes group equal component layouts; chunks hold contiguous component columns. Preserve stable lifetimes and change ticks when modifying storage.
- Entity identity is not component storage. Do not retain unsafe chunk/component pointers beyond their documented query/update lifetime.

## Queries and Access

- Prefer typed `Query` / `FilterQuery` targets for runtime hot paths.
- Reading a component by value declares read access. `Ref<T>` declares write access and provides the mutable path.
- Filters such as `With`, `Without`, change/addition filters, and relationships participate in matching and may also contribute access.
- `EntityQuery` is a dynamic entity-oriented query and can carry an explicit `SystemAccessSet`; use it when component types are resolved at runtime.
- Every custom `SystemParameter` must report all component/resource reads and writes. Missing access declarations can make concurrent scheduling incorrect; overly broad writes unnecessarily serialize systems.
- Query state is refreshed by the scheduler through `SystemQueries`. Do not manually cache query results across structural world changes unless the owning API guarantees validity.

## Systems and Scheduling

- Prefer `@PlainSystem` for a system type and `@System` for a function-style system.
- Declare ordering with `SystemDependency` only when data access alone does not express the required order.
- Use the appropriate scheduler name rather than embedding phase behavior inside one monolithic system.
- Structural changes should use the established `Commands`/world mutation path when iteration safety requires deferral.
- Keep the update function nonblocking. Use structured concurrency only where the data-access and lifetime model permits it.

## Plugins and Runtime Bridges

- Plugins configure worlds and schedulers through `AppWorlds`; setup and teardown are main-actor lifecycle operations.
- A scripting or editor bridge must expose capabilities, not the entire `World`. Derive readable/writable component access from declared queries and feed it into `SystemAccessSet`.
- A convenient per-entity proxy is acceptable for beginner/editor paths, but it is not the performance endpoint. Hot script execution should batch entities/components, reuse bridge objects where possible, cache resolved metadata, and ultimately use typed/chunk accessors for supported component schemas.
- Keep VM or foreign-runtime lifetime, reentrancy, and thread-safety explicit. Never assume a C runtime is `Sendable` because it is wrapped in a Swift class.

## Performance Review Checklist

- Does the change add an allocation, dictionary lookup, existential conversion, reflection pass, lock, or component copy per entity per frame?
- Does a mutable query correctly mark component writes and update change ticks?
- Is work performed once per system/query/archetype/chunk when it could avoid once-per-entity overhead?
- Are arrays copied through value semantics in the hot loop?
- Does the optimization preserve inactive entities, filters, structural changes, and scheduler conflicts?
- Is there a realistic stress scene or benchmark that exercises the affected scale?

Test storage/query changes with multiple archetypes, multiple chunks, inactive or removed entities where relevant, and both read-only and writable access.
