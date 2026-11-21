---
name: ada-genre-puzzle-platformer
description: "Platforming where each level is a puzzle to solve. Genre defaults for Ada Studio game builds; matches briefs such as: perspective puzzle, two characters solving it together, a game like Braid, Limbo, Fez or Monument Valley"
---

# Genre: puzzle-platformer
*Part of the genre library: load `ada-genres` for matching, the camera-token legend and online stand-ins; `ada-genres-mashups` when the idea joins genres.*

**Camera:** `follow2d`; `static` when a level fits the window, `fixed` for a 3D level seen from a
set angle.

## Design defaults

- **one-idea-a-level**: Each level is built around one idea: shown first where it is safe, then
  used, then twisted with something already learned. Why: the player learns the rule by playing,
  never from text. Break it when: one big open level of mixed ideas, a world of puzzles to roam.
- **fair-jumps**: Jumps forgive a late or early press, but a gap the puzzle blocks is always out of
  reach, and every surface you can stand on looks the same. Why: the player solves with their head,
  never by a lucky jump. Break it when: the exact jump is the puzzle, a precision platformer.

## Feel

- **undo-anything**: Undo is one key with no limit and takes back a move and all it caused; restart
  is another key, and undo brings a restart back. Both are taught on the title. Why: trying an idea
  costs nothing, so the player experiments. Break it when: each try is a whole run through traps,
  which use instant retry instead.
- **no-dead-ends**: A level never becomes unsolvable in silence: a stuck position shows a quiet
  restart prompt, and a death puts you back at the puzzle's start at once. Why: the player is never
  left trying a level that can no longer be solved. Break it when: the user wants a lost level
  replayed from the menu, a strict challenge.
- **rules-visible**: Every object that matters looks like what it does: a switch and the door it
  opens share a colour or a line, and cause and effect animate. Why: the player reasons from what
  they see, so the answer is fair when it comes. Break it when: finding out what things do is the
  discovery, hidden rules learned from clues.
- **eureka-click**: The solving move lands with a clear sound and the exit lighting at once, and the
  walk from the idea to the door is short. Why: the insight is the reward, not the chores after it.
  Break it when: the escape after the idea is the point, a timed run out of the level.

## Feel variants

- **thoughtful**: Calm and thoughtful: no hazards and no clock, time to think, undo on every move.
- **eerie**: Dark and tense: traps that kill at once, instant retry, a world that teaches by danger.
- **flowing**: Flowing: momentum and bounces are part of the answer, puzzles solved on the move.

## Choices that shape the pitch

- **The twist:** pushing blocks and switches in a side view (default) · turning the world to change
  what connects · two characters with different moves, swapped with one key · rewinding time as a
  move.
- **Failure:** undo and restart, no death (default) · traps that kill and an instant retry · a few
  lives per level, arcade stakes.
- **What the player sees:** a side view, `follow2d` (default) · the whole level at once, `static` ·
  a 3D level from a set angle you can turn, `fixed`.
- **Feeling:** the player feels eureka by seeing the answer all at once after a few wrong tries,
  because the rule was taught fairly and undo made trying free.

## Later, beyond the first slice

- Hints that nudge without giving the answer → iterate on it after play, in the same project
- Hidden extras behind harder optional puzzles → iterate on it after play, in the same project
- A level editor with a required clear before sharing → not verified in Studio yet: ask for it after play and the agent will try it without a verified path
- Two-player co-op with tools that only work together → iterate on it after play, in the same project
- A story told through the levels → grow it across later milestones
- Many worlds of hand-made levels → grow it across later milestones
- A speedrun timer → iterate on it after play, in the same project

## In a mashup

The puzzle leads rules, undo, level teaching and the solution check; the platformer leads movement
and camera, and its forgiveness never lets a jump bypass the puzzle. A story half leads what the
levels mean. A metroidvania leads the map, and puzzles guard its gates. A physics half leads objects
that move on their own, and each level is checked by a recorded clear.

---

Adapted from Donchitos/Claude-Code-Game-Studios (MIT): `.claude/genres/chipsets/puzzle-platformer.md` @ abc0de7. See `NOTICE.md` beside the skills root.
