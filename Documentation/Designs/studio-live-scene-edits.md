# Live scene edits in Ada Studio

Status: Proposed

## Behavior

An open editing viewport keeps rendering while the author hides or shows an object,
adds an object, deletes an object or subtree, changes a component in the Inspector,
or drags an object to another parent in the scene hierarchy. The viewport applies
Undo and Redo through the same update path as the original action. Ordinary edits
take effect on the next available frame after the world update. The viewport keeps
its current camera and the playback state of unrelated objects.

Inspector coverage includes property and reference changes and adding or removing
components through the scene Inspector. Document-only fields, such as fields for
components used only in Play, update the document and the Inspector. The live
preview follows the document's existing visibility, transform inheritance, picking
and selection rules. A hierarchy move applies the parent and transform recorded by
the document, including when replaying history. Saving and reopening reproduces the
authored result.

When an edit needs a new asset or derived geometry, the author can keep using the
viewport while it is prepared. A new model appears when ready. If replacing an
existing model, its last valid visual can remain visible until the replacement is
ready. Visibility changes, deletion and newer edits take precedence over pending
work. A failed asset uses the existing scene warning mechanism, with the rest of the
preview still usable.

## Current behavior and ownership

`EditorSceneViewportModel.configure` compares incoming and previous scene models.
Most runtime differences call `reloadSceneRuntimeIfReady`. For a scene with model,
Spine or nested-scene references, or with more than 128 entities, that path reports
scene-loading progress and can suspend hosted updates during installation.
`installSceneRuntimeIncrementally` breaks the full replacement into batches. It
removes the existing authored entities and instantiates the scene again, including
entities that are unaffected by the edit. The asset cache already shares unchanged
imports. The viewport gizmo already applies live transforms and records one history
entry when the gesture finishes.

The editing document and its existing history are the authored source of truth. The
shared AdaUI editing viewport used by desktop and mobile Studio owns
synchronization with its ECS preview. The immersive owner also uses this model
with its own world-access hook. Browser Studio has an independent preview path.
Opening a scene and explicitly replacing the document use the existing full-scene
preparation. Preview synchronization uses the parsed model and derives ordinary
edit summaries directly from it. The existing scene file format, Save and history
snapshots supply persistence and replay.

## Applying changes

- Track the revision and authored records applied to the current preview. Compare
  model revisions by stable editor entity ID and component key. Ignore editor-only
  state when planning ECS changes. Account for changes already applied by the live
  transform and terrain paths so committing a gesture does not apply it twice.
- Write visibility, transforms and supported component values on the current
  runtime entity. For additions and component changes, reuse the loader's payload
  resolution, component decoding, runtime bundle preparation and warnings. Limit
  replacement to an affected representation or subtree when its component requires
  it. Keep the authored ID and update both directions of the editor/runtime mapping.
  Reconcile derived components and refresh the scene environment when an edit
  affects its authored camera.
- Update hierarchy links in both directions. Create required parents before
  attaching children and detach surviving children before deleting an obsolete
  subtree. Preserve document hierarchy and its selection behavior. An affected
  scope can include generated children or dependent data such as animation
  bindings, nested instances, CSG results or mesh terrain. Reuse the specialized
  update paths and refresh only the affected scope.
- Prepare required resources and expensive derived data before the world mutation.
  Reuse existing asset handles and scope resource discovery to changed references
  and their dependencies. Keep resources needed by surviving or still-visible
  entities and release them when their last preview reference is removed.
- Apply each ready group of related changes at a frame-safe ECS boundary, using
  the existing world access mechanism. Publish the entity mappings, diagnostics,
  picking data and redraw request with the committed change. Bound main-actor work
  for large additions and removals so camera input and frames can continue.
- Check document identity and the applicable edit revision before committing
  asynchronous results. Cancel or discard superseded work when the target changes,
  is deleted, or its viewport closes. Independent ready edits can proceed while a
  resource is pending. Preserve a coherent visible state when a preparation fails.

Replacing the whole preview gives loader parity by construction but resets
unrelated state. Routing individual UI commands directly to ECS would duplicate
synchronization across the hierarchy, Inspector and history. Comparing authored
revisions at the viewport boundary gives those entry points one update path and
allows scoped reuse of scene-loading behavior.

## Acceptance

1. Exercise production hierarchy and Inspector actions in a scene with cached
   models and more than 128 authored entities. Hide and show a parent and a child,
   add empty and rendered objects, delete a subtree, change transforms and
   representative component properties, add and remove a component, and reparent
   through a hierarchy drag. Undo and redo each edit.
2. Verify matching Inspector, hierarchy, picking and rendered results. Retain the
   viewport world and unaffected entity IDs, avoid scene-loading callbacks and
   hosted-update suspension, and observe an unrelated animation advance during the
   sequence. Save and reopen and compare authored state to the live result.
3. Exercise rapid edit/Undo/Redo sequences, parent changes across transformed
   branches, and delete or Undo during an asset import. Test an invalid reference
   and an edit in a second scene pane. Confirm that stale work cannot resurrect
   an entity or alter the other pane, and that valid local edits still apply.
4. Record edit-to-present time and the largest frame gap on the same large
   Windows scene before and after the change, with a warm asset cache. Include an
   uncached model addition while orbiting the camera. Verify that the camera
   continues to respond and the scene loading overlay remains absent throughout.
   Use frame and identity evidence in addition to captures of the rendered result.
5. Run Editor regression tests, including existing loading, hierarchy, picking,
   terrain and history tests, and the repository contribution checks. Verify the
   shared AdaUI editing path on affected Studio targets with the available native
   builds or CI. Record the targets exercised and any unavailable checks.

## User documentation

Update [Explore and edit in the AdaEditor Guide](../../Editor/Documentation/EditorGuide.md#explore-and-edit),
linked from the [repository README](../../README.md#ada-studio) and available in
Studio's offline help. Show how to hide an object, move it to another group and undo
the edit while continuing to navigate the viewport. Explain what happens when a
new model needs time to load. Verify the walkthrough in installed Studio and
regenerate and check the offline help with `Editor/scripts/update-offline-documentation.py`.
