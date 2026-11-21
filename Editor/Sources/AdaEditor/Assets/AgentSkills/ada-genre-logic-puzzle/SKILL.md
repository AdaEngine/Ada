---
name: ada-genre-logic-puzzle
description: "Pure deduction on a grid of clues, from picture logic to mines. Genre defaults for Ada Studio game builds; matches briefs such as: logic game, nonogram, picross, minesweeper, sudoku, a game like Picross or Minesweeper"
---

# Genre: logic-puzzle
*Part of the genre library: load `ada-genres` for matching, the camera-token legend and online stand-ins; `ada-genres-mashups` when the idea joins genres.*

**Camera:** `static`, the board fits the window.

## Design defaults

- **one-board-graded**: One board solved in minutes, picked from a few difficulties graded by the
  kind of reasoning each needs, not only by its size. Why: the player picks a challenge that fits.
  Break it when: a hand-made run of boards, each teaching one technique.
- **logic-alone**: The solver proves every board can be solved by reasoning alone from the first
  move: a mine board's first click is safe, and no guess is ever needed. Why: a loss is the player's
  slip, never a coin toss. Break it when: a clearly labelled lucky mode.

## Feel

- **mark-what-you-know**: One button fills a cell and another marks it surely empty, a drag marks a
  whole run at once, and cells are big enough to hit easily. Why: the player writes down each
  deduction and builds on it. Break it when: cells take numbers, not marks, and notes are small
  pencil numbers instead.
- **clues-answer**: A clue greys out once its row or region meets it, and a rule broken by your own
  marks, two of one number in a row, shows in red; whether a mark is right stays hidden until the
  board is done. Why: each deduction gets an answer without the game solving it for you. Break it
  when: the user wants a strict mode where nothing answers until the end.
- **undo-marks**: Undo takes marks back one at a time with no limit, restart clears the board, and a
  fatal click on a mine board can be undone once. Why: a slip never ruins a board half solved, so
  the player keeps reasoning. Break it when: a strict mode where a mine ends the board.
- **picture-reveal**: The last right cell finishes the board at once: the picture colours in, or the
  safe cells flip over in a wave, with a chime and the time taken. Why: a board of reasoning ends on
  a beat of payoff. Break it when: boards come back to back in a timed race, and the next one starts
  at once.

## Feel variants

- **relaxed**: Calm and gentle: no timer, broken rules shown in red, a hint on request.
- **strict**: Sharp and strict: a timer and best times, nothing confirmed until the whole board is
  done.

## Choices that shape the pitch

- **The puzzle:** picture logic, number clues on rows and columns (default) · mines, where a number
  counts the hidden mines next to it · number place, each number once per row, column and box · a
  logic grid of who-owns-what clues.
- **Boards:** generated each game and proven by the solver (default) · a hand-made set, each
  teaching one technique · a daily board, the same for everyone.
- **Feeling:** the player feels sharp and independent by proving a cell that no single clue names,
  because two clues together settle it and nothing pointed the way.

## Later, beyond the first slice

- Hints that point to the next deduction without giving it → iterate on it after play, in the same project
- Big boards in parts, and picture logic in colour → grow it across later milestones
- Logic grids told as a whodunit, confirmed in batches → add it as its own feature milestone
- A campaign of hand-made boards → grow it across later milestones
- Mixed rules on one board, or rules that change mid-board → add it as its own feature milestone
- Daily boards with times compared online → needs a server: not built by Studio; offer the local stand-in from `ada-genres`

## In a mashup

Logic leads the board, the clues and the proof that no guess is needed. A mystery or detective half
leads the story, and a logic grid is its deduction, confirmed in batches. An adventure half leads
the world, and boards are its locks. A cozy half leads theme and pace. A roguelike half leads the
run, and what a solved board earns carries over.

---

Adapted from Donchitos/Claude-Code-Game-Studios (MIT): `.claude/genres/chipsets/logic-puzzle.md` @ abc0de7. See `NOTICE.md` beside the skills root.
