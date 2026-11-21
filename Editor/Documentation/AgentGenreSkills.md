# Genre skills for game-building agents

Ada Studio bundles a genre knowledge library for the agents that build games
(the workflows described in the [agent catalog](AgentCatalog.md)). When a brief
names or implies a genre — "a platformer like Celeste", "a cozy farming game",
"bullet hell" — the agent matches it to one of 69 genre skills and applies that
genre's tested defaults instead of improvising them.

Each genre skill is a compact sheet:

- **Camera** — the view the genre's players expect (side view, top-down, orbit
  behind the character, strategy pan-and-zoom, first person, and so on), mapped
  to the engine's camera components.
- **Design defaults** — the rules a player of the genre assumes: instant
  retries in a platformer, visible waves and lives in a tower defense, a saved
  character in an MMO slice. Every default carries its reason and when to
  break it.
- **Feel rules** — the small behaviors that make the genre feel right: coyote
  time and jump buffering, honest hitboxes, placement previews, wave pauses.
- **First-slice scope** — what belongs in the first playable version and what
  deliberately waits for later milestones, including a minimum enemy variety
  floor for combat genres (marked as a hypothesis, not a measurement).
- **Mashup role** — which systems this genre leads when the idea combines two
  genres, settled per system (input and camera, death, economy, rules,
  enemies, structure) rather than by one genre running everything.

The router skill `ada-genres` matches a brief to one of the 69 genre skills
and carries the shared reference tables: the camera-token legend and the
online stand-in levels described below. Two more shared skills complete the
library: `ada-genres-mashups` for combining genres, and
`ada-genres-art-direction` for writing a per-game art direction (mood, camera
and scale, shapes, values, palette, detail, rules and one signature detail)
instead of picking a style off a list.

## How agents use it

No setup is needed. The bundled `ada-game-builder` and `ada-autonomous-studio`
workflows load the genre library automatically when a brief names or implies a
genre. Discovery goes through the same `editor.skills.list` /
`editor.skills.read` tools as the other bundled workflows, on desktop, mobile
and the browser shell. The chosen genre and its key defaults are recorded in
the project's design notes, so later sessions keep them.

The genre list covers action (platformer, metroidvania, shooters, fighting,
soulslike), roguelikes and roguelites, strategy and management (RTS, tower
defense, city builder, tycoon, colony sim), puzzles of many kinds, racing and
sports, simulations (farming, fishing, flight, sailing), narrative genres
(visual novel, detective, walking sim), party and word games, and
online-flavored genres (MMO, MOBA, battle royale, co-op).

## Online play: what gets built

Studio builds local games; nothing runs over a network. When a brief asks for
online play, the agent names the level in the design document and builds a
local stand-in, saying so in plain words: a daily seed and local leaderboard
for asynchronous play, bots named as bots for session or competitive play, and
bot players with a locally saved character for a persistent-world slice. A
stand-in shows whether the idea is fun; it never proves the game would hold up
over a network. VR has no verified path and is built flat-screen. Console
ports go through the platform holders' programs.

## Limits

- The sheets are a curated reading of each genre's best-received games, not
  measurements; the words in your brief always win over a sheet.
- Genre defaults guide the agent's choices; they do not add engine features.
  A sheet's "later" lines mark what is grown after the first playable slice,
  and anything needing a server is not built.
- The library is a snapshot of the upstream source at import time; it does not
  track later upstream changes.

## Attribution

The genre library is adapted from
[Claude-Code-Game-Studios](https://github.com/Donchitos/Claude-Code-Game-Studios)
by Donchitos, licensed under the MIT License. The full license text ships in
`NOTICE.md` beside the bundled skills, and every genre skill carries an
attribution footer.
