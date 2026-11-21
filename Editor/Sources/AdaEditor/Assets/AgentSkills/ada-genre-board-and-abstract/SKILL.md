---
name: ada-genre-board-and-abstract
description: "Chess, go and other board games, with an AI opponent. Genre defaults for Ada Studio game builds; matches briefs such as: board game, chess, checkers, classic card games like solitaire or poker, a game like Chess, Go or Catan"
---

# Genre: board-and-abstract
*Part of the genre library: load `ada-genres` for matching, the camera-token legend and online stand-ins; `ada-genres-mashups` when the idea joins genres.*

A first slice is one full game against the AI, or one deal of a solo card game.

**Camera:** `static`, the board or table filling the window; `fixed` for a 3D board on a table.
**Research:** needs primary research: the source research has no row for board, table or abstract games,
only nearby card-game entries on scoring, stakes and bluffing. It has no entry for lighting a
piece's legal moves, taking a move back against the AI, or an AI that plays at the player's level.

## Design defaults

None yet: the source research (upstream) has no entry for this genre's staples (see Research).

## Feel

- **read-the-board**: The AI moves after a short, steady pause, its move stays marked until you have
  moved, and a key lights your pieces under attack and the places it threatens. Why: the player sees
  what changed and what is coming, so a loss is a misread they could have seen. Break it when: an
  expert game with every aid off.
- **piece-snap**: A held piece lifts with a shadow, a drop a little off still lands in the nearest
  legal place with a click, and a capture knocks the taken piece aside with a heavier sound. Why:
  moving a piece feels like the real thing, and a sloppy drop is never a wrong move. Break it when:
  moves are typed or picked from a list.
- **count-up**: Where the game scores, the count plays out one item at a time, each a step higher in
  pitch on top of the starter's pitch variation, and a solitaire's last cards fly home in a rising
  run. Why: the total builds where the player can follow it. Break it when: nothing is counted, a
  game won by one position, as chess is by checkmate.
- **game-end**: The end is shown on the board: the winning line lit or the beaten king tipped over,
  a short fanfare, then a rematch on one key. Why: the win lands, and the next game is a key away.
  Break it when: an endless solo game that never ends.

## Feel variants

- **classic**: Classic and deep: a known game at full size, a strong AI, time to think.
- **luck**: Luck and nerve: dice or a shuffled deck, the odds shown, a bet or a bluff.
- **calm**: Calm and solo: a patience game with no opponent and no clock, each move putting a little
  more in order.

## Choices that shape the pitch

- **The game:** a known game played by its rules, chess, draughts or reversi (default) · a new
  abstract game with a few simple rules · a classic card game, solitaire or poker.
- **Opponent:** an AI at a level the player picks, that makes small human mistakes (default) · no
  opponent, a solo game · two players taking turns on one device.
- **Luck:** none, a game of pure skill (default) · dice with the odds shown · hidden cards and bets.
- **What the player sees:** the board from above, `static` (default) · a 3D board on a table,
  `fixed`.
- **Feeling:** the player feels clever by seeing a few moves ahead and watching the plan work,
  because the board showed every threat and the AI played fair.

## Later, beyond the first slice

- Online play and a rating → needs a server: not built by Studio; offer the local stand-in from `ada-genres`
- A book of set positions to solve → grow it across later milestones
- A hint that names the best move, and a review of the game after → iterate on it after play, in the same project
- A clock for each side → iterate on it after play, in the same project
- Variants and house rules → iterate on it after play, in the same project
- Rule-changing rewards for a master of the game → iterate on it after play, in the same project
- An opening book and endgame tables for a strong AI → add it as its own feature milestone
- A board game inside a bigger game, found while exploring → add it as its own feature milestone

## In a mashup

The board game leads the rules, the turn and the AI's move. A puzzle leads set positions with one
answer, and the board leads how they are played. An RPG or adventure half leads the world, and the
board game is found in it. A roguelike leads a run of games, with pieces won between them. A card
battler leads a duel of built decks, and the board leads the table.

---

Adapted from Donchitos/Claude-Code-Game-Studios (MIT): `.claude/genres/chipsets/board-and-abstract.md` @ abc0de7. See `NOTICE.md` beside the skills root.
