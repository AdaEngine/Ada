---
name: ada-genre-hidden-object
description: "Find listed items or characters in a cluttered scene. Genre defaults for Ada Studio game builds; matches briefs such as: seek and find, picture search, a game like Hidden Folks, Mystery Case Files or Where's Waldo"
---

# Genre: hidden-object
*Part of the genre library: load `ada-genres` for matching, the camera-token legend and online stand-ins; `ada-genres-mashups` when the idea joins genres.*

There is no tested way to build large authored content yet: a first slice uses a small hand-made scene and a short
target list.

**Camera:** `static`, the scene and target strip fit the window.

## Design defaults

- **targets-in-view**: Keep a strip of targets beside the cluttered scene so the player can see what
  to seek. Why: the search has a clear purpose. Break it when: the scene is open exploration with no
  required finds. [hiddenfolks-1]
- **unhurried-search**: Let the player take their time and explore objects without a penalty for an
  empty click. Why: curiosity keeps the scene pleasant to search. Break it when: a timed contest is
  the stated challenge. [hiddenfolks-3]

## Feel

- **hint-on-request**: Selecting a target gives a clue to help find it. Why: a stuck player can ask
  for help while keeping control of the search. Break it when: the target's written clue is already
  the main instruction. [hiddenfolks-2]
- **scenery-answers**: Let flaps open and bushes part when the player explores them. Why: searching
  changes the scene instead of only testing the pointer. Break it when: every target is visible from
  the start, a pure observation puzzle. [hiddenfolks-4]
- **quiet-and-busy**: Give different parts of the scene sparse or busy ambient sound. Why: the
  player gets relief from constant noise while looking around. Break it when: the scene is silent by
  design. [hiddenfolks-5]

## Feel variants

- **gentle**: Gentle discovery: unhurried looking, harmless exploration and clues on request.
  [hiddenfolks-2], [hiddenfolks-3]
- **playful**: Playful discovery: poke at the scenery and enjoy how it changes. [hiddenfolks-4]

## Choices that shape the pitch

- **What to find:** pictured targets (default) · names in a list · short riddles describing
  the targets.
- **The search:** clutter with interactive hiding places (default) · a still picture · a
  diorama whose viewpoint reveals differences.
- **Stakes:** no search clock or penalty (default; [hiddenfolks-3]) · a timed score challenge.
- **What the player sees:** a scene that fits the window, `static` (default) · a larger scene
  explored by panning · a rotatable diorama, `orbit`.
- **Feeling:** the player feels a small delight of discovery when a hint makes a hidden detail
  stand out of the clutter ([hiddenfolks-2]).

## Later, beyond the first slice

- More scenes and larger illustrations → grow it across later milestones
- A story connecting the finds → grow it across later milestones
- Inventory puzzles that unlock new parts of a scene → add it as its own feature milestone
- A rotatable diorama with finds hidden by depth → add it as its own feature milestone
- Stronger hints after play shows where people get stuck → iterate on it after play, in the same project
- A scene editor with shared puzzles → not verified in Studio yet: ask for it after play and the agent will try it without a verified path

## In a mashup

The hidden-object half leads the target list and the search. A detective half leads what the
found evidence proves. A point-and-click half leads inventory and locks. A word half turns
target descriptions into riddles. A cozy half leads the pace and atmosphere while the search
gives the player a reason to look closely.

---

Adapted from Donchitos/Claude-Code-Game-Studios (MIT): `.claude/genres/chipsets/hidden-object.md` @ abc0de7. See `NOTICE.md` beside the skills root.
