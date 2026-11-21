---
name: ada-genre-extraction
description: "Go in, grab loot and get out alive; die and lose what you carried. Genre defaults for Ada Studio game builds; matches briefs such as: extraction shooter, full-loot PvP, raid, a game like Escape from Tarkov, Hunt Showdown or Dark and Darker"
---

# Genre: extraction
*Part of the genre library: load `ada-genres` for matching, the camera-token legend and online stand-ins; `ada-genres-mashups` when the idea joins genres.*

**Camera:** `first` for an extraction shooter; `topdown` for a raid seen from above; `chase`
behind the player.
**Online:** Bots play the other raiders: they loot, fight and head for the exits too, and are
named as bots; two players can raid as a pair on one screen. Raids with real players, servers,
matchmaking, safe item records and anti-cheat need a server: not built by Studio; offer the local stand-in from `ada-genres`.
**Research:** needs primary research: the source research has about nine extraction entries, on what death
loses, greed, the stash and safe trades between people. It has no entry for the raid as one machine
holds it: the exits, the raid clock and the map.

## Design defaults

- **know-the-stakes**: Before each raid the screen says what you could lose: everything in the bag
  goes on death, and one small safe pocket keeps a single item. Why: the risk is understood before
  it is taken, so a loss feels fair. Break it when: a gentle version where death keeps half the bag,
  as the user asked.
- **stash-between**: Between raids a stash shows what came home; selling finds buys better gear for
  the next raid, and the stash is saved. Why: a good raid makes the next one stronger, and a bad one
  stings. Break it when: one raid is the whole game, scored and done.
- **bot-raiders**: Bot raiders search the same map, react after a human delay, and fight each other
  as well as you. Why: one person feels the threat of other players. Break it when: a co-op raid
  against monsters only, with no rival raiders.

## Feel

- **bag-value**: The bag's worth is on screen and climbs with every pickup, so each extra room is a
  choice to stay or go. Why: greed is a decision the player sees themselves make. Break it when:
  loot has no price, and the raid is for one named item.
- **escape-turn**: Heading for an exit, or with the raid clock low, the music turns and the pace
  rises. Why: the way out feels different from the search, and the last stretch is the tensest.
  Break it when: the raid is quiet to the end on purpose, a slow horror crawl.
- **heard-first**: Footsteps, doors and shots carry by direction and fade through walls, so a rival
  is heard before seen. Why: listening is how a raider survives, and an ambush is fair. Break it
  when: the view is from above and shows every rival near.

## Feel variants

- **grim**: Tense and grim: slow steps, hard hits, every fight a risk to the whole bag.
- **heist**: A quick heist: a small map, loud loot, a dash for the exit.
- **dungeon**: A dungeon raid: swords and spells, monsters as well as raiders, a portal out.

## Choices that shape the pitch

- **Stakes:** lose the bag, keep one safe item (default) · lose half the bag · lose the gear you
  brought in too.
- **Threat:** bot raiders and monsters (default) · monsters only, a co-op raid with a friend on
  one screen · bot raiders only.
- **Between raids:** a stash and a trader (default) · no stash, a score for each raid.
- **What the player sees:** first person, `first` (default) · from above, `topdown` · behind the
  player, `chase`.
- **Feeling:** the player feels clutch survival by reaching the exit with a full bag and a rival
  close behind, because the bag's worth was in view all along and they chose to stay one room
  longer.

## Later, beyond the first slice

- Raids with real players, servers and matchmaking → needs a server: not built by Studio; offer the local stand-in from `ada-genres`
- Safe item records and trades between people
  → needs a server: not built by Studio; offer the local stand-in from `ada-genres`
- Anti-cheat → needs a server: not built by Studio; offer the local stand-in from `ada-genres`
- Seasons that wipe every stash → needs a server: not built by Studio; offer the local stand-in from `ada-genres`
- Insurance that returns lost gear → iterate on it after play, in the same project
- A grid bag where items must fit by shape → iterate on it after play, in the same project
- Gear that wears down and costs to repair → iterate on it after play, in the same project
- A hideout to upgrade between raids → add it as its own feature milestone
- Raiders that hunt by sound and flank → not verified in Studio yet: ask for it after play and the agent will try it without a verified path

## In a mashup

Extraction leads what is secured or lost, the exits and the stash. A shooter leads combat. An RPG
and an economy lead what gear is worth and how it is replaced. A survival half leads hunger and
healing in the raid. A dungeon crawler leads monsters and the map, and extraction leads getting out
alive.

---

Adapted from Donchitos/Claude-Code-Game-Studios (MIT): `.claude/genres/chipsets/extraction.md` @ abc0de7. See `NOTICE.md` beside the skills root.
