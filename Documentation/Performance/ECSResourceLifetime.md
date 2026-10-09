# ECS resource and allocation lifetime

Local correctness milestone, 2026-10-09.

## Reproduced failure

`BlobArray._Buffer.deinit` freed the allocation and initialized-slot flags without
destroying remaining values. Resource replacement/removal, `clearResources()` and
World teardown therefore leaked stored references. Live component columns were
also affected when their final owner disappeared without an explicit clear.

The initial nine regression tests failed before the fix with eleven failed
expectations. These tests checked destruction counters without dereferencing
resource views that were dangling in the original implementation.

## Ownership and cleanup

- The allocation owner records its stride and destroys initialized runs before
  freeing memory. Holes, explicitly removed/cleared slots and values transferred
  by reallocation or archetype moves are not destroyed twice.
- Resource change-tick boxes retain the resource allocation. They already travel
  with `Ref`, `ResMut` and `DynamicResource`, so these views keep the pointed-to
  resource alive without adding a field to every component `Ref` or `UnsafeBox`.
  The owner is captured by the existing managed-box deallocator closure.
- Replacing/removing a resource detaches it from World. Existing resource views
  still address the old value; mutations through them do not affect a replacement.
  The final storage/view owner releases the value. Views do not retain World.
- Resource metadata snapshots share allocation ownership. World teardown uses
  normal field destruction rather than forcibly clearing storage still owned by
  snapshots or resource views. `World.clear()` continues to preserve resources.
- Reflected resource and event callbacks hold a local owner through raw-pointer
  access. A callback may remove its resource or finish its dynamic parameter
  without invalidating the pointer currently in use. A dynamic write updates the
  tick associated with the allocation it wrote, even if the callback refreshes
  the parameter.

Raw pointer/opaque-pointer `UnsafeBox` and `UnsafeAnyBox` constructors remain
borrowed: they neither destroy nor free the external value. Component query refs
and manually constructed refs retain their existing structural-mutation access
contract. `BlobArray.realloc` still invalidates views of the old allocation;
the resource-view guarantee applies to the fixed resource allocation and its
original change-tick handles, not arbitrary copied raw pointers.

The optional `BlobArray` deinitializer still defines how values are destroyed;
the destructor invokes it only for live initialized slots. No concurrency or
external synchronization contract changed, and application-created ownership
cycles still require explicit cycle breaking.

## Validation

- All **218 tests in 30 suites** pass in Debug and Release: the complete
  AdaECSTests and AdaUtilsTests targets in the isolated adapter.
- **19 new tests** cover resource replacement, generic/runtime-type removal,
  repeated clear, World/component teardown, snapshots, copied refs,
  get-or-init refs, `ResMut`, dynamic views, reentrant reflection/event callbacks,
  sparse allocation destruction, reallocation transfer, managed box aliases,
  retained owners and borrowed pointer/opaque boxes. Two tests each run both
  read and write cases.
- All **seven benchmark smoke cases** run successfully, including SpawnBatch.
  These runs validate execution/cleanup, not comparative performance.
- Focused SwiftLint on the lifetime implementation/new tests and
  `git diff --check` pass.
- An existing chunk-pointer test now explicitly extends the chunk's lifetime
  through its final pointee read. Release may end an owner's lifetime after its
  last use, before a subsequent dereference of a returned borrowed pointer.
  The snapshot destruction check likewise explicitly retains its snapshot
  while checking that the value is still alive.

Validation imports the production AdaECS/AdaUtils/Math sources through the
task-owned SwiftPM adapter at `/tmp/adaecs-storage-20261009`, with local dependency
sources and the existing macro helper. This avoids rewriting the user's shared
build cache, which contains artifacts from a different Swift toolchain. The
adapter also builds the real benchmark client and the previous storage/query/
spawn/batch probes. This is focused engine/client evidence, not a full engine,
editor or device run.

Address Sanitizer was not validated: previous attempts in this task's isolated
environment were blocked by the signed test helper's sanitizer policy or stopped
in sanitizer initialization before tests ran. Destruction counters and weak
references are the evidence for this milestone. No performance improvement is
claimed from this correctness change.
