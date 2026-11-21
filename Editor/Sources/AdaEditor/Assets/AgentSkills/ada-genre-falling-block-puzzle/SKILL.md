---
name: ada-genre-falling-block-puzzle
description: "Falling pieces placed so rows or groups clear before the stack tops out. Genre defaults for Ada Studio game builds; matches briefs such as: tile matching, match-three, falling blocks, casual puzzle, a game like Tetris, Puyo Puyo or Bejeweled"
---

# Genre: falling-block-puzzle
*Part of the genre library: load `ada-genres` for matching, the camera-token legend and online stand-ins; `ada-genres-mashups` when the idea joins genres.*

**Camera:** `static`, the well or the board fits the window.
**Research:** needs primary research: the source research has no falling-block or match entry, only general
input, chain and luck entries. It has no entry for topping out as the speed rises, lock delay with a
ghost piece, or the bonus for clearing several rows at once.

## Design defaults

- **next-and-fair**: The next piece shows beside the well, and pieces are dealt so the same shape
  seldom comes twice running and none stays missing for long. Why: the player plans one piece ahead,
  and a drought never decides the run. Break it when: the board refills from above, a swap game with
  nothing to preview.

## Feel

- **sharp-shift**: A tap moves a piece one column, a held key slides it fast after a short pause, a
  turn is instant, and a turn pressed just before a piece appears is kept. Why: the hands keep up
  with the head at any speed. Break it when: one tap places a piece, a slow casual game played with
  the mouse.
- **clear-beat**: Cleared rows flash and hold for a beat before the stack drops with a thud; in a
  chain each step plays in its real order, louder than the last, on top of the starter's rising
  pitch. Why: the player watches the payoff they set up. Break it when: speed is everything, a mode
  where clears vanish at once.

## Feel variants

- **classic**: Tight and arcade: falling shapes, quick hard drops, a speed that climbs to a frantic
  end.
- **chain**: Chain builder: coloured blobs that pop in groups of one colour, and setting up a
  cascade of pops is the skill.
- **calm**: Calm and endless: nothing falls and no clock runs, two gems swap on a board that
  refills, and matches cascade on their own.

## Choices that shape the pitch

- **The pieces:** shapes of four squares that clear full rows (default) · coloured blobs that
  pop in groups of a colour · gems swapped to make rows of three, on a board that refills.
- **Stakes:** an endless run until the stack tops out, for a best score (default) · a sprint to
  clear a set number of lines fast · a set number of moves to reach a score.
- **Opponent:** none (default) · a bot whose clears push rows of rubbish up into your well · two
  players on one keyboard, each clear sending rubbish to the other.
- **Feeling:** the player feels a clutch rescue by clearing a tall stack just below the top, because
  the danger was plain and one big clear turned the run.

## Later, beyond the first slice

- A hold slot that keeps one piece for later → iterate on it after play, in the same project
- Spins and other trick clears scored as specials → iterate on it after play, in the same project
- Boosters and special gems in a swap game → add it as its own feature milestone
- Hand-made puzzle boards to clear in few moves → grow it across later milestones
- A daily challenge with a small reward → iterate on it after play, in the same project
- Online versus and ranked play → needs a server: not built by Studio; offer the local stand-in from `ada-genres`

## In a mashup

The falling-block puzzle leads the well, the input, the deal and the clear. A battle or RPG half
leads damage and enemies, and each clear sends an attack. A story half leads what happens between
rounds. A versus half leads the match, and rubbish rows are the attack. A rhythm half leads the
beat, and pieces fall on it.

---

Adapted from Donchitos/Claude-Code-Game-Studios (MIT): `.claude/genres/chipsets/falling-block-puzzle.md` @ abc0de7. See `NOTICE.md` beside the skills root.
