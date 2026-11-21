---
name: ada-genre-platformer
description: "Run and jump past hazards; the jump is the core verb. Genre defaults for Ada Studio game builds; matches briefs such as: 2D or 3D platformer, jump-and-run, a game like Celeste or Mario"
---

# Genre: platformer
*Part of the genre library: load `ada-genres` for matching, the camera-token legend and online stand-ins; `ada-genres-mashups` when the idea joins genres.*

**Camera:** `follow2d`; `orbit` in 3D.
**First-slice variety floor (hypothesis, not measured):** at least 2 enemy kinds, each attacking or moving differently; bosses and elites count. The brief's features list wins if it asks for more.

## Design defaults

- **instant-retry**: A fall or a hit puts you back at the last checkpoint at once: no lives, no
  game-over screen. Why: failing costs seconds, so the hard jump gets tried again. Break it when:
  arcade stakes are the point, lives and a game over.

## Feel

- **forgiving-jump**: Late jumps off a ledge, early presses just before landing and clipped corners
  still count. Why: a miss is the player's mistake, never the game's. Break it when: the user
  wants exact, unforgiving jumps as the challenge.
- **jump-control**: Hold the button to jump higher, tap it for a hop, and fall faster than you rise.
  Why: the player shapes every arc and lands soon enough to act again. Break it when: every jump is
  meant to be the same arc, as in a one-button game.
- **jump-land-juice**: Every jump and landing has its own sound and a quick squash of the body, with
  a puff of dust on a hard landing. Why: the body feels its weight without a word on screen. Break
  it when: the look is still and abstract on purpose, shapes that never bend.
- **look-ahead**: The camera shows more of where you are heading and holds still through ordinary
  jumps. Why: the next hazard is seen in time, and the screen does not bob. Break it when: each
  level is one room that fits the window.
- **fair-hurtbox**: Only your body takes hits, never your hair or cape: the hit box sits inside the
  sprite. Why: a near miss looks like one. Break it when: the part that can be hit is the hook, a
  flame or a shadow.

## Feel variants

- **precise**: Tight and arcade: quick to start and stop, short committed hops, fast falls.
- **flowing**: Flowing: speed builds on slopes and carries through slides and wall runs.
- **heavy**: Heavy and grounded: slow to turn, jumps with weight that land with a thud.

## Choices that shape the pitch

- **Failure:** instant retry at checkpoints (default) · lives and a game over, arcade stakes · none,
  exploring at your own pace.
- **Progression:** hand-made screens in order (default) · one connected map opened by new moves, a
  metroidvania · an endless run.
- **What the player sees:** side view, `follow2d` (default) · 3D behind the avatar, `orbit`.
- **Feeling:** the player feels precise mastery by clearing a jump they missed a moment ago, because
  the miss was their own and the retry is instant.

## Later, beyond the first slice

- New moves over time → grow it across later milestones
- Bosses → iterate on it after play, in the same project
- Collectible hunts and completion → iterate on it after play, in the same project
- Checkpoints traded for rewards → iterate on it after play, in the same project
- A speedrun timer and ghosts → iterate on it after play, in the same project
- Two-player co-op on one screen → iterate on it after play, in the same project
- A level editor → not verified in Studio yet: ask for it after play and the agent will try it without a verified path

## In a mashup

The platformer leads movement and camera. Puzzle leads rules, undo and level teaching, and movement
forgiveness never lets a jump bypass the puzzle. A metroidvania leads the map and its ability gates.
A roguelite leads the run and what carries over. A management half leads money and building between
levels.

---

Adapted from Donchitos/Claude-Code-Game-Studios (MIT): `.claude/genres/chipsets/platformer.md` @ abc0de7. See `NOTICE.md` beside the skills root.
