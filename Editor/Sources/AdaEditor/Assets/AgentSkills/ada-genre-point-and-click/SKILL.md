---
name: ada-genre-point-and-click
description: "Explore drawn scenes, click items, solve puzzles to move the story on. Genre defaults for Ada Studio game builds; matches briefs such as: graphic adventure, adventure game, escape room, exploration puzzle adventure, a game like Monkey Island, Myst or Machinarium"
---

# Genre: point-and-click
*Part of the genre library: load `ada-genres` for matching, the camera-token legend and online stand-ins; `ada-genres-mashups` when the idea joins genres.*

There is no tested way to build large authored content yet: a first slice is a few drawn screens and one chain
of puzzles, each proved solvable.

**Camera:** `static`, one drawn screen at a time; `follow2d` for a wide scene that scrolls,
`first` for a Myst-like place seen from your own eyes.

## Design defaults

- **items-and-locks**: Items you pick up wait in a bar along the bottom, to use on the scene or on
  each other, and every lock (a door, a guard, a machine) is seen before the thing that opens it.
  Why: the player knows what a find is for the moment they find it. Break it when: the puzzles are
  all in the scene, levers and codes, as in a Myst-like or an escape room.
- **hints-on-ask**: A Hint button gives a small nudge first, then a bigger one, never the answer at
  once. Why: no one quits for a walkthrough, and the idea stays theirs. Break it when: the user
  wants it hard and pure, with no help.

## Feel

- **show-hotspots**: The cursor changes over anything you can use, hotspots are generous, and one
  key briefly lights up everything you can click. Why: the puzzle is in the thinking, never in
  hunting for pixels. Break it when: finding the hidden thing is the puzzle, a hidden-object game.
- **every-click-answers**: Click a thing to use it, right click or a Look key to hear what the hero
  thinks of it, and a wrong try gets its own line, often a joke. Why: every try teaches or amuses,
  and nothing meets silence. Break it when: the hero never speaks, a wordless game that shows
  thoughts in pictures.
- **eureka-plays-out**: When the right thing meets the right lock, it plays out at once with a sound
  and a short animation, and the solved step never has to be done again. Why: the idea is the
  reward, so it lands loud and costs nothing to carry out. Break it when: carrying out the plan is
  the challenge, a timed escape.
- **never-stuck**: No death and no dead end: an item the story needs cannot be lost or used up, and
  a double click on an exit goes straight to the next screen. Why: a stuck player is thinking, never
  doomed, and never walks the same path twice. Break it when: the user wants old-school deaths;
  then a death restarts the screen at once.

## Feel variants

- **comic**: Talky and comic: characters to chat with, odd item combinations, a joke for every wrong
  try.
- **mysterious**: Quiet and strange: alone in an odd place, machines and codes built into the scene,
  few words, clues in the walls.

## Choices that shape the pitch

- **Puzzles:** items used on the scene and on each other (default) · machines and codes in the
  scene, a Myst-like exploration puzzle adventure · one locked room to escape against a clock, an
  escape room.
- **Talk:** a few characters who help when asked about things (default) · no one to talk to, a
  lone explorer · talk is the puzzle, the right line to the right person.
- **Failure:** none, you cannot die or get stuck (default) · deaths that restart the screen at
  once, the old style.
- **What the player sees:** drawn screens, `static` (default) · a wide scene that scrolls,
  `follow2d` · a 3D place seen from your own eyes, `first`.
- **Feeling:** the player feels the eureka of using the right thing on the lock they saw first,
  because the answer was in plain view all along.

## Later, beyond the first slice

- Many screens and a long puzzle chain → grow it across later milestones
- Conversations whose choices change the story → add it as its own feature milestone
- Several ways past the same lock → add it as its own feature milestone
- A list of verbs (push, pull, talk to) → iterate on it after play, in the same project
- A story that turns midway into a different problem → add it as its own feature milestone
- A world whose walls hide a language you learn to read → add it as its own feature milestone
- Switching between a few heroes → iterate on it after play, in the same project

## In a mashup

Point-and-click leads the scenes, the items and the hints. A puzzle half leads the rules and proves
each puzzle can be solved. A visual novel leads the conversations. A detective half leads the
evidence and what counts as solved. An action half leads its fights, and a lost fight sends you back
to the screen, never to a dead end.

---

Adapted from Donchitos/Claude-Code-Game-Studios (MIT): `.claude/genres/chipsets/point-and-click.md` @ abc0de7. See `NOTICE.md` beside the skills root.
