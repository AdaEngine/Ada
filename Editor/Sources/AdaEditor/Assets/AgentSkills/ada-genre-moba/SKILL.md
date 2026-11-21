---
name: ada-genre-moba
description: "Two teams of heroes push lanes to destroy the other base. Genre defaults for Ada Studio game builds; matches briefs such as: MOBA, lane pusher, hero brawler, a game like League of Legends or Dota"
---

# Genre: moba
*Part of the genre library: load `ada-genres` for matching, the camera-token legend and online stand-ins; `ada-genres-mashups` when the idea joins genres.*

**Camera:** `strategy`, angled from above and kept on your hero; `topdown` for a flat 2D arena.
**Online:** You play one hero, and bots play your teammates and the other team; two players can
share one screen on gamepads, on the same side or on opposite sides. Two full teams of people on
separate machines, matchmaking, ranks and servers need a server: not built by Studio; offer the local stand-in from `ada-genres`.
**Research:** needs primary research: the source research on MOBAs is about bots, team pings, shared
credit, readable roles and ranked play. It has no entry for lanes, towers, minions or gold for the
last hit.

## Design defaults

- **bot-heroes**: Bots play every other hero at a level picked on the title screen: they push, back
  off when hurt and come to help when called. Why: one person gets a whole match with a team on each
  side. Break it when: two people play one hero each on one screen and want no one else in the
  match.
- **short-match**: Towers and bases fall fast enough that a match fits one short sitting, and it
  ends on each hero's kills, assists and gold. Why: the whole arc of lane, fights and push is played
  in one go, and helpers get credit. Break it when: the user wants the long game, a big map and a
  slow build.

## Feel

- **ability-keys**: A few abilities on fixed keys, each showing its range or shape on the ground
  while aimed and its cooldown on the bar. Why: a hero is learned in a minute, and a miss is the
  player's aim, not a surprise. Break it when: a one-button hero brawler, made for people who have
  never played one.
- **level-in-match**: Every hero starts weak and levels up during the match with a chime, and each
  level makes one ability stronger, the player's pick. Why: the hero grows within minutes, and the
  pick is a plan. Break it when: heroes are fixed and the match is about play alone.
- **ping-the-team**: One key marks a spot or an enemy with a sound for the team, and bot teammates
  come, attack or fall back. Why: the player leads the team without typing. Break it when: there are
  no teammates, a one against one duel.

## Feel variants

- **laning**: Patient and strategic: farm the lane, grow stronger, pick the moment to push.
- **brawler**: Fast and brawly: a short lane, fights from the first seconds, quick respawns.

## Choices that shape the pitch

- **Map:** one lane (default) · three short lanes and woods between them · an arena with a point
  to hold, a hero brawler.
- **Team:** you and bot teammates against bots (default) · two players on one screen on the same
  side · two players on opposite sides.
- **Heroes:** a few heroes who play differently, picked before the match (default) · one hero, the
  same for everyone.
- **Items:** gold buys items at the base (default) · no items, levels
  only.
- **What the player sees:** angled from above, `strategy` (default) · straight down, `topdown`.
- **Feeling:** the player feels ongoing planning by farming a lane and choosing the moment to push,
  because gold and levels grow each wave and the towers show how far the push got.

## Later, beyond the first slice

- Two full teams of people on separate machines → needs a server: not built by Studio; offer the local stand-in from `ada-genres`
- Matchmaking and ranks → needs a server: not built by Studio; offer the local stand-in from `ada-genres`
- A big roster of heroes, each with a full kit → grow it across later milestones
- Bots that play as a team and adapt to the player → not verified in Studio yet: ask for it after play and the agent will try it without a verified path
- Random critical hits that come at a steadier rhythm → iterate on it after play, in the same project
- Neutral monsters in the woods → iterate on it after play, in the same project
- Custom games and a map editor → not verified in Studio yet: ask for it after play and the agent will try it without a verified path

## In a mashup

The MOBA leads the lane, the bots, the match and the gold. An action or fighting half leads how
each hero moves and hits. Tower defense leads the waves and the towers, and the MOBA leads the
hero who walks among them. An RPG leads progression between matches. A shooter leads aiming when
the heroes carry guns, and the MOBA keeps the lane.

---

Adapted from Donchitos/Claude-Code-Game-Studios (MIT): `.claude/genres/chipsets/moba.md` @ abc0de7. See `NOTICE.md` beside the skills root.
