# AdaUI View Identity

AdaUI reconciles a new view tree against the mounted `ViewNode` tree. A node is preserved only when the new node and old node describe the same identity and the new node can update the old node. Preserved nodes keep their `@State`, focus state, in-flight animation controllers, layers, and other node-local runtime state. Recreated nodes start with fresh runtime state.

## Identity Model

For every sibling list, AdaUI resolves identity in this order:

1. Explicit identity from `.id(_:)` or `ForEach` data IDs.
2. Structural identity from result-builder constructs, including the active branch of `if` / `else`.
3. Structural sibling position for children without explicit IDs.

Explicit IDs are scoped to the current sibling list. IDs must be unique within that list; duplicate IDs are ambiguous and are not a stable state-preservation contract.

## `.id(_:)`

`.id(_:)` binds a node to a hashable identity value. If the value is unchanged, AdaUI may move that node to a different sibling index and preserve its runtime state. If the value changes, AdaUI treats the view as a different node and recreates it.

The view type still participates in matching. A node with the same explicit ID but an incompatible concrete node type is recreated instead of being updated in place.

## `ForEach`

`ForEach` wraps each generated child in an explicit identity:

- `ForEach(data)` uses each element's `Identifiable.id`.
- `ForEach(data, id: keyPath)` uses the key-path value.
- `ForEach(0..<n)` is position-based and is intended for constant ranges.

Reordering identified data preserves the child nodes associated with those IDs, so row `@State`, focus, and animations follow the data item rather than the visual index. Inserting or deleting an item only creates or removes nodes for the affected IDs.

## Conditional Branches

`if` / `else` branches add a structural branch discriminator. This prevents state from moving between two branches that happen to produce the same view type at the same sibling position. Switching from one branch to the other recreates that branch's node; explicit IDs are still scoped by the active branch structure.

## `@State` Properties

`@State` storage belongs to the preserved view node and to the exact property wrapper slot inside that view. The slot key includes the wrapper's declaration order among state-like wrappers, its reflected property label, and its value type.

Renaming a `@State` property creates a new storage slot. Reordering `@State` properties also creates new slots for the moved wrappers. Adding or removing a state wrapper preserves only wrappers whose slot key is unchanged.

This rule intentionally resets state after source-level declaration edits rather than migrating values between properties. It prevents a rebuild from moving state between different properties or between different view instances. Dynamic or reorderable view instances still need `.id(_:)` or `ForEach(_:id:)` so the owning view node has stable identity.

## Unkeyed Children

Children without explicit IDs are matched by structural sibling position. AdaUI uses common-prefix and common-suffix matching for unkeyed runs, which preserves unaffected nodes around an insertion or deletion in the middle. Reordering unkeyed siblings has no semantic identity signal, so state is not guaranteed to follow a particular data item; use `.id(_:)` or `ForEach(_:id:)` for reorderable content.

## Mixed Keyed And Unkeyed Children

In a mixed sibling list, keyed nodes are matched by ID first. The remaining unkeyed nodes are reconciled by their structural order with the same prefix/suffix rules. This keeps static unkeyed content stable around keyed inserts, deletes, and reorders, while still requiring explicit IDs for dynamic reorderable items.
