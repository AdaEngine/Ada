---
name: ada-genre-turn-based-strategy
description: "Armies and cities moved a turn at a time on a map. Genre defaults for Ada Studio game builds; matches briefs such as: strategy, 4X, grand strategy, wargame, empire builder, a game like Civilization, Polytopia or Crusader Kings"
---

# Genre: turn-based-strategy
*Part of the genre library: load `ada-genres` for matching, the camera-token legend and online stand-ins; `ada-genres-mashups` when the idea joins genres.*

**Camera:** `strategy`, an angled pan and zoom; `topdown` for a flat map of tiles, `static` for a
small map that fits the window.

## Design defaults

- **yields-shown**: Each tile shows what it gives, and the income per turn is on screen with where
  it comes from, a pointer away. Why: the player sees why a city grows fast or slow. Break it when:
  one resource only, and the map itself is the economy. [johnson-4]
- **forecast**: Before an attack, the result is shown: the damage both ways and who would fall. Why:
  a war is planned, not gambled. Break it when: dice and luck are the point, a game of chance.
- **explore-first**: The map starts dark except around the first city, and scouts reveal it tile by
  tile. Why: exploring is the most fun part, and what lies past the edge pulls the player on. Break
  it when: a known map is the point, a wargame on a set board. [civ-manual-1], [amplitude-1]
- **game-that-ends**: The game ends at a turn limit with a score, or sooner by a plain win shown
  from the start, on a map small enough to finish in one sitting. Why: a decided game never drags on
  for turns of clicking. Break it when: an endless sandbox empire the user asked for. [johnson-3],
  [civ-manual-1], [polytopia-1]
- **turn-summary**: Each turn opens with a short list of what changed that needs a decision, and
  each kind of alert can be turned off. Why: many systems stay readable without a wall of messages.
  Break it when: a tiny map where everything is in view. [victoria-3-1], [johnson-4]

## Feel

- **one-more-turn**: Every city shows what it is making and in how many turns, and something always
  finishes soon, so ending a turn brings a new choice. Why: near and far goals overlap, so there is
  always one more turn. Break it when: a single battle with nothing to build. [johnson-2]
- **rivals-readable**: Rival turns play quickly and show only what your units can see, and a rival
  army massing near your border is pointed out before it strikes. Why: a war never comes from
  nowhere, and waiting is short. Break it when: hidden armies are the point, a game of bluff and
  surprise.
- **teach-then-look-up**: The first turns bring in one system at a time, and afterwards every number
  and icon explains itself under the pointer, with the full detail in a panel the player opens. Why:
  many systems are learned in play without a wall of rules. Break it when: a map so small there is
  one system to learn. [johnson-4]

## Feel variants

- **empire**: Empire: cities, research and a slow climb to a big win.
- **skirmish**: Skirmish: a tiny map, a short turn limit, a score, a game in a few minutes.
- **war**: Wargame: no cities to build, armies on terrain, a front line to hold.

## Choices that shape the pitch

- **How to win:** take every rival capital (default) · the best score when the turns run out ·
  the first to a goal, a wonder or a discovery.
- **Rivals:** a few AI rivals, each with a plain leaning, one warlike and one a builder
  (default) · one rival, a duel · two players taking turns on one
  device.
- **The map:** a small generated map with a fair start for each side (default) · a
  hand-made scenario.
- **What the player sees:** angled pan and zoom, `strategy` (default) · flat from above,
  `topdown` · one map that fits, `static`.
- **Feeling:** the player feels ongoing planning by finishing one project and choosing the next,
  because near and far goals stay connected.

## Later, beyond the first slice

- Diplomacy, trade and alliances with rivals → not verified in Studio yet: ask for it after play and the agent will try it without a verified path
- Rising costs for wide empires → add it as its own feature milestone
- Catch-up research for trailing sides → add it as its own feature milestone
- A research tree → grow it across later milestones
- Rulers with traits and families → not verified in Studio yet: ask for it after play and the agent will try it without a verified path
- Events written for the setting, with choices → add it as its own feature milestone
- Peoples with their own units and timing → grow it across later milestones
- Online games with other players → needs a server: not built by Studio; offer the local stand-in from `ada-genres`

## In a mashup

Strategy leads the map, the turn and the rivals' turns. Tactics leads a battle when armies meet, on
its own grid. Character drama leads rulers, stress and events, and strategy leads land and money. A
city builder leads a city's own layout. A card game leads actions as cards.

---

Adapted from Donchitos/Claude-Code-Game-Studios (MIT): `.claude/genres/chipsets/turn-based-strategy.md` @ abc0de7. See `NOTICE.md` beside the skills root.
