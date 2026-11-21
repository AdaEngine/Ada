---
name: ada-genre-action-roguelite
description: "Real-time runs that end in death; progress carries over. Genre defaults for Ada Studio game builds; matches briefs such as: roguelite, run-based action, buildcraft, a game like Hades, Dead Cells or Enter the Gungeon"
---

# Genre: action-roguelite
*Part of the genre library: load `ada-genres` for matching, the camera-token legend and online stand-ins; `ada-genres-mashups` when the idea joins genres.*

**Camera:** `topdown`, sitting between the player and the aim; `follow2d` for a side view.
**First-slice variety floor (hypothesis, not measured):** at least 4 enemy kinds, each attacking or moving differently; bosses and elites count. The brief's features list wins if it asks for more.

## Design defaults

- **pick-a-boon**: Clearing a room offers one of a few upgrades, each saying what it does, and the
  build grows from them. Why: every room changes the run, so no two runs play the same. Break it
  when: the build is a loadout chosen before the run.
- **meta-progress**: Death keeps a currency spent between runs on small permanent upgrades, and the
  game saves it. Why: a lost run still moves the player forward. Break it when: only skill carries
  over, pure runs the user asked for.
- **generated-floors**: Each run lays its floors out from hand-made rooms in a new order, with a
  safe first room, and the run's seed is shown at its end. Why: every run is new, and every room is
  still fair. Break it when: one fixed route learned run after run.

## Feel

- **dodge-dash**: A dash on its own key is untouchable from its first moment, and an attack pressed
  during it comes out as it ends. Why: a mistake can be dodged, so skill beats numbers. Break it
  when: defence is a block or a parry, a duel the user asked for.
- **loot-pops**: Coins and pickups burst out of a beaten enemy, then fly to the player on their own.
  Why: the reward is seen and caught without breaking the fight. Break it when: nothing drops, a run
  where rewards come only at the room's end.
- **room-clear**: The last enemy of a room goes down harder, then a quiet beat, the doors unlock
  with a clear sound and the reward appears. Why: each room ends on a small high, and the way on is
  plain. Break it when: one open level with no rooms, where fights flow into each other.

## Feel variants

- **aggressive**: Fast and aggressive: dashes, quick hits, health won back by attacking.
- **gunplay**: Bullets and dodges: a gun always firing, rolls through bullet patterns.
- **heavy**: Heavy and deliberate: slow weapons that commit, fewer enemies, each fight a duel.

## Choices that shape the pitch

- **Combat:** melee with a dash (default) · guns and a dodge roll · a side view that runs and jumps,
  `follow2d`.
- **Builds:** one of a few upgrades after each room (default) · items found in rooms, the strongest
  with a drawback · a loadout picked before the run.
- **Between runs:** a currency for small permanent upgrades (default) · new weapons and starts
  unlocked, no stat gains · nothing, pure skill.
- **What the player sees:** from above, `topdown` (default) · from the side, `follow2d`.
- **Feeling:** the player feels clever and strong by finding upgrades that combine, because each
  room offers a choice and the build shows how they stack.

## Later, beyond the first slice

- A hub between runs with characters and a story → grow it across later milestones
- Many biomes and bosses → grow it across later milestones
- Difficulty modifiers after a win → iterate on it after play, in the same project
- A shop in the middle of a run → iterate on it after play, in the same project
- Upgrades that multiply each other → add it as its own feature milestone
- Rare items and protection from long unlucky streaks → iterate on it after play, in the same project
- Co-op runs on one screen → iterate on it after play, in the same project
- Daily seeded runs shared with others → needs a server: not built by Studio; offer the local stand-in from `ada-genres`

## In a mashup

The roguelite leads the run: what a death resets and what carries over. The action half leads the
immediate feel, combinatorial pieces lead the build, and aim and threats stay readable as the build
grows. A deckbuilder leads the build as cards. A platformer leads movement in a side view. A
management half leads the hub between runs.

---

Adapted from Donchitos/Claude-Code-Game-Studios (MIT): `.claude/genres/chipsets/action-roguelite.md` @ abc0de7. See `NOTICE.md` beside the skills root.
