---
name: ada-genre-arcade-classic
description: "A single-screen arcade game played for a high score. Genre defaults for Ada Studio game builds; matches briefs such as: arcade, score attack, snake, maze chase, breakout, block breaker, asteroids, invaders, a growth game, a game like Pac-Man, Snake or Breakout"
---

# Genre: arcade-classic
*Part of the genre library: load `ada-genres` for matching, the camera-token legend and online stand-ins; `ada-genres-mashups` when the idea joins genres.*

Our research has few entries on single-screen arcade games: snake, maze chase, breakout, invaders,
asteroids and growth games share these lines, which carry the nearest score, input and growth
entries. A named game is a reference; the design document's fan-game rule handles copies.

**Camera:** `static`, one screen that fits the window; `follow2d` for a growth game whose view
follows and zooms out as you grow.

## Design defaults

- **best-score**: The score sits at the top beside the best score, which is kept between visits, and
  the game-over screen says when it is beaten. Why: every run has a number to beat. Break it when: a
  growth game played for size, or a calm toy with no score.
- **lives-and-extra**: A few lives, shown as icons, an extra life at a score, and a short safe
  moment after each death. Why: arcade stakes, with a reward for playing well. Break it when: one
  life a run, a quick game that restarts at once.
- **gets-faster**: Each cleared screen or wave comes back faster or busier, and the level number is
  on screen. Why: the same screen stays a challenge as the player gets better. Break it when: a
  growth game, where getting bigger is the change.

## Feel

- **instant-turns**: The player moves the moment a key is pressed, and a turn pressed a moment early
  is remembered, so a quick pair of turns both count. Why: a death is the player's mistake, never a
  dropped key. Break it when: a drifting ship with momentum, where the slide is the skill.
- **fair-collisions**: The player's hit area sits a little inside the sprite, and pickups are caught
  a little outside it. Why: a near miss looks like one, and a grab that looks like a grab counts.
  Break it when: exact edges are the challenge on purpose, squeezing through the tightest gaps.
- **score-pops**: Every score pops up where it was earned, and quick kills or pickups in a row raise
  a multiplier shown beside the score. Why: playing fast and close is seen to pay. Break it when:
  the score is plain counting, as a snake's length.

## Feel variants

- **frantic**: Fast and frantic: the speed climbs quickly, big chains, short runs.
- **steady**: Steady and readable: a slow start, a pattern to learn, long runs.
- **snowball**: Snowballing: you grow, and what chased you becomes what you eat.

## Choices that shape the pitch

- **What you play:** a maze chase, eat every dot while enemies hunt you (default) · a snake that
  grows · a ball and paddle against bricks · a descending fleet to shoot down · a ship among
  drifting rocks · eat smaller things to grow.
- **Stakes:** a few lives, then game over (default) · one life, restart at once · no
  failure, a timed round for score.
- **Speed:** each level faster (default) · speed that rises with the score · the same speed,
  more enemies.
- **What the player sees:** one screen, `static` (default) · a view that follows and zooms out as
  you grow, `follow2d`.
- **Feeling:** the player feels the pull of one more go by beating their best by a little, because
  the run was short, the death was their own and the restart is one key.

## Later, beyond the first slice

- An online high-score table → needs a server: not built by Studio; offer the local stand-in from `ada-genres`
- Initials on a high-score table → iterate on it after play, in the same project
- Each enemy with its own chase rule → iterate on it after play, in the same project
- Two players taking turns or together → iterate on it after play, in the same project
- A demo that plays itself on the title screen → iterate on it after play, in the same project
- Growth through many stages of scale → grow it across later milestones
- A daily seeded challenge → iterate on it after play, in the same project
- A level editor → not verified in Studio yet: ask for it after play and the agent will try it without a verified path

## In a mashup

The arcade game leads the screen, the score and the lives. A roguelite leads upgrades between
runs and what carries over. A puzzle half leads the rules of the board. Rhythm leads timing, and
moves land on the beat. A management half leads money spent between rounds, and the arcade game
keeps each round short.

---

Adapted from Donchitos/Claude-Code-Game-Studios (MIT): `.claude/genres/chipsets/arcade-classic.md` @ abc0de7. See `NOTICE.md` beside the skills root.
