---
name: ada-genre-fighting
description: "Head to head with a move set, life bars and rounds. Genre defaults for Ada Studio game builds; matches briefs such as: versus fighter, platform fighter, a game like Street Fighter, Tekken or Smash Bros"
---

# Genre: fighting
*Part of the genre library: load `ada-genres` for matching, the camera-token legend and online stand-ins; `ada-genres-mashups` when the idea joins genres.*

**Camera:** `static`, one stage that fits the window; `follow2d` for a wider stage, kept on both
**First-slice variety floor (hypothesis, not measured):** at least 1 enemy kinds, each attacking or moving differently; bosses and elites count. The brief's features list wins if it asks for more.
fighters; `fixed` for a 3D fighter seen from the side.

## Design defaults

- **rounds-and-bars**: Mirrored health bars in the top corners with a round timer between them, best
  of three rounds, then a winner screen. Why: the state of the fight reads at a glance, and a lost
  round is not a lost match. Break it when: a platform fighter, where damage builds up and a fall
  off the stage decides.
- **cpu-rival**: The computer fights at a level picked on the title screen: it reacts after a short,
  human delay, blocks some of the time and never reads a press before it happens. Why: a rival that
  can be beaten and still feels like a person. Break it when: the game is for two players only, on
  one keyboard or two gamepads.
- **move-list**: The pause screen lists each fighter's moves and keys, and every special also has a
  one-key shortcut. Why: a new player finds and throws the special in the first round. Break it
  when: every move is already one key, a party brawler with nothing to look up.

## Feel

- **light-and-heavy**: A light attack comes out at once; a heavy winds up, commits you and hits
  hard; every press shows its pose straight away. Why: the choice between quick and safe or slow and
  strong is felt in the hands. Break it when: everyone shares one simple attack, a party game for
  people who never played a fighter.
- **forgiving-inputs**: A special is a short direction-then-button motion that forgives small slips,
  and a press made just before a move ends comes out the moment it ends. Why: the move the player
  meant is the move they get. Break it when: specials are one direction and one key, as in Smash
  Bros, with no motions to learn.
- **face-and-block**: Fighters always turn to face each other; holding away blocks with a solid
  guard sound and a small slide back, and a blocked heavy leaves its user open for a moment. Why:
  defence is a choice from the first exchange, and a careless heavy costs. Break it when: fighters
  roam an open arena and dodge instead of facing off.

## Feel variants

- **combo**: Fast and combo-heavy: quick walks, short moves, light into heavy into special.
- **heavy**: Heavy and deliberate: slow, big blows that commit, a few clean hits win a round.
- **duel**: A duel of counters: a well-timed block turns into a counter and breaks the other's
  guard.

## Choices that shape the pitch

- **Format:** one on one on a flat stage, bars and rounds (default) · a platform fighter where hits
  build knockback and a fall off the stage loses a life · a weapon duel where a few clean hits win.
- **Opponent:** the computer (default) · a friend on the same keyboard or a gamepad · a ladder of
  computer rivals fought in turn.
- **Fighters:** two who play differently, picked on a select screen (default) · the same fighter on
  both sides.
- **What the player sees:** side view in 2D, `static` (default) · 3D from the side, `fixed`,
  with a sidestep.
- **Feeling:** the player feels sharp mastery by blocking a heavy and punishing it, because the
  opening was readable and the counter came out on the press.

## Later, beyond the first slice

- Online versus with rollback → needs a server: not built by Studio; offer the local stand-in from `ada-genres`
- Ranked ladders and matchmaking
  → needs a server: not built by Studio; offer the local stand-in from `ada-genres`
- A big roster of fighters → grow it across later milestones
- A super meter that fills as you fight → iterate on it after play, in the same project
- A training mode with an input display → iterate on it after play, in the same project
- Long combos, juggles and cancels → add it as its own feature milestone
- An arcade ladder with a story for each fighter → grow it across later milestones

## In a mashup

Fighting leads the duel: moves, blocking, inputs and rounds. Sports leads scoring and the field, and
fighting leads command input, recovery and defence, kept the same for both sides. A beat 'em up
leads the crowd and the stage, and fighting leads a boss duel. An RPG leads progression between
fights. Rhythm leads timing, and inputs are never delayed to land on the beat.

---

Adapted from Donchitos/Claude-Code-Game-Studios (MIT): `.claude/genres/chipsets/fighting.md` @ abc0de7. See `NOTICE.md` beside the skills root.
