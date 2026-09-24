# ADR-0015: Add structured asynchronous tasks to AdaScript

> Any async behavior that depended on AdaScript `@view` callbacks is unavailable while [ADR-0016](0016-temporarily-disable-adascript-adaui.md) is in force.

- Status: Accepted
- Date: 2026-09-24
- Implementation: Partial (worktree foundation; not released)

## Implementation status

Last verified: 2026-09-24 in the `codex/adascript-async` worktree. This
implementation has not been released.

Implemented and covered by focused tests in this worktree:

- [x] Explicit `async func`, `await`, `Tasks.start`, one-shot promises, and
  nested coroutine results.
- [x] Serialized per-world task pumping, fair bounded dispatch, task/parent/
  owner/trace identities, and view/world/module cancellation.
- [x] Game-clock and monotonic real-time timers.
- [x] Async asset load/save results and a real slow-load test while ECS frames
  continue.
- [x] Atomic background text save and a 256 KiB-per-chunk streamed save with
  an atomic commit and cancellation cleanup.
- [x] Runtime leases for borrowed query rows and reflected resource views;
  `@nonsendable` type metadata, typed-parameter checks, and runtime capture
  validation across aliases, lists, returns, and one-shot results.
- [x] AdaUI action continuation, view disposal, and view-generation retirement;
  Editor keyword, declaration, and completion support.
- [x] Native `async`/`await` tokens, AST lowering, and direct-call effect checks
  in `gravity-lang` revision `24695757a0ba5638b3633004a2166b7878c116de`.
  The AdaEngine runtime still owns task scheduling and suspension policy.

Remaining before this ADR is fully implemented:

- [ ] Isolate a single coroutine's VM trap without aborting the shared Gravity
  VM. The current dependency has no public recovery API. The runtime instead
  quarantines that module and requires reload, with one task/owner/trace
  diagnostic.
- [ ] Full static effect and borrowed-value analysis through aliases, map
  entries, and imported method declarations; typed result descriptors and
  source maps for generated async continuations.
- [ ] Engine-owned, incremental snapshots of arbitrary ECS data, beyond the
  available bounded streaming writer.
- [ ] A game time-scale resource, complete Editor diagnostics, and platform
  runtime proof on browser/WASI, Linux, Windows, and Apple mobile targets.

The synchronous `AdaScriptAssetsBridge` operations remain available for
compatibility. New awaitables use the native asynchronous asset operations.

## Context

AdaScript authors need to load shop content while gameplay continues, save
large data without holding a frame, wait for timers, and write sequential
event-driven flows such as waiting for a user's confirmation. Per-frame state
machines can express some of these flows, but do not provide a general answer
for asynchronous I/O or nested waits.

[ADR-0007](0007-ada-script-runtime-and-hot-reload.md) serializes VM entry and
keeps engine-to-script callbacks synchronous. Its borrowed query rows,
component and resource views, world context, and command capabilities expire
when a callback returns. This remains true when a script starts an asynchronous
task. A Swift `Task` may change OS threads; a VM fiber can suspend a stack but
cannot perform I/O, schedule itself, or make borrowed ECS values safe to retain.

## Decision

### Source language and task entry points

Declare a suspending function explicitly with `async func`. It may call a
normal function directly and another async function with `await`. The compiler
rejects `await` in a normal function, an async call used without `await` or an
explicit start, and `async` on an engine lifecycle callback whose current
contract is synchronous. The declaration's async effect is part of its
signature for calls, imports, overrides, editor diagnostics, and generated
interfaces. Async methods use the same modifier before `func`.

The following is proposed AdaScript, not currently executable:

```ada
async func request_confirmation() {
    System.print("Will ask the user");
    var confirmed = await wait_confirmation();

    if (confirmed) {
        System.print("User confirmed");
    } else {
        System.print("User cancelled");
    }
}
```

From an async function, `await request_confirmation()` waits for that child.
From a synchronous UI action or system callback,
`Tasks.start(request_confirmation())` explicitly starts it and returns a task
handle. `Tasks.start(asyncCall)` is a compiler-recognized spawn expression: it
does not evaluate `asyncCall` as an ordinary synchronous call. It schedules the
new function for the next safe script dispatch point, avoiding reentrant VM
entry during the originating callback. A bare async call in synchronous code
is an error; tasks are never silently discarded. The handle supports status
inspection and cancellation. An unawaited task started with `Tasks.start` is
still owned by the current lifecycle scope and reports an unhandled failure.
`return` completes an async function with its value; an awaited caller receives
that value. Starting a task never blocks until its first suspension.

`@system.update(context)`, scriptable-object lifecycle methods, AdaUI body
evaluation, and existing UI event callbacks remain synchronous. They may
start tasks, passing detached input values. They cannot pass a live callback
context or its borrowed capabilities into an async function. The eventual
result is applied through a fresh permitted callback, event, or deferred
command; a resumed coroutine does not acquire implicit world access. Starting
the same task on every frame is an authoring error to avoid, not behavior the
runtime silently deduplicates.

### Coroutine context and execution

The unit of identity is a logical task, not an OS thread. Each task records a
stable task ID, parent task ID, owner scope, world and module identity, module
generation, cancellation state, selected clock and deadline when applicable,
and trace ID. The scheduler tracks `created`, `ready`, `running`, `suspended`,
`completed`, `failed`, and `cancelled` states. Completion is accepted at most
once. Parent-child links propagate cancellation and make child failures
observable. A task cannot resume after a terminal state.

AdaScript runs only while entered through the serialized VM coordinator. The
runtime may implement a suspended continuation with Gravity fibers or a
compiler-generated state machine; neither mechanism is part of the public
AdaScript API. The runtime must retain VM closures and stack values for the
task's generation while it is suspended, and release them on completion or
cancellation. No task is pinned to a particular OS thread. A Swift worker
receives immutable or otherwise safely owned, `Sendable` native request data,
never a VM object, borrowed ECS bridge, or raw pointer into script memory.

At `await`, the script continuation is suspended and the active invocation
scope ends. The operation completes outside the VM and enqueues a detached
value or error. The script scheduler checks task ownership, cancellation,
generation, and completion state before reentering the VM at a safe dispatch
point. The completion callback itself must never enter the VM. UI work resumes
under its UI actor; ECS changes are published through the appropriate world
scheduler and access declarations. Native work must not hold the VM boundary
while awaiting I/O, `WorldActor`, or main-actor dispatch. This extends, rather
than weakens, the lock ordering in ADR-0007.

The scheduler processes ready continuations in stable enqueue order within a
world and generation. A completion is never delivered inline from a native
callback. Gameplay need not pause while a task waits, and a task may resume on
a later dispatch cycle rather than the exact frame in which I/O completed.
No cross-world ordering is promised. Per-dispatch resume counts and task
counts are bounded to protect frame time and memory; exceeding a bound yields
a diagnostic or typed resource-limit failure instead of unbounded queue growth.

Task-local native tracing metadata may be restored at each resume, but task
identity and authorization travel explicitly in the native task record. A
Swift thread-local or `TaskLocal` value alone is not the bridge contract.

### Ownership, cancellation, and hot reload

Every root task has a lifecycle owner: a view instance, scriptable-object
instance, system/world, or another explicit runtime scope. `Tasks.start`
inherits that owner unless the API explicitly accepts a longer-lived owner.
No unowned process-global task is created implicitly. Child tasks inherit
their parent's owner and cancellation. Closing a view, detaching an object,
stopping its world, or replacing its module generation cancels its tasks.

Cancellation prevents any later script continuation or ECS publication. The
runtime requests cancellation of native work when supported, but cancellation
is not a rollback guarantee: a file write or network request may already have
committed. A late completion from a cancelled task or retired generation is
discarded and recorded at most once. New code never resumes an old generation's
fiber. A source-compatible hot reload may preserve explicit persistent game
state as ADR-0007 allows, but not suspended stacks. A save that must outlive a
view should be owned by a world-level service, with completion exposed to the
new generation as an engine-owned result rather than by reviving an old fiber.

One-shot waits, including UI confirmation, register the waiter and publish the
prompt atomically so an immediate response cannot be lost. Only the first
response completes the wait. A user choosing Cancel returns `false`; owner
disposal cancels the task and does not pretend that the user chose Cancel.

### Built-in awaitable capabilities

The first implementation must exercise the same task mechanism with these
capabilities, rather than providing unrelated callback-only shortcuts:

1. **Asset loading:** `await Assets.loadAsync(...)` performs eligible disk,
   network, and CPU decoding away from the script dispatch. Renderer or UI
   finalization still runs on its required actor. Existing asset type, cache,
   and virtual-path rules apply. Platforms without an operation return a
   typed unsupported-operation failure.
2. **Large saves:** `await Saves.writeAsync(...)` takes an immutable string
   before background encoding and I/O. `Saves.begin(path)` with awaited
   `appendAsync(chunk)` and `finishAsync()` provides a bounded incremental
   path for large data; each chunk is at most 256 KiB. General ECS snapshot
   production is still planned. On supported filesystems, commit by atomic
   replacement so failure does not expose a partial save. The result reports
   whether commit occurred, including when cancellation races with commit.
3. **Timers:** `await Time.sleep(seconds)` uses game time, obeying pause and
   time scale. A separately named real-time sleep uses a monotonic clock and
   advances while game time is paused. Its continuation still waits for the
   next permitted script dispatch; a paused world need not run script code
   until resumed. Durations must be finite and nonnegative. Neither timer
   blocks a thread or resumes a fiber without a script dispatch point.
4. **Event waits and coroutines:** a one-shot awaitable may be completed by a
   UI event or engine event. `wait_confirmation()` returns a Boolean choice;
   a coroutine can compose several awaits while preserving local variables.
   Event subscriptions are released on completion or cancellation.

The names above describe the intended public surface. Their signatures and
type descriptors must be generated from or reconciled with the owning native
capabilities; the bridge must not invent separate stringly asset or event
registries. AdaScript callers see detached values or stable engine-owned
handles, not native mutable objects.

### Suspension policy

`@nonsendable` is a type-level suspension policy. It marks a script class,
struct, or enum whose instances cannot enter an async frame or cross an
`await`. Native callback-scoped bridge types declare the equivalent policy at
their binding site. This policy describes script lifetime; it is independent
of Swift's `Sendable` conformance used to synchronize the bridge internally.

The compiler rejects async parameters explicitly typed as `@nonsendable`,
async methods whose receiver has that policy, and async effects on callbacks
registered by `@system`, `@view`, `@scriptable`, or `@rpc` descriptors. It does not infer borrowing
from variable names such as `context` or ban method names in an ordinary
class. The runtime validates actual task arguments, nested lists, returned
values, and promise completions, catching untyped aliases. A borrowed ECS
lease also expires at callback exit as a final runtime guard. Map captures
currently fail closed until entries can be traversed and checked.

### Error contract and authoring diagnostics

In the first slice, fallible asynchronous capabilities return a tagged result
with success/value/error cases, described as `Result<Value, AsyncError>` in
signatures. Its descriptor carries the concrete value and error types even if
AdaScript's initial source syntax cannot spell generic types. `await` unwraps
scheduling, not the operation's failure. Success and failure must be inspected
explicitly; the error carries a stable code, message, and safe contextual data.
Adding AdaScript `try`/`catch` is a separate language decision and must not be
assumed from Swift syntax or Gravity's `Fiber.try`. A non-fallible wait such as
the user's confirmation can return its ordinary value. Cancellation of the
task is distinct from such a value and normally stops its continuation.

The compiler and runtime enforce separate categories:

| Category | Examples | Required behavior |
| --- | --- | --- |
| Static effect error | `await` in `func`, async call without `await` or `Tasks.start`, unsupported async lifecycle signature | Reject with source range and fix guidance. |
| Borrow escape | Borrowed ECS/UI value captured across `await` | Reject statically; invalidate and diagnose erased aliases at runtime. |
| Operation failure | I/O, HTTP, decoding, insufficient space, unsupported platform, invalid path | Deliver typed result; do not crash the VM. |
| Lifetime failure | Parent or owner cancelled, world stopped, stale module generation, expired event source | Cancel or discard; never resume an invalid continuation. |
| Scheduler violation | Double completion, resume after terminal state, reentrant VM entry, quota exceeded | Reject completion and emit a structured runtime diagnostic. |
| Script failure | VM trap, invalid bridge use, execution-budget failure | Fail the task, cancel its children, and isolate the failing invocation under ADR-0007. |

Async task diagnostics include task and parent IDs, owner, module generation,
trace ID, originating source range, current await site, operation kind,
terminal state, and underlying native error code when safe to expose. They
must not log credentials or private payloads. An unhandled failure from a
root task must be visible in runtime and Editor diagnostics; repeated failures
are rate limited without hiding their count. An awaited child failure is
reported once with its causal chain. Release builds retain safety checks for
generation, cancellation, and borrowed leases.

### Platform behavior

The same AdaScript semantics apply on macOS, iOS/iPadOS, Linux, Windows, and
browser/WASI targets. Native operations may have platform-specific backends or
return `unsupportedOperation`; no platform may implement `await` by blocking
its UI, render, or script thread. Browser completion enters through the host
event loop. File save support follows each platform's filesystem capability;
WASM must not silently route to an unavailable synchronous save path.

## Implementation plan

1. Add async effects and `await`/`Tasks.start` parsing, lowering, source maps,
   and static borrowed-value validation to the AdaScript compiler and Editor
   language services.
2. Introduce task records, owner scopes, continuation scheduling, cancellation,
   quotas, and structured diagnostics in the AdaScript runtime. Prove the VM
   continuation backend can resume safely across dispatches before exposing
   the language feature.
3. Add detached native awaitable bridges for timers and one-shot events, then
   asset loading and large saves. Reuse native AdaAssets operations where
   applicable; keep the existing synchronous APIs source-compatible until a
   deliberate migration.
4. Integrate task cancellation with view/object/world teardown and module hot
   reload. Expose task state and failures in Editor diagnostics.
5. Validate native and browser paths, including real frame progress during
   I/O, bounded snapshot work, pause/time-scale timers, cancellation races,
   and late completions after reload.

## Validation requirements

- Compiler tests reject every illegal async effect and borrowed-value escape,
  including values passed through helpers and containers where analyzable.
- Runtime tests prove nested await, local-variable preservation, parent-child
  cancellation, exactly-once completion, stable per-world resume order, and
  no VM entry from a native completion callback.
- An integration test loads shop data while gameplay frames continue and
  publishes the result through a fresh script callback.
- A large-save test proves snapshot consistency, nonblocking frame progress,
  atomic committed output, and truthful cancellation/commit reporting.
- Timer tests cover game pause, time scale, monotonic real time, invalid
  durations, and cancellation.
- UI tests cover confirmation versus owner cancellation, immediate response,
  duplicate response, and a closed view.
- Hot-reload and teardown tests prove retired generations never resume and
  release fibers, subscriptions, and native tasks.
- macOS plus browser runtime smoke tests exercise actual scheduling; a Swift
  build or source parse alone does not establish the async behavior.

## Consequences

AdaScript gains sequential asynchronous authoring without making ECS callback
contexts persistent or letting background workers enter the VM. The engine
owns task lifetime and diagnostic identity. Implementing this requires new
compiler semantics, a runtime scheduler, native async bridges, and Editor
support; the presence of Gravity fibers alone is insufficient.

## Rejected alternatives

### Expose `Fiber` directly as the async API

Manual `Fiber.call()` requires authors to schedule every continuation and
does not supply I/O, ownership, cancellation, or ECS lifetime checks.

### Infer `async` from an `await` expression

Implicit effect propagation obscures whether a caller can suspend and makes
imports, overrides, and diagnostics harder to reason about. `async func` is
required.

### Resume AdaScript directly from a worker completion

That can reenter the globally serialized VM, bypass the appropriate UI/world
scheduler, and deliver stale results after owner teardown or hot reload.

### Retain a callback context across suspension

Borrowed ECS and UI capabilities expire at callback exit. Extending their
lifetime would bypass scheduler access declarations and allow stale native
references to survive world mutation.
