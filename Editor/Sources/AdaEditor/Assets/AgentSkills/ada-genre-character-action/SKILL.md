---
name: ada-genre-character-action
description: "Stylish melee in 3D, with combos, dodges and a rank for style. Genre defaults for Ada Studio game builds; matches briefs such as: hack and slash, character action, superhero, cinematic action, martial arts, a game like Devil May Cry, Bayonetta or Sifu"
---

# Genre: character-action
*Part of the genre library: load `ada-genres` for matching, the camera-token legend and online stand-ins; `ada-genres-mashups` when the idea joins genres.*

**Camera:** `orbit`, with a lock-on that keeps the target in view; `fixed` for set angles in
**First-slice variety floor (hypothesis, not measured):** at least 3 enemy kinds, each attacking or moving differently; bosses and elites count. The brief's features list wins if it asks for more.
each room, `follow2d` for a side-on 2D one.

## Design defaults

- **style-rank**: A style rank on screen rises with varied hits and falls when you repeat a move or
  get hit, and each fight ends on a grade. Why: the player is pushed to fight well, not only to win.
  Break it when: the fight is about surviving, not showing off, a grim duel.
- **arena-waves**: Each fight closes you into an arena with a few waves of enemies, the last one the
  hardest. Why: a fight has a shape, and the last wave tests everything learned in it. Break it
  when: enemies roam an open world and a fight can start anywhere.

## Feel

- **combo-strings**: Tapping attack strings a combo, a pause in the middle changes it, and a press
  made early comes out the moment the last hit ends. Why: the player writes the combo with their
  timing. Break it when: there is one attack, a game about a single perfect strike.
- **dodge-cancel**: A dodge comes out of any attack's follow-through and is safe from its first
  frame, and a dodge at the last moment slows time for a beat. Why: defence never waits for an
  animation, and a close dodge pays. Break it when: attacks commit you on purpose, a heavy duel
  where a swing cannot be stopped.
- **launch-juggle**: An uppercut launches an enemy, a jump follows it, and hits in the air keep it
  there. Why: the air is a second stage for the combo. Break it when: fights stay on the ground, a
  martial-arts duel of guard and stance.
- **soft-lock**: Attacks turn you toward the enemy you push toward and close a short gap, and one
  key locks the camera onto it. Why: the hit goes where the player meant. Break it when: aiming each
  swing by hand is the skill.

## Feel variants

- **stylish**: Stylish and flashy: long combos, launches, a slowdown on every perfect dodge.
- **duelist**: Duelist: fewer, tougher enemies, and a block at the moment of a hit breaks their
  guard.
- **mighty**: Mighty: a hero of great power who sends whole crowds flying.

## Choices that shape the pitch

- **Defence:** dodges (default) · blocks at the last moment that break an enemy's guard, the
  martial-arts way · health won back by hitting back after a hit.
- **Structure:** a few arenas in a row, each graded (default) · one boss fight to master · endless
  waves for a high score.
- **Hero:** a sword fighter (default) · bare hands and martial arts · a superhero with powers.
- **What the player sees:** behind the hero, `orbit` (default) · set angles, `fixed` · side-on,
  `follow2d`.
- **Feeling:** the player feels fearless aggression by dodging through a blow and straight into a
  combo, because a close dodge pays and the style rank climbs.

## Later, beyond the first slice

- Weapons switched in the middle of a combo → add it as its own feature milestone
- Upgrades that add new moves → add it as its own feature milestone
- Music that grows with the style rank → iterate on it after play, in the same project
- Giant bosses with a camera of their own → iterate on it after play, in the same project
- Finishers driven by pressing again and again → iterate on it after play, in the same project
- Cutting objects along a line you choose → add it as its own feature milestone
- Enemy groups that combine their attacks as a team → not verified in Studio yet: ask for it after play and the agent will try it without a verified path
- Cutscenes and dramatic camera moments → grow it across later milestones

## In a mashup

Character action leads combos, dodges and the style rank. An RPG half leads levels and gear, and
gear never replaces skill. A rhythm half leads timing, and attacks land on the beat. A roguelite
half leads the run and what carries over. A platformer half leads the jumps between arenas, and a
beat-em-up half leads crowds along a stage.

---

Adapted from Donchitos/Claude-Code-Game-Studios (MIT): `.claude/genres/chipsets/character-action.md` @ abc0de7. See `NOTICE.md` beside the skills root.
