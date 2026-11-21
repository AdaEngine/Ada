---
name: ada-genre-roguelike-deckbuilder
description: "Build a deck from rewards on a generated map; death ends the run. Genre defaults for Ada Studio game builds; matches briefs such as: deckbuilder, dice-builder, a game like Slay the Spire, Balatro or Monster Train"
---

# Genre: roguelike-deckbuilder
*Part of the genre library: load `ada-genres` for matching, the camera-token legend and online stand-ins; `ada-genres-mashups` when the idea joins genres.*

A run that builds a deck card by card on the way up a generated map; the design document battler is a duel
between two decks built beforehand. A first slice is one short run: a few floors and a boss.

**Camera:** `static`, the fight seen from the player's side; `fixed` for cards on a 3D table.
**First-slice variety floor (hypothesis, not measured):** at least 4 enemy kinds, each attacking or moving differently; bosses and elites count. The brief's features list wins if it asks for more.

## Design defaults

- **small-start**: You start with a small deck of plain attacks and blocks and the same energy every
  turn; each turn draws a fresh hand, and the draw and discard piles show their counts. Why: every
  card added later is felt, and the player sees what is left to draw. Break it when: a scoring run
  that plays hands from a full standard deck.
- **pick-or-skip**: After each fight, take one of a few cards or skip them all, and a shop or a rest
  can remove a card. Why: the deck gets sharper, not only bigger, and a lean deck can win. Break it
  when: the deck is fixed and the run grows only through relics.
- **branching-map**: A generated map of fights, a few harder fights, events, rests and a shop, with
  the path picked by the player and a boss at the top. Why: the route is a plan: risk a hard fight
  for a better reward, or rest. Break it when: one ladder of fights in a row.

## Feel

- **intent-shown**: Each enemy shows what it will do next turn, and for how much: an attack, a block
  or a buff, and the damage shown already counts your block. Why: each turn is a puzzle to solve,
  and a loss is the player's misread. Break it when: surprise is the point, a gamble every turn.
- **play-in-order**: A card played flies to its target, and its effects resolve one at a time in the
  order they happen; the enemy turn and long chains speed up on a key. Why: the player sees why each
  number changed. Break it when: a speed run where cards resolve at once on purpose.
- **rising-count**: Damage and score count up one hit or trigger at a time, each step higher in
  pitch on top of the starter's pitch variation, and a kill or a beaten target lands with a burst.
  Why: a good turn builds, and the big total feels earned. Break it when: every card does one plain
  thing and nothing chains.
- **hand-feel**: The hand fans out, a card under the pointer lifts and explains its keywords, it is
  dragged onto its target along an arrow, and a card that cannot be played says why. Why: cards feel
  like things in the hand, and a mistake is caught before it happens. Break it when: cards are
  picked from a plain list, on purpose.

## Feel variants

- **fights**: Fights: enemies with intents, block against damage, a boss at the top.
- **score**: Score chase: hands played for a target that rises each round, jokers that multiply, a
  shop between rounds.
- **dice**: Dice: rolled dice placed into the design documents' slots, and luck shaped by what is on the faces.

## Choices that shape the pitch

- **What a fight is:** a few enemies with intents, beaten turn by turn (default) · a hand scored
  against a target, no enemy · units placed on lanes that fight on their own.
- **Rewards:** a card from a few, or skip (default) · relics that change the rules · upgrading a
  card already held.
- **Stakes:** death ends the run, and a new run is a new map (default) · a few lives across the run
  · cards unlocked for later runs.
- **What the player sees:** the fight from the player's side, `static` (default) · cards on a 3D
  table, `fixed`.
- **Feeling:** the player feels clever by winning with a deck they trimmed, because they skipped
  weak rewards and the winning turn played out in order.

## Later, beyond the first slice

- Several characters, each with its own cards → grow it across later milestones
- Written events with choices → add it as its own feature milestone
- Harder levels opened by a win → iterate on it after play, in the same project
- Card upgrades at rests → iterate on it after play, in the same project
- Cards exhausted for the fight, apart from removal → iterate on it after play, in the same project
- Potions and other one-use items → iterate on it after play, in the same project
- Cards and relics unlocked over many runs → grow it across later milestones
- Daily seeded runs shared online → needs a server: not built by Studio; offer the local stand-in from `ada-genres`

## In a mashup

The deckbuilder leads the run and the deck: rewards, removal and the draw. A card battler leads a
duel between two built decks. Tactics leads a board of positions and pushes, and the design documents are the
moves. An action roguelite leads real-time fights, and cards become the rewards. An RPG half leads
the world, and cards are found in it.

---

Adapted from Donchitos/Claude-Code-Game-Studios (MIT): `.claude/genres/chipsets/roguelike-deckbuilder.md` @ abc0de7. See `NOTICE.md` beside the skills root.
