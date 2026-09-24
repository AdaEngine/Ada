# ADR-0007: Use transactional Ada Script module generations

> Current AdaUI view availability is defined by [ADR-0016](0016-temporarily-disable-adascript-adaui.md); AdaScript-backed views are temporarily disabled.

- Status: Accepted
- Date: 2026-08-31
- Implementation: Planned

## Context

[ADR-0001](0001-ada-script-annotation-modules.md) defines one Ada Script module
plugin per Swift target. ECS systems, scriptable objects, and AdaUI views then
create live Gravity objects from that module. Those objects may be entered from
different engine subsystems and, in the case of AdaUI callbacks, outside an ECS
scheduler scope.

Gravity's C runtime is globally shared and non-reentrant. A lock around an
individual plugin call prevents simultaneous entry, but it does not by itself
define safe replacement of a module while systems, query rows, UI closures, or
scriptable objects still refer to its VM.

Development also needs useful hot reload. A failed edit must not destroy the
last working game state, while a successful edit must not mix declarations from
different compilations. Some changes can be loaded from source alone, but the
native backing types generated for script components and resources by
[ADR-0003](0003-ada-script-components-and-resources.md) require rebuilding the
Swift target.

Runtime failures need the same explicit boundary. A script trap must not leave
borrowed ECS values usable, publish half-built UI, or crash the engine process.
Diagnostics must retain source identity across embedded builds, Editor reloads,
and WebAssembly.

## Decision

### Module generations

Each installed Ada Script module is represented by an immutable generation. A
generation owns:

- its normalized module identifier and monotonically increasing generation
  number;
- the complete target-relative source map and import graph;
- one Gravity VM and all compiled declarations from that source map;
- semantic descriptors for systems, queries, components, resources,
  scriptable objects, views, capabilities, and exported fields;
- source maps and diagnostics;
- live Gravity instances and closures created by that generation.

A module has exactly one active generation. Engine-facing registrations refer
to a native generation handle rather than retaining a VM pointer directly.
Every script-owned handle also records the generation that created it. Using a
handle after its generation is retired produces a typed stale-generation
diagnostic.

Generations are not mutated in place. A source change creates a candidate
generation and either activates it completely or leaves the current generation
unchanged.

### Serialized runtime coordinator

All Gravity operations in the process go through one native runtime
coordinator, including compilation, instantiation, lifecycle callbacks, ECS
systems, AdaUI body evaluation, and event closures. The coordinator serializes
entry into Gravity even when the calls belong to different modules.

Engine code must not hold the Gravity runtime boundary while awaiting an async
operation, acquiring `WorldActor`, or dispatching synchronously to the main
actor. Native data needed by a callback is prepared before VM entry and native
side effects are committed after VM exit. This lock ordering prevents a script
callback from deadlocking the engine.

Ada Script callbacks are synchronous. Work that completes asynchronously uses
a capability which accepts detached request values and later publishes a
detached result, event, or resource update. Query rows, component views,
resource views, world contexts, bindings, and native objects cannot cross that
boundary.

The serialized coordinator is a correctness boundary, not permission to hide
undeclared ECS access. Scheduler access and capability validation remain as
defined by ADR-0002 and ADR-0004.

### Candidate compilation

Reload compiles the complete affected Ada Script module, not only the changed
file. A change to a shared import invalidates every dependent declaration in
that module. The candidate is validated before activation:

1. resolve and compile the complete source map;
2. run Ada Script annotation and semantic validation;
3. resolve native imports and bridge descriptors;
4. construct system access sets and query plans;
5. instantiate declarations and validate required lifecycle methods;
6. compare generated-data and persistent-state schemas with the active
   generation;
7. prepare replacement scheduler, scriptable-object, and AdaUI registrations.

Candidate compilation may run off the main actor, but it still enters
Gravity only through the serialized coordinator. It cannot observe or mutate
the active generation.

Warnings do not prevent activation. Any compilation, import, annotation,
capability, schema, or setup error rejects the whole candidate.

### Reload classes

The runtime classifies a candidate before activation.

#### Source-compatible reload

A reload is source-compatible when its native ABI and persistent schemas are
unchanged. It may change function bodies, system declarations, query access,
view descriptions, and other metadata that the runtime can replace by
rebuilding registrations.

Stable declaration identity comes from explicit identifiers such as
`@system(id:)`, `@scriptable(id:)`, and `@view(id:)`. A declaration without an
explicit stable identifier is matched by normalized module path and qualified
declaration name. Renaming such a declaration is removal plus insertion, not a
state-preserving reload.

#### Build-required change

Adding, removing, or changing the stored schema of an Ada Script `@component`
or `@resource` changes generated native Swift backing types. It is not loaded
into the running process. The Editor reports that the Swift target must be
rebuilt and keeps the current generation active.

Changing a native bridge ABI, generated registration surface, or unavailable
virtual import has the same result. The build plugin remains the source of truth
for the embedded production module.

#### Incompatible persistent-state change

A scriptable-object exported schema change must provide the version and
migration behavior required by ADR-0005. Without a valid migration, reload is
rejected while live or scene-backed instances of that type exist.

AdaUI state compatibility follows ADR-0006. Incompatible local view state may
reset with a development diagnostic because it is transient and not scene
coded; it does not make the whole module candidate invalid.

### Safe-point activation

Activation occurs only at an engine safe point where:

- no callback from the active generation is executing;
- no ECS query row, component view, resource view, or world context is live;
- deferred world commands from the completed scheduler scope have been either
  committed or discarded;
- AdaUI is not evaluating or reconciling a script view body.

The runtime pauses new entries for the module, installs all replacement
registrations as one transaction, rebinds persistent owners, and then publishes
the candidate as active. Scheduler graph and access-set changes become visible
together on the next applicable schedule. AdaUI closure replacement and view
reconciliation are dispatched on the main actor as part of the same activation
barrier.

If activation fails, any partially prepared native registrations are discarded
and the previous generation remains active. A retired generation is destroyed
only after its final native generation handle is released. It cannot receive
new callbacks while draining.

### State across reload

Runtime state is preserved only through an explicit owner:

- components and resources remain in the ECS world when their native schemas
  are unchanged;
- scriptable objects preserve only the exported, versioned payload described
  by ADR-0005 and recreate their Gravity instances;
- AdaUI preserves compatible native `@state` storage and rebinds event closures
  as described by ADR-0006;
- detached engine-owned asset, event, and command values remain valid according
  to their capability contracts.

System instances and ordinary Gravity globals are recreated. Their arbitrary
heap state is not copied into the new VM. Durable gameplay state belongs in a
component, resource, or explicitly coded scriptable object rather than a hidden
module global.

Lifecycle replacement is deterministic. Removed instances receive `destroy`
under the old generation when applicable. New or recreated instances attach and
run `ready` under the candidate only after activation succeeds. A failed
candidate does not run gameplay lifecycle methods.

### Callback failure isolation

Every engine-to-script call has a native invocation scope. The scope owns all
borrowed bridge values and the callback-local deferred command buffer. On
normal return, bridge values expire and commands are submitted. On a Gravity
error, timeout, or bridge violation:

- all borrowed values are invalidated;
- callback-local deferred commands are discarded;
- no candidate UI description is published;
- a structured diagnostic is emitted;
- the failing system, scriptable-object instance, view evaluation, or event
  closure is quarantined until a successful reload or explicit development
  retry.

Component and resource writes performed before a trap are not rolled back.
Script authors must therefore validate before mutating when a callback needs
all-or-nothing behavior. Adding general ECS transactions is outside this
decision.

The runtime enforces a configurable instruction or execution budget per entry
when the Gravity backend can provide a reliable interruption hook. Until then,
budget enforcement is reported as unsupported rather than implemented with a
thread-blocking watchdog that cannot safely stop the VM.

### Diagnostics

Diagnostics use a structured native representation containing:

- module identifier and generation;
- target-relative file path and source range when known;
- phase: import, compile, semantic, setup, activation, or runtime;
- severity and stable diagnostic code;
- declaration identifier and callback kind when applicable;
- a message and related source locations;
- whether the active generation was retained, the declaration was quarantined,
  or a rebuild is required.

Repeated runtime diagnostics are rate limited by code, declaration, and source
location. The latest occurrence count remains observable.

The Editor and LSP consume this representation directly. Console formatting is
a presentation layer, not the diagnostic API. Embedded and WebAssembly builds
retain target-relative source paths so errors do not depend on host filesystem
layout.

### Production policy

Dynamic source reload is a development capability and is disabled in release
builds unless the application explicitly installs a trusted source provider.
Production modules normally come from the source map embedded by the Swift
build plugin.

A source provider supplies a complete module snapshot and identity; it does not
grant arbitrary filesystem access to Gravity. Code signing, download trust, and
remote-content policy are application responsibilities and require a separate
security decision before remote scripts are enabled.

## Consequences

- A game never observes a mixture of declarations from two compilations of one
  Ada Script module.
- Failed edits leave the last valid generation and its native presentation
  active while surfacing actionable diagnostics.
- Hidden Gravity globals are deliberately not a persistence mechanism.
- All VM entry remains serialized while native ECS work can still be scheduled
  according to declared access outside the VM boundary.
- Component and resource schema edits require a target rebuild, avoiding two
  incompatible native layouts in one process.
- Runtime and Editor implementations need generation handles, a transaction for
  native registrations, safe-point coordination, quarantine state, structured
  diagnostics, and stale-handle tests.
- Validation must cover failed compilation, failed activation, import
  invalidation, scheduler graph replacement, state preservation, schema
  rejection, callback traps, stale handles, UI rebinding, and concurrent reload
  requests against real module source maps.

## Rejected alternatives

### Mutate the active VM in place

Rejected because old closures, instances, query plans, and native registrations
could observe a partially updated module and cannot be rolled back reliably.

### Replace each changed file independently

Rejected because imports and cross-file symbols make the Swift target's Ada
Script sources one semantic module.

### Preserve the complete Gravity heap

Rejected because arbitrary VM objects contain closures, bridge handles, and
generation-specific state with no stable schema. Explicit engine-owned state is
safer and deterministic.

### Activate valid declarations from a partially invalid candidate

Rejected because systems, data schemas, scriptable objects, and views may refer
to each other. Partial activation would make the running module differ from the
module that was validated.

### Reload generated component layouts without rebuilding Swift

Rejected because AdaECS stores the generated native types in archetypes and
compiled Swift code depends on their concrete metadata and layout.

### Let every module lock its own Gravity VM

Rejected because the underlying Gravity runtime is globally shared and
non-reentrant; per-module locks would still allow unsafe concurrent entry.
