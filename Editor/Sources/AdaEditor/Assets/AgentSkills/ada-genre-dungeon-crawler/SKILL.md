---
name: ada-genre-dungeon-crawler
description: "A party explores a grid dungeon in first person, step by step. Genre defaults for Ada Studio game builds; matches briefs such as: blobber, grid crawler, first-person dungeon, a game like Legend of Grimrock or Etrian Odyssey"
---

# Genre: dungeon-crawler
*Part of the genre library: load `ada-genres` for matching, the camera-token legend and online stand-ins; `ada-genres-mashups` when the idea joins genres.*

**Camera:** `first`, one square per step and a quarter turn per turn; `topdown` for a crawl seen
from above.
**Research:** needs primary research: the source research has two dungeon-crawler entries, on generated
floors and rest that brings monsters back. It has no entry for grid steps, the party or fights in
the crawl view.

## Design defaults

- **auto-map**: A small map draws itself square by square as you walk, with an arrow for the way you
  face. Why: the player always knows where they have been, so the blank squares pull them on. Break
  it when: mapping by hand is the challenge, an old-school crawl with no map.
- **stairs-down**: Each floor has stairs down to a harder one, and the floor you are on is on
  screen. Why: going deeper is a choice, and the depth is the score. Break it when: the dungeon is
  one hand-made floor and the way out is the goal.
- **camp-rest**: Resting in a safe room heals the party and saves the game, but ordinary monsters
  come back. Why: a safe room is a goal to reach, and rest has a price. Break it when: the crawl is
  one short dive with no way to rest.

## Feel

- **dark-ahead**: The corridor fades to dark a few squares ahead, and monsters are heard before they
  are seen, from the side they are on. Why: each step into the dark is a small dare. Break it when:
  the dungeon is bright and friendly, a cozy crawl for young players.

## Feel variants

- **brisk**: Brisk: quick steps, quick fights, small floors and the stairs never far.
- **tactical**: Tactical: fewer, harder fights where the front and back rows matter and the
  monster's next move is shown.
- **dread**: Tense and dark: a torch that burns down, scarce healing, sounds behind every wall.

## Choices that shape the pitch

- **Fights:** turn by turn, the monster's next move shown (default) · real time on the grid,
  stepping aside from a blow as it lands.
- **Dungeon:** generated floors (default) · one hand-made floor of keys, levers and locked doors · a
  single tower to climb.
- **Party:** a ready-made party (default) · pick each hero's class at the start · one hero alone.
- **What the player sees:** through the party's eyes, `first` (default) · from above,
  `topdown`.
- **Feeling:** the player feels dread and discovery by stepping into a dark square where they heard
  something, because the map shows what is known and the dark hides the rest.

## Later, beyond the first slice

- Classes and a party built from them → add it as its own feature milestone
- Orders the party follows on its own → add it as its own feature milestone
- Gear that teaches skills → add it as its own feature milestone
- Traps, pressure plates and lever puzzles → iterate on it after play, in the same project
- Hidden walls and secret rooms → iterate on it after play, in the same project
- Food and torches that run out → iterate on it after play, in the same project
- A town with shops between dives → add it as its own feature milestone
- Many hand-made floors with a story → grow it across later milestones

## In a mashup

The crawler leads grid movement, the party and the map. A roguelike half leads generated floors and
what a death costs. A card battler half leads fights as cards the party plays, and the grid stays. A
horror half leads dread and sound. A puzzle half leads lever and pressure-plate rooms with one
answer each.

---

Adapted from Donchitos/Claude-Code-Game-Studios (MIT): `.claude/genres/chipsets/dungeon-crawler.md` @ abc0de7. See `NOTICE.md` beside the skills root.
