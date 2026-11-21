---
name: ada-genre-twin-stick-shooter
description: "Top-down; one stick moves, the other aims. Genre defaults for Ada Studio game builds; matches briefs such as: top-down shooter, arena shooter on one screen, a game like Geometry Wars or Robotron"
---

# Genre: twin-stick-shooter
*Part of the genre library: load `ada-genres` for matching, the camera-token legend and online stand-ins; `ada-genres-mashups` when the idea joins genres.*

**Camera:** `topdown`, between the player and where they aim; `static` for one arena that fits
**First-slice variety floor (hypothesis, not measured):** at least 4 enemy kinds, each attacking or moving differently; bosses and elites count. The brief's features list wins if it asks for more.
the window.

## Design defaults

- **waves-and-score**: One arena, enemies in waves that grow, and a score with a multiplier on
  screen that a hit resets; the best score is kept. Why: every second alive is worth more than the
  last. Break it when: the game is rooms to clear and a door to reach, with no score.
- **enemy-jobs**: A few kinds of enemy, each with its own job: one chases, one wanders, one shoots,
  one splits when hit. Why: the player reads a crowd by its shapes and picks what to shoot first.
  Break it when: one horde of the same enemy is the point, a survive-the-swarm game.

## Feel

- **move-and-aim**: One hand moves at the same speed every way, the other aims, and the gun fires
  where you point while you keep moving; a gamepad gets a small aim help, a mouse none. Why: dodging
  and shooting are two jobs done at once. Break it when: one button fires the way you face, a
  simpler arcade shooter.
- **camera-leads-aim**: The camera sits between the player and the aim point, so more of the screen
  lies where you shoot. Why: the threat you aim at is in view before it reaches you. Break it when:
  the whole arena fits the window and the camera never moves.
- **gun-kick**: Every shot flashes at the muzzle and kicks the player back a hair, and bullets are
  big, fast and easy to follow. Why: the gun feels strong without a word on screen. Break it when:
  the weapon is soft and silent on purpose, a toy or a beam of light.
- **spawn-warning**: New enemies flash in place a moment before they are real and never appear right
  beside the player, adding to the starter's enemy fairness. Why: a death comes from a choice, never
  from a spawn. Break it when: enemies walk in through set doors at the edges.

## Feel variants

- **swarm**: Neon swarm: one arena, crowds that keep growing, one hit and a life is gone.
- **bullet-dodge**: Bullet dodge: rooms of shooters, a dodge roll through their bullets, health that
  matters.
- **heavy-gun**: Heavy guns: slow, strong shots with a big kick, fewer and tougher enemies.

## Choices that shape the pitch

- **Arena:** one arena, endless waves (default) · rooms cleared one by one · a run of generated
  rooms, a roguelite.
- **Stakes:** a few lives and a high score (default) · one life · health, and pickups that heal.
- **Weapons:** one gun that grows with pickups (default) · a few guns with different jobs · ammo
  earned by kills.
- **Players:** one (default) · two on one keyboard or gamepads (local
  co-op).
- **What the player sees:** from above, `topdown` (default) · one arena that fits the window,
  `static`.
- **Feeling:** the player feels fearless aggression by diving into a crowd to keep the multiplier,
  because each kill keeps it climbing and each enemy reads at a glance.

## Later, beyond the first slice

- Enemies that flank, take cover and call to each other → not verified in Studio yet: ask for it after play and the agent will try it without a verified path
- Bosses with phases → iterate on it after play, in the same project
- A bomb that clears the screen → iterate on it after play, in the same project
- Weapons and builds unlocked between runs → grow it across later milestones
- Cover that breaks apart → add it as its own feature milestone
- Shields and weak points that need a different aim → iterate on it after play, in the same project
- Scores shared online → needs a server: not built by Studio; offer the local stand-in from `ada-genres`
- Co-op online → needs a server: not built by Studio; offer the local stand-in from `ada-genres`

## In a mashup

The twin-stick leads movement, aim and the arena. A roguelite half leads the run, the rooms and
what carries over. An RPG half leads loot and levels. A tower-defense half leads building
between waves, and the shooting stays by hand. A stealth half leads guards and sight, and the
shooting is the plan that failed.

---

Adapted from Donchitos/Claude-Code-Game-Studios (MIT): `.claude/genres/chipsets/twin-stick-shooter.md` @ abc0de7. See `NOTICE.md` beside the skills root.
