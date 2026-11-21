---
name: ada-genre-grid-puzzle
description: "Push blocks onto targets (Sokoban); a wrong push can make it unsolvable. Genre defaults for Ada Studio game builds; matches briefs such as: puzzle, block pushing, Sokoban, a game like Baba Is You or Stephen's Sausage Roll"
---

# Genre: grid-puzzle
*Part of the genre library: load `ada-genres` for matching, the camera-token legend and online stand-ins; `ada-genres-mashups` when the idea joins genres.*

**Camera:** `static`, the whole level in the window; `follow2d` for a level bigger than the
window; `fixed` for a 3D grid seen from a set angle.

## Design defaults

- **few-teaching-levels**: A handful of hand-made levels in order: the first teaches the push where
  nothing can go wrong, each next one adds or twists one thing, the last combines them, and solved
  levels are kept. Why: the player learns every rule by pushing, never from text. Break it when: one
  big level to work through, or a fresh generated puzzle each day.
- **board-shows-rules**: Walls, pieces that can be pushed and targets each look like what they are,
  and a target lights up when it is covered. Why: the player plans from what they see, so the answer
  is fair when it comes. Break it when: finding out what things do is the discovery, hidden rules
  learned by trying.

## Feel

- **crisp-steps**: Each press moves one square in a quick slide that lands with a soft thud, a held
  key repeats steadily, and a press made during a move is kept for the next. Why: moves come as fast
  as the player thinks them. Break it when: slowness is the theme, a heavy stone that takes effort
  to shove.
- **undo-every-push**: Undo is one key with no limit and takes back one move with all it pushed;
  restart is another key, and undo brings a restart back. Both are taught on the title. Why: a bad
  push costs nothing, so the player tries ideas. Break it when: the user wants a strict move limit
  with no take-backs.
- **dead-end-shown**: A push that makes the level unsolvable, a box shoved into a corner, is
  noticed: the box dims and a quiet prompt offers undo. Why: the player never keeps pushing in a
  level that can no longer be won. Break it when: spotting your own dead end is the challenge, a
  strict mode the user asked for.
- **eureka-solve**: Each level turns on one fair surprise about a rule the player thought they knew,
  and once it is seen the solution is a few moves, not a chore; the last box landing rings and the
  next level opens at once. Why: the insight is the reward. Break it when: the levels are calm
  tidying with no trick, pushing for its own sake.

## Feel variants

- **clever**: Clever and sparse: small boards, few pieces, one surprising move a level.
- **wordplay**: Rule-bending: the rules are word tiles on the board, and pushing them into new
  sentences changes what things do.
- **cozy**: Calm and cozy: gentle levels about putting things where they belong, each push tidying a
  little more.

## Choices that shape the pitch

- **The pieces:** boxes pushed onto targets (default) · rules as word tiles you push · pieces longer
  than one square that roll and turn as you push · ice, where whatever moves slides until it hits
  something.
- **Failure:** undo and restart, no death (default) · a move limit per level, with stars for fewer
  moves · hazards that end the level, taken back with one undo.
- **What the player sees:** the whole level at once, `static` (default) · a bigger level that
  scrolls, `follow2d` · a 3D grid from a set angle, `fixed`.
- **Feeling:** the player feels eureka by seeing that a rule they trusted works another way, because
  the levels taught it fairly and undo made every try free.

## Later, beyond the first slice

- Hints that nudge without giving the answer → iterate on it after play, in the same project
- A move count and a par per level → iterate on it after play, in the same project
- Optional harder levels hidden in plain sight → iterate on it after play, in the same project
- Many worlds of hand-made levels → grow it across later milestones
- A story told through the levels → grow it across later milestones
- A level editor where a level is saved only once cleared → not verified in Studio yet: ask for it after play and the agent will try it without a verified path
- Two players pushing together with different moves → iterate on it after play, in the same project

## In a mashup

The grid puzzle leads the rules, undo, the order of levels and the solver's proof that each level
can be won. A platformer half makes it a puzzle-platformer, where movement serves the grid and never
skips it. A dungeon or roguelike half leads the run, and each room's lock is a small push puzzle. A
story half leads what the levels mean. A cozy half leads theme and pace, and the puzzles turn to
tidying.

---

Adapted from Donchitos/Claude-Code-Game-Studios (MIT): `.claude/genres/chipsets/grid-puzzle.md` @ abc0de7. See `NOTICE.md` beside the skills root.
