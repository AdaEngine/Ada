---
name: ada-genre-sailing
description: "Sail a ship with the wind, explore the sea and fight other ships. Genre defaults for Ada Studio game builds; matches briefs such as: naval combat, pirate ships, boats, a game like Sea of Thieves or Sid Meier's Pirates!"
---

# Genre: sailing
*Part of the genre library: load `ada-genres` for matching, the camera-token legend and online stand-ins; `ada-genres-mashups` when the idea joins genres.*

There is no tested way to build a real sea simulation yet: a first slice ship turns, speeds and slows from
simple rules of its own, one wind and a sail setting, never a simulation of waves or buoyancy.

**Camera:** `chase`, behind and above the ship; `topdown` for a sea seen from above.
**Research:** needs primary research: the source research has four sailing entries, all from Sea of Thieves
and Black Flag, on water, waves, flooding and how the wind shapes a chase. It has no entry for
broadside cannons, sails as the throttle, or a goal for the voyage.

## Design defaults

- **sink-to-port**: Hits make leaks that slowly fill the ship and can be patched; a ship that sinks
  washes up at the last port with its cargo lost, not the game. Why: a lost fight costs a haul,
  never the voyage. Break it when: one ship and one life, a hard run.

## Feel

- **read-the-wind**: One wind blows, shown by a flag, an arrow and the sails filling; across it is
  fastest, and straight into it the ship slows to a crawl. Why: the sea has a rule the player can
  read and use. Break it when: a motor boat, where the wind is only weather.
- **ship-on-swell**: The ship rolls and pitches on the swell, spray rises at the bow with speed, and
  a wake trails behind. Why: speed and weight are felt without a number on screen. Break it when: a
  flat sea seen from above, where the wake alone shows speed.

## Feel variants

- **voyage**: Calm voyage: a wide sea, islands to find, rare fights, the wind the only clock.
- **battle**: Heavy and tactical: slow ships, broadsides traded at close range, a duel won by
  position and the wind.
- **nimble**: Light and nimble: a small fast boat, quick turns through the wind, races round buoys.

## Choices that shape the pitch

- **What you do:** sail between islands to find treasure (default) · fight other ships with
  broadsides · trade cargo between ports for profit · race round buoys.
- **Stakes:** a sunk ship washes up at port with its cargo lost (default) · one ship, and
  sinking ends it · no fighting, a calm voyage.
- **Crew:** you sail alone (default) · two players on one screen, one steers and one fires.
- **What the player sees:** behind the ship, `chase` (default) · from above, `topdown`.
- **Feeling:** the player feels seamanship by catching the wind to close on a fleeing ship and
  turning to fire, because the wind's rule was theirs to learn.

## Later, beyond the first slice

- Real waves and buoyancy, ships that flood and list → not verified in Studio yet: ask for it after play and the agent will try it without a verified path
- Waves that hide ships and spoil aim → not verified in Studio yet: ask for it after play and the agent will try it without a verified path
- Rival ships that sail, chase and flee on their own → not verified in Studio yet: ask for it after play and the agent will try it without a verified path
- A crew of players sharing jobs in a storm → needs a server: not built by Studio; offer the local stand-in from `ada-genres`
- Trade between ports with changing prices → add it as its own feature milestone
- Storms and a wind that changes → iterate on it after play, in the same project
- Boarding fights on deck → add it as its own feature milestone

## In a mashup

Sailing leads the ship, the wind and the sea. A trading half leads prices and cargo, and sailing is
the trip between ports. An action-adventure half leads the islands on foot. A fishing half leads the
catch, and sailing reaches the spots. A naval strategy half leads fleets and turns, and sailing
gives each ship its handling.

---

Adapted from Donchitos/Claude-Code-Game-Studios (MIT): `.claude/genres/chipsets/sailing.md` @ abc0de7. See `NOTICE.md` beside the skills root.
