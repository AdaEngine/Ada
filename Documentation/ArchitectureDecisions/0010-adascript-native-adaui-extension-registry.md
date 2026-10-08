# ADR-0010: Export native AdaUI extensions through versioned descriptors

- Status: Accepted
- Date: 2026-09-05
- Implementation: Planned

AdaScript views are temporarily unavailable until this design is implemented;
see [ADR-0016](0016-temporarily-disable-adascript-adaui.md) for the active
product status and follow-up sequence.

## Context

[ADR-0006](0006-ada-script-adaui-integration.md) establishes that AdaScript UI
produces native AdaUI view graphs rather than a parallel immediate-mode UI. Its
first implementation slice lowers a fixed set of constructor names into a
private bridge model and renders that model as type-erased native AdaUI views.

That closed constructor table is sufficient for built-in primitives, but it
cannot represent an application-defined Swift `View` such as `HealthBar`, a
package-provided control, or a custom `ViewModifier`. Teaching the compiler
about every concrete Swift type would couple AdaScriptCompilerCore to
application modules and still fail for types compiled after the build plugin
runs.

Directly exposing a Swift `View`, `ViewNode`, `AnyView`, closure, or generic
initializer to the embedded VM is not a viable extension mechanism:

- Swift view types and generic constraints are not a stable scripting ABI;
- native view identity and `@State` must remain owned by AdaUI;
- the VM must not retain main-actor objects or borrowed native values;
- the AdaScript build plugin cannot execute the target's Swift code to discover
  runtime registrations;
- a portable project runs inside a precompiled host which may not contain the
  requested native implementation;
- AdaEditor completion and Preview need the same signatures and availability
  rules as the game runtime.

The initial bridge also stores supported modifiers in a property bag and
reapplies them in a fixed native order. AdaUI modifier order and repetition are
semantic, so a scalable extension ABI must preserve the source-ordered modifier
chain rather than add more fields to that bag.

## Decision

### Separate the signature catalog from native factories

AdaScript-facing native UI extensions have two representations:

1. A platform-neutral, versioned signature declares the module, exported
   symbol, stable descriptor identifier, arguments, optional content shape,
   result kind, platform availability, and ABI version.
2. A compiled native descriptor associates that signature with a main-actor
   Swift factory.

The signature is available to build tools, AdaEditor, the language server, and
runtime validation without loading or executing application code. The factory
exists only in a host binary that linked the Swift implementation.

Signature data belongs in a dependency-neutral compiler model. Native factories
and rendering adapters belong in the optional AdaScript/AdaUI integration layer
defined by ADR-0006. Neither representation is part of
`ScriptableObjectRegistry`; that registry owns ECS-attached behavior, coding,
and lifecycle rather than UI construction.

Native packages publish a generated or checked-in signature manifest alongside
their exported module. A Swift macro or generator may reduce declaration
boilerplate, but the manifest and native descriptor must be validated against
the same stable identifiers and ABI versions. Source scanning alone is not the
runtime contract.

### Resolve symbols through explicit UI modules

Custom symbols are imported from a named UI module instead of entering one
process-wide constructor namespace:

```ada
import { HealthBar } from "GameUI";

@view(id: "game.hud")
class GameHUD {
    @state var health = 0.75;

    func body() {
        HealthBar(
            value: health,
            color: "#45d483"
        );
    }
}
```

The public module and symbol names are source-facing API. The descriptor
identifier is the stable runtime identity and does not depend on the Swift type
name. Renaming a Swift type therefore does not break scripts when its descriptor
identity and signature remain compatible.

Built-in AdaUI symbols use the same semantic catalog. Existing implicit
built-in names may remain source-compatible during migration, but custom
extensions require an explicit import so dependencies, collisions, completion,
and host compatibility are deterministic.

Duplicate module symbols, duplicate descriptor identifiers, incompatible ABI
versions, and ambiguous imports are validation errors before a candidate module
is activated.

### Lower calls into a detached, ordered view description

The compiler resolves a constructor against its signature and lowers it into a
generic view-description node. It does not emit a direct Swift call:

```swift
.nativeView(
    descriptorID: "game.ui.health-bar",
    descriptorVersion: 1,
    arguments: [
        "value": .double(0.75),
        "color": .string("#45d483")
    ],
    children: [],
    identity: .structural(sourceLocation)
)
```

Arguments crossing the VM boundary are copied into detached, `Sendable` values.
The initial value ABI contains null, Boolean, integer, floating-point, string,
array, and string-keyed object values. Descriptors may interpret these values as
declared concepts such as colors, edge insets, asset references, or enum cases,
but factories never receive a raw VM value.

Every node stores modifiers as a source-ordered list. Repeated modifiers remain
repeated, and changing their order changes the resulting AdaUI graph. Native
modifier descriptors accept the current type-erased AdaUI view plus detached
arguments and return the modified view. A modifier is not stored as an unordered
style field.

Unknown modules or symbols are compiler diagnostics when a catalog is
available. If an interactive tool temporarily lacks a dependency manifest, it
may retain an unresolved external reference for editing, but build, Preview,
and runtime activation must resolve every reference before publishing a view.

### Register factories in a host-scoped catalog

Applications and AdaEditor construct an immutable `AdaScriptUICatalog` for each
runtime session from built-in descriptors and descriptors supplied by native
plugins. Registration is completed before AdaScript candidate validation. The
catalog is then frozen for that module generation so evaluation cannot observe
partially registered extensions.

A native registration is conceptually equivalent to:

```swift
AdaScriptNativeViewDescriptor(
    signature: HealthBar.adaScriptSignature,
    makeView: { arguments, context in
        AnyView(
            HealthBar(
                value: try arguments.float("value"),
                color: try arguments.color("color")
            )
        )
    }
)
```

The exact convenience macro and property-wrapper spelling is API design, not
part of this decision. Manual registration remains available so existing AdaUI
types can be exported without changing their declarations.

Factories are `@MainActor`. They receive only validated detached arguments,
rendered child content when declared, and a scoped native rendering context.
They must not capture a VM instance, retain a runtime coordinator guard, query
the ECS world, or call back into AdaScript while the view is being constructed.

Candidate compilation and view evaluation copy all required values while inside
the serialized AdaScript runtime boundary. Native factories run after leaving
that boundary. This preserves the lock ordering and immutable module-generation
rules from
[ADR-0007](0007-ada-script-runtime-and-hot-reload.md).

### Preserve native and script identity

An exported native view participates in ordinary AdaUI reconciliation. Its
script-side identity combines:

- the stable descriptor identifier and compatible version;
- the parent structural path;
- an explicit script identity when supplied, otherwise the source position;
- the identity of repeated content supplied by a list builder.

Reevaluation may call the factory again in the same way a Swift `body` creates
new view values, but a compatible identity preserves native AdaUI node state and
Swift property-wrapper storage. Changing the descriptor identity or explicit
node identity replaces the subtree.

Nested AdaScript `@view` declarations use the same description and identity
model but retain their own script instance and state storage. Flattening a child
view by calling its `body()` inside the parent is forbidden because it would
route child actions to the wrong instance and recreate child state on every
parent evaluation.

### Represent actions and bindings as scoped tokens

Native factories do not receive VM closures or references to script properties.
Callback and two-way inputs use typed tokens:

- an action token identifies the module generation, view instance, callback,
  and expected argument schema;
- a binding token identifies its owning script state or parent binding, value
  schema, and invalidation owner.

AdaUI closures retain native token adapters. When invoked, an adapter verifies
that the generation and view identity are still active, enters the serialized
runtime coordinator on the main actor, performs the callback or mutation, then
coalesces view invalidation after the call returns.

Tokens are valid only in the mounted view graph. They cannot be stored in
components, resources, scene coding payloads, global script variables, detached
tasks, or arbitrary native objects. A stale token produces a structured
diagnostic instead of entering a retired VM generation.

Display-only custom views can ship before action and binding inputs. A
descriptor that declares an unsupported input kind is rejected rather than
receiving a disconnected placeholder.

### Support custom content without exposing Swift generics

A signature declares whether a native view accepts no content, one content
subtree, or a list of children. AdaScript child expressions are rendered through
the same description pipeline and delivered to the factory as type-erased AdaUI
content. The exported factory performs any generic specialization inside Swift.

AdaScript does not name the native factory's generic parameters and cannot
instantiate an arbitrary Swift generic initializer. Unsupported overloads are
separate exported signatures or deliberately remain Swift-only.

### Make host compatibility explicit

A native UI extension is usable only when the executing host contains a
compatible factory:

- a hybrid desktop application may link its own `GameUI` module and register its
  descriptors;
- a custom AdaEditor build may include organization-specific UI modules;
- the precompiled portable AdaEditor host can use only native extensions shipped
  in that host;
- an iPadOS `.adaproject` cannot compile, download, or dynamically execute an
  arbitrary Swift view supplied beside its AdaScript sources.

Importing a signature manifest proves that source can be checked; it does not
prove that the current host contains the implementation. Build and Preview
therefore compare required descriptor identifiers and versions with the active
host catalog. A missing, incompatible, or platform-unavailable descriptor is a
blocking diagnostic that names the module, symbol, required version, and host.

AdaEditor Preview uses the same host catalog and native factories as runtime. It
must not silently replace unavailable native views with a different control.
An explicit descriptor-provided design-time representation is allowed only when
its semantics and limitations are identified in the descriptor.

Loading arbitrary native binaries into a precompiled portable host is outside
this decision and requires a separate security, signing, distribution, and
platform-lifecycle design.

### Version the extension ABI

Each descriptor has a positive ABI version. Compatible signature additions may
retain the version when all existing calls preserve meaning. Removing or
retyping an argument, changing content shape, changing action or binding
semantics, or changing the result kind requires a new version.

A module-generation candidate records the exact native descriptor identifiers
and versions it resolved. Changing a native descriptor or its manifest requires
a Swift rebuild. AdaScript-only hot reload may reuse the frozen catalog when its
requirements remain compatible.

Runtime errors use typed diagnostics for at least:

- missing module, symbol, descriptor, or factory;
- duplicate identifier or exported symbol;
- incompatible descriptor version;
- missing, unknown, or incorrectly typed argument;
- unsupported content or callback shape;
- platform-unavailable extension;
- native factory failure;
- stale action or binding token.

## Implementation plan

1. Introduce dependency-neutral UI signature and detached-value types plus an
   immutable host-scoped catalog.
2. Replace the unordered modifier style bag with an ordered modifier description
   and migrate built-in constructors to catalog-compatible descriptors.
3. Add display-only native view exports, signature manifests, factory
   registration, imports, validation, and real AdaUI rendering tests.
4. Load the same manifests and host catalog in AdaEditor completion, diagnostics,
   and Preview.
5. Add stable nested `@view` storage and action routing.
6. Add typed action, binding, and content inputs with stale-generation tests.
7. Add native modifier descriptors and migrate the remaining script-facing
   AdaUI surface.
8. Validate hybrid desktop, precompiled portable, hot-reload, and unavailable-
   host paths with actual mounted views and interactions.

## Consequences

- Applications can expose native AdaUI views and modifiers without modifying
  AdaScriptCompilerCore for each concrete Swift type.
- AdaScript receives a stable, documented UI ABI rather than Swift reflection or
  access to arbitrary initializers.
- Build tools and the language server can validate source without executing the
  application, while runtime still verifies that the host linked the factory.
- Modifier order, view identity, native state, nested script state, callbacks,
  bindings, Preview, and hot reload share one description model.
- Export authors must maintain signatures, versions, factories, and manifests.
- Portable projects cannot assume that project-local Swift extensions exist in a
  precompiled host.
- Type erasure remains at the native dynamic boundary, but native AdaUI retains
  ownership of nodes, layout, rendering, focus, input, and state.

## Rejected alternatives

### Add every native view to the compiler switch

Rejected because application and package views are open-ended, compiler releases
would be required for every extension, and the compiler cannot depend on
application targets.

### Reflect over Swift views at runtime

Rejected because Swift metadata does not provide a stable constructor ABI,
argument labels and generic constraints are not a scripting contract, and
runtime reflection is unavailable to build-time tooling.

### Bind native views directly into the embedded VM

Rejected because it exposes main-actor objects and native lifetimes to a
non-reentrant VM, permits retention across invalid scopes, and bypasses AdaUI
reconciliation.

### Treat an unknown capitalized call as an unchecked native view

Rejected for build and activation because misspellings and missing host modules
would become late runtime failures. Interactive editing may preserve an
unresolved reference, but no view is published until it resolves.

### Let a portable project compile or download Swift extensions

Rejected because the precompiled host owns executable code, iPadOS cannot run an
arbitrary project compiler pipeline, and unsigned native plugin loading requires
a separate security and distribution model.

### Flatten a nested script view by invoking its body

Rejected because child state, actions, bindings, environment subscriptions, and
hot-reload identity belong to the child instance rather than the parent.

### Keep modifiers in an unordered style property bag

Rejected because modifier ordering and repetition affect layout, drawing, hit
testing, accessibility, and environment behavior.
