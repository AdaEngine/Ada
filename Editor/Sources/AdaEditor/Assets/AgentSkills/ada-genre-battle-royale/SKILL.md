---
name: ada-genre-battle-royale
description: "Many players drop onto a shrinking map; the last one standing wins. Genre defaults for Ada Studio game builds; matches briefs such as: last one standing, a game like Fortnite, PUBG or Tetris 99"
---

# Genre: battle-royale
*Part of the genre library: load `ada-genres` for matching, the camera-token legend and online stand-ins; `ada-genres-mashups` when the idea joins genres.*

**Camera:** `chase`, behind the player; `topdown` for a battle royale seen from above; `first`
for first person.
**Online:** One player drops in with bots in every other seat, and the bots are named as bots;
two players can share one screen as a pair. A real crowd on other machines, servers,
matchmaking and anti-cheat need a server: not built by Studio; offer the local stand-in from `ada-genres`.
**Research:** needs primary research: the source research on battle royale holds one entry, a later one on
anti-cheat. It has no entry for the drop, the closing zone or scavenging weapons from the ground.

## Design defaults

- **players-left**: How many are left is always on screen, and a fall ends on your place: last one
  standing wins. Why: every knockout moves the player up, so even a loss is a ranking. Break it
  when: the match ends on a clock instead of the last one standing.
- **bot-crowd**: Bots land, loot, fight each other and react after a human delay, and the last few
  play harder. Why: one person gets a full match that thins out like a real one. Break it when: two
  friends play only each other on one screen.

## Feel

- **loot-pops**: Loot glints in its rarity's colour, bursts out of a crate with a sound, and is
  picked up by walking over it. Why: the scramble is quick and every find reads at a glance. Break
  it when: there is no loot, and everyone fights with what they started with.
- **heard-first**: Footsteps, shots and opened crates are heard from their direction and fade with
  distance, so a rival is heard before seen. Why: listening is a skill, and an ambush is fair. Break
  it when: the view is from above and shows everything near.
- **final-circle**: As few players remain, the music builds and the zone tightens, so the last fight
  is the loudest. Why: the match rises to its end instead of fading out. Break it when: a calm
  survival match where quiet is the point to the end.

## Feel variants

- **tense**: Tense and careful: few shots, hiding and listening, one mistake ends the run.
- **frantic**: Frantic and loud: lots of loot, fights everywhere, a quick next match.

## Choices that shape the pitch

- **Battle:** shooting on one shared map (default) · melee and dodging, seen from above · each
  player on their own puzzle board, where doing well sends trouble to a rival.
- **Team:** solo (default) · a pair on one screen, reviving each other.
- **Map:** one hand-made island (default) · a new map each match.
- **What the player sees:** behind the player, `chase` (default) · from above, `topdown` · first
  person, `first`.
- **Feeling:** the player feels clutch survival by winning the last fight in the last circle,
  because the zone forced it and every earlier choice of where to go and what to carry led there.

## Later, beyond the first slice

- A real crowd of players on other machines, servers and matchmaking
  → needs a server: not built by Studio; offer the local stand-in from `ada-genres`
- Anti-cheat → needs a server: not built by Studio; offer the local stand-in from `ada-genres`
- Building walls and ramps mid-fight → add it as its own feature milestone
- Squads with pings, revives and respawns → add it as its own feature milestone
- Bots that loot, hide and flank like people → not verified in Studio yet: ask for it after play and the agent will try it without a verified path
- Seasons, a battle pass and a cosmetics shop → not verified in Studio yet: ask for it after play and the agent will try it without a verified path
- Watching the rest of the match after you fall → iterate on it after play, in the same project
- Vehicles to cross the map → not verified in Studio yet: ask for it after play and the agent will try it without a verified path

## In a mashup

Battle royale leads the drop, the zone, the count of who is left and the end of the match. A
shooter leads aiming and weapons. Survival leads hunger and crafting when the user wants
them. A puzzle or arcade game leads the board, and battle royale leads who is left and where the
trouble goes. Extraction leads keeping what you found, when getting out matters more than
being last.

---

Adapted from Donchitos/Claude-Code-Game-Studios (MIT): `.claude/genres/chipsets/battle-royale.md` @ abc0de7. See `NOTICE.md` beside the skills root.
