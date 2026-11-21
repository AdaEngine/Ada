---
name: ada-genre-action-rpg
description: "Real-time fighting by hand; levels, gear and builds set the numbers. Genre defaults for Ada Studio game builds; matches briefs such as: ARPG, looter, loot game, Diablo-like, looter shooter, a game like Diablo, Path of Exile or Borderlands"
---

# Genre: action-rpg
*Part of the genre library: load `ada-genres` for matching, the camera-token legend and online stand-ins; `ada-genres-mashups` when the idea joins genres.*

**Camera:** `topdown`, angled from above and kept on the hero; `orbit` behind the hero for a
**First-slice variety floor (hypothesis, not measured):** at least 3 enemy kinds, each attacking or moving differently; bosses and elites count. The brief's features list wins if it asks for more.
third-person one, `first` for a looter shooter.

## Design defaults

- **gear-compare**: Gear drops with its rarity in its colour and its name, and pointing at it shows
  what it changes against what you wear, better or worse, in words and arrows. Why: a pickup is a
  quick choice, not homework. Break it when: there is no gear, and power comes from levels and
  skills alone.
- **level-points**: Kills fill an experience bar; each level gives a point for a skill or a stat,
  the first choice comes early, and early points can be taken back. Why: the build is the player's
  own from the first minutes. Break it when: power comes only from gear, a pure looter.
- **potion-charges**: Healing is a few potion charges on one key, refilled at checkpoints and a
  little by kills. Why: healing is a choice in the fight, never a hoard. Break it when: health comes
  back on its own between fights, a gentle game.

## Feel

- **sure-strike**: An attack starts the moment it is pressed and turns toward the nearest enemy in
  reach, and a dodge can cut the end of a swing, never its start. Why: the hero hits what the player
  meant, and a mistake can still be dodged. Break it when: heavy, committed swings are the
  challenge, a slow duel the user asked for.
- **loot-burst**: A beaten enemy bursts into gold and gear that scatter and settle; gold flies to
  you, and a rare drop rises in a beam of its colour with its own sound. Why: the reward is seen
  across the screen, and the best one is heard. Break it when: rewards come only at the end of a
  level.
- **breakpoints**: An upgrade is felt as fewer hits: an enemy falls in one swing fewer, and a pack
  you fled from falls to one blast. Why: growth shows in the fight, not only on the sheet. Break it
  when: numbers never change, a game of skill alone.
- **pack-fights**: Enemies come in packs of weak ones around a tougher one, and an area attack
  through a pack scatters them, its hits added into one rising number. Why: the hero feels strong
  against many, and one number says how strong. Break it when: every fight is one enemy, a duel.

## Feel variants

- **horde**: Horde: fast moves, big packs, area skills that clear the screen.
- **heavy**: Heavy and deliberate: few enemies, stamina, committed swings, a dodge that costs.
- **guns**: Guns: weapon families that each handle their own way, shooting from cover.

## Choices that shape the pitch

- **Combat:** clicks or keys from above, `topdown` (default) · behind the hero with a dodge and
  stamina, `orbit` · guns through the eyes, a looter shooter, `first`.
- **Loot:** gear of a few rarities with a quick compare (default) · fewer uniques that change the
  rules · no gear, skills only.
- **Death:** back to the last checkpoint with everything kept (default) · gold dropped where you
  fell, to win back · the hero gone for good, a hard mode.
- **Build:** a few skills opened by level (default) · a skill board with keystones · gear that
  changes how the hero moves and fights.
- **Feeling:** the player feels their power grow by clearing a pack that nearly killed them earlier,
  because a level or an item cut the hits each enemy takes.

## Later, beyond the first slice

- Crafting that rerolls gear within a budget → add it as its own feature milestone
- Item slots and affix rules → add it as its own feature milestone
- A grid inventory where shapes are the puzzle → iterate on it after play, in the same project
- A stash and several characters → grow it across later milestones
- Bosses with phases and parts to break → iterate on it after play, in the same project
- Endgame maps of rising tiers → grow it across later milestones
- Loot weighted toward the current build → iterate on it after play, in the same project
- Enemies that flank and work together → not verified in Studio yet: ask for it after play and the agent will try it without a verified path
- Co-op and trading with other players → needs a server: not built by Studio; offer the local stand-in from `ada-genres`

## In a mashup

The action RPG leads loot and the build. Action leads timing, targeting and camera, and the chosen
stakes lead checkpoints. A roguelite leads the run and what a death resets. Extraction leads what is
kept or lost. A survival half leads gathering and crafting, and the action RPG leads the fights.

---

Adapted from Donchitos/Claude-Code-Game-Studios (MIT): `.claude/genres/chipsets/action-rpg.md` @ abc0de7. See `NOTICE.md` beside the skills root.
