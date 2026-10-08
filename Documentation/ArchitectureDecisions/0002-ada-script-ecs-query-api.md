# ADR-0002: Use iterator-based Ada Script ECS queries

- Status: Accepted
- Date: 2026-08-31
- Implementation: Partial (foundation shipped)

## Implementation status

Last verified: 2026-08-31.

Shipped:

- [x] Positional fetched components and `with` / `without` filters use the
  canonical `@query(...)` declaration.
- [x] Gravity iterates queries through `for (var entity in query)`.
- [x] AdaECS binds component columns once per chunk and advances rows without
  materializing an array of entity identifiers.
- [x] Component fields are read and written through generated pointer thunks;
  mutable stores update the component change tick.
- [x] Direct row access such as `entity.transform.position` is supported.
- [x] Pointer lifetimes remain inside the system update and raw pointers are not
  exposed to Gravity.

Remaining before this ADR is implemented:

- [ ] Implement `optional`, `changed`, and `added` query clauses.
- [ ] Implement explicit component aliases and duplicate-short-name
  diagnostics.
- [ ] Infer read and write access from the compiled script. The current runtime
  conservatively declares every fetched component writable.
- [ ] Implement and validate the explicit `@access` escape hatch for dynamic
  access.
- [x] Remove the temporary `lastResult` testing hook. A system `update(context)`
  callback is command-style and its return value is not part of the ECS API.
- [ ] Add the realistic typed-Swift versus Gravity iterator benchmark required
  by this decision.

## Context

The current Gravity bridge uses a dynamic `EntityQuery`, materializes arrays of
entity identifiers, and performs component access through per-entity world
lookups and reflected component copies. The batch API reduces bridge-object
allocation but still addresses data through entity identifiers rather than
binding native component columns.

AdaECS already stores components in contiguous chunk columns. The scripting
bridge should preserve that data-oriented layout while keeping raw pointer
lifetimes inside AdaECS.

Query declarations must also describe enough access for the scheduler to avoid
data races. Repeating manual read and write component lists is error-prone when
the compiler can see ordinary property reads and assignments.

## Decision

### Canonical query syntax

A query is declared with one `@query` annotation:

```ada
@query(
    Health,
    Movement,
    with: Damageable,
    without: Player
)
var entities;
```

The canonical model is:

- positional components are required and fetched;
- `optional` components are fetched but may be absent;
- `with` components are required filters and are not fetched;
- `without` components are exclusion filters and are not fetched;
- `changed` filters by component change tick;
- `added` filters by component addition tick.

One value and a list are both accepted and normalized to lists:

```ada
with: Damageable
with: [Damageable, Visible]
```

A complete declaration may therefore be written as:

```ada
@query(
    Health,
    Movement,
    optional: Target,
    with: [Damageable, Visible],
    without: [Player, Frozen],
    changed: Health
)
var entities;
```

Standalone `@with`, `@without`, `@changed`, and `@added` annotations are not
part of the language. Query filters have one declaration site and no annotation
ordering semantics.

The SQL-like form below is not supported:

```ada
@query(Health, Movement with Damageable without Player)
```

It is ambiguous once aliases, multiple filters, optional components, or boolean
composition are introduced.

### Aliases

The default row property is the lower-camel-case short component name:

```ada
@query(Health, Movement)
var entities;

// entity.health
// entity.movement
```

An explicit alias uses `as`:

```ada
@query(
    Game.Health as health,
    Physics.Movement as movement
)
var entities;
```

### Iterator and row semantics

Queries are iterators:

```ada
for (var entity in entities) {
    var position = entity.movement.position;
    entity.health.current -= 1.0;
}
```

The compiler lowers row component and field access to numeric query slots. It
does not perform component-name or field-name lookup in the per-row hot path.

A query plan resolves symbols once during plugin setup into:

- `ComponentId` values;
- matching archetypes;
- component column bindings;
- field accessors;
- scheduler access;
- change-tick storage.

The native cursor traverses archetype, chunk, and row. Component addresses are
derived from a bound column base address and row stride. Raw pointers never
cross into Gravity and cannot outlive an update call.

Query rows are borrowed and non-escaping. Retaining a row, component view, or
field reference outside its iteration scope is a compilation error where
statically detectable and a runtime diagnostic otherwise.

Structural mutations are not performed while an iterator is active. They use
the deferred command model in [ADR-0004](0004-ada-script-world-capabilities.md).

### Access inference

The Ada Script semantic pass infers component access from row use:

```ada
var current = entity.health.current; // read Health
entity.health.current = current - 1; // write Health
entity.health.current -= 1;          // read and write Health
```

Component writes imply both read and write scheduler access. Filter-only
components do not become row properties. Change and addition filters declare
the runtime metadata access needed to evaluate their ticks.

If a row escapes into code that cannot be analyzed, or a component is accessed
dynamically, the system must provide an explicit escape hatch:

```ada
@access(
    read: [Velocity],
    write: [Transform]
)
```

Compilation fails when access cannot be inferred safely and is not declared.
The runtime never silently widens a system to unrestricted world access.

### Complex predicates

Boolean `where` expressions are deliberately deferred. They may be added later
without changing the canonical fetched and filter clauses:

```ada
@query(
    Health,
    where: has(Burning) || has(Poisoned)
)
```

They will be introduced only when a concrete OR-filter use case justifies the
additional parser, semantic, and LSP complexity.

## Consequences

- Query code has one concise declaration and no manual read/write lists.
- Scheduler conflicts remain derived from concrete component and resource use.
- Per-frame allocations must not grow with the number of matching entities.
- The hot path avoids entity-ID materialization, world location lookup,
  existential component copies, and whole-component reinsertion.
- A successful mutable field store updates its component change tick.
- Query validation must cover empty results, multiple archetypes, multiple
  chunks, inactive entities, optional components, filters, and invalidated rows.
- Benchmarks compare typed Swift queries, the old bridge during development,
  and the new iterator at realistic entity counts. The old bridge is removed
  before the new Ada Script API is considered complete.

## Rejected alternatives

### Separate `@with` and `@without` annotations

Rejected because annotation order would be semantically irrelevant but visually
unstable, and filters would have multiple declaration sites.

### Keep entity and batch execution modes

Rejected because there is one intended scalable query model and no compatibility
requirement for the old modes.

### Expose raw component pointers to Gravity

Rejected because pointers could escape iteration, survive structural changes,
and bypass scheduler and change-detection invariants.

### Infer access at runtime

Rejected because the scheduler requires an access set before system execution.
