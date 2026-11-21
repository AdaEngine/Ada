---
name: ada-genre-mmo
description: "A persistent world shared by many players at once. Genre defaults for Ada Studio game builds; matches briefs such as: MMORPG, online world, live service, a game like World of Warcraft or RuneScape"
---

# Genre: mmo
*Part of the genre library: load `ada-genres` for matching, the camera-token legend and online stand-ins; `ada-genres-mashups` when the idea joins genres.*

A first slice cannot be an MMO: it has no server and no other players. It shows a tiny slice of a
shared world instead: a town and the fields around it, bot players walking, fighting and
chatting, and your character saved on this machine. The design document says so.

**Camera:** `orbit`, behind your character; `strategy`, angled from above with click to move, for
an old-school world.
**Online:** Bot players stand in for the crowd, all on this machine, and the character is saved
locally. Servers, a real shared world, accounts, chat and trading between people
need a server: not built by Studio; offer the local stand-in from `ada-genres`.
**Research:** needs primary research: the source research on MMOs is about servers, economies and live
play, which no first slice runs. It has no entry for what one machine can hold of an MMO: a town full
of other players, or an ability bar with cooldowns.

## Design defaults

- **busy-town**: A town hub where named bot players walk about, fight in the nearby fields, stand at
  the forge and post in a chat box, each marked as a bot. Why: the world feels shared even with
  nobody else there. Break it when: the user wants a lonely world, the last player left.
- **quest-board**: A few short quests from a board or a quest giver, each with a marker on the map
  and a tracker on screen: defeat, gather, deliver. Why: there is always a next thing nearby, and a
  quest done is a place to stop. Break it when: a sandbox world where players set their own goals.
- **saved-character**: Your character, level and bag are saved on this machine after every quest and
  on leaving, and the next visit starts where you left. Why: the world keeps your progress, even
  with no server. Break it when: it is a demo of one evening, and nothing should carry over.

## Feel

- **level-up-ding**: Experience fills from every fight and quest, any extra carries into the next
  level, and a level-up rings out with a glow over the character. Why: progress is felt often, and
  nothing earned is wasted. Break it when: there are no levels, and gear or skill alone makes the
  character stronger.
- **loot-shows**: Drops glint in a colour by rarity, a rare one has its own sound, and worn gear
  changes how the character looks. Why: a good find is noticed at once and shown off in town. Break
  it when: the character's look is fixed, a story hero with one outfit.
- **hotbar**: Abilities sit on a bar of keys, each with a cooldown that sweeps round as it
  recharges. Why: a fight is a rhythm of choices, and the bar shows what is ready. Break it when:
  combat is one attack key, an action game in a shared world.

## Feel variants

- **questing**: Steady questing: quests, levels and gear, with the next zone opening as you grow.
- **skilling**: Calm skills: chop, mine, fish and craft, each skill levelling on its own at an easy
  pace.

## Choices that shape the pitch

- **World:** a town and the fields around it (default) · a town and one short dungeon with a bot
  party · a small island of gathering and crafting.
- **Progression:** levels and gear from quests (default) · skills that level by doing them ·
  standing with a faction.
- **Others:** bot players in town and in the fields (default) · a bot party for a dungeon, one who
  tanks, one who heals, and you · a market where bots buy and sell.
- **What the player sees:** behind the character, `orbit` (default) · angled from above with
  click to move, `strategy`.
- **Feeling:** the player feels ongoing planning by finishing a quest just as the next level and the
  next quest come into reach, because short and long goals overlap.

## Later, beyond the first slice

- A real shared world: servers, accounts and chat → needs a server: not built by Studio; offer the local stand-in from `ada-genres`
- Trading and a market between people, with safe item transfers
  → needs a server: not built by Studio; offer the local stand-in from `ada-genres`
- Guilds, groups and raids with other people → needs a server: not built by Studio; offer the local stand-in from `ada-genres`
- Many zones, quest chains and dungeons → grow it across later milestones
- A long-run economy that stays in balance → grow it across later milestones
- Subscriptions, a shop or a battle pass → not verified in Studio yet: ask for it after play and the agent will try it without a verified path
- Seasons and fresh starts → not verified in Studio yet: ask for it after play and the agent will try it without a verified path
- A rested bonus after time away → iterate on it after play, in the same project
- Protection from long runs of bad luck on rare drops → iterate on it after play, in the same project

## In a mashup

The MMO leads the shared world: the town, the bot players, the quests and the save. An RPG leads
combat rules and builds. A crafting or management half leads gathering and the market. Survival
leads hunger and shelter. Extraction leads what is lost on death, when the world has dangerous
zones.

---

Adapted from Donchitos/Claude-Code-Game-Studios (MIT): `.claude/genres/chipsets/mmo.md` @ abc0de7. See `NOTICE.md` beside the skills root.
