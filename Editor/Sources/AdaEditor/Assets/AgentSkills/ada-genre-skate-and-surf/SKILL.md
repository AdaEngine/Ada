---
name: ada-genre-skate-and-surf
description: "Ride a board or a wave, chain tricks and keep a line going for score. Genre defaults for Ada Studio game builds; matches briefs such as: skateboarding, surfing, snowboarding, BMX, momentum sports, a game like Tony Hawk's Pro Skater, SSX or OlliOlli"
---

# Genre: skate-and-surf
*Part of the genre library: load `ada-genres` for matching, the camera-token legend and online stand-ins; `ada-genres-mashups` when the idea joins genres.*

**Camera:** `chase`, behind the rider; `follow2d` for a side view.
**Research:** needs primary research: the source research has a few skating entries, on the manual and
revert that carry a combo, speed from slopes and grind routes. It has no entry for the tricks
themselves, flips and grabs on a press, or for a timed run with its listed goals.

## Design defaults

- **bank-on-landing**: Tricks chain into a combo whose points and multiplier grow on screen; a clean
  landing banks it, a bail loses it, and the same trick twice in one combo scores less. Why: every
  combo is a gamble on one more trick, and variety pays. Break it when: a calm ride with no score,
  surfing for the view.

## Feel

- **keep-the-line**: A balance move on flat ground, a manual or a carve along the wave's face, keeps
  a combo alive between ramps and rails, with a balance meter that tips if held too long. Why: the
  whole park becomes one route. Break it when: each trick is scored on its own, a contest of single
  jumps.
- **forgiving-landing**: Landing near level counts as clean and snaps the board straight, a sloppy
  landing is a wobble, not a bail, and a bail rights you in a moment. Why: tricks are tried, not
  feared. Break it when: the user wants a sim where every landing must be exact.
- **slopes-give-speed**: Dropping into a ramp or down a wave's face builds speed, and a pump at the
  bottom carries it on. Why: speed is earned from the ground, so a line has a rhythm. Break it when:
  speed is set, a side-view run that scrolls on its own.
- **rail-catch**: A rail or ledge close under the board catches a grind on a press, with a scrape
  that runs while you hold it. Why: catching a rail feels sure, so lines are planned, not hoped for.
  Break it when: surf or snow with no rails, where the wave's lip or a log takes that part.

## Feel variants

- **arcade**: Tight and arcade: big air, quick spins, tricks on a press, combos across the whole
  park.
- **flowing**: Flowing and calm: no clock, long carves on a wave or a slope, style over points.
- **timing**: Precise timing: each trick lands on a press made just before touchdown, and a perfect
  press scores more.

## Choices that shape the pitch

- **What you ride:** a skateboard in a park (default) · a surfboard on a moving wave · a snowboard
  down a mountain · a bike.
- **Stakes:** a timed run for score and goals (default) · a race downhill, with tricks filling a
  boost · a free ride with no clock.
- **What the player sees:** behind the rider, `chase` (default) · a side view, `follow2d`.
- **Feeling:** the player feels kinetic flow by linking a grind, a manual and a ramp into one combo,
  because the balance move keeps the line alive and the landing forgives.

## Later, beyond the first slice

- A park editor → not verified in Studio yet: ask for it after play and the agent will try it without a verified path
- A career of parks and pro goals → grow it across later milestones
- Real board physics with flips and spins → not verified in Studio yet: ask for it after play and the agent will try it without a verified path
- A rider and board to dress up → iterate on it after play, in the same project
- Music that builds with the combo → iterate on it after play, in the same project
- Two players taking turns on one screen, copying each other's tricks → iterate on it after play, in the same project
- Shared high scores → needs a server: not built by Studio; offer the local stand-in from `ada-genres`
- Online sessions → needs a server: not built by Studio; offer the local stand-in from `ada-genres`

## In a mashup

Skate leads movement, tricks and the combo score. A racing half leads the course and the rivals, and
tricks fill the boost. A platformer half leads the level's goals, and the board is how you move. A
level-maker half leads the park editor. An arcade-classic half leads one screen and the high score.

---

Adapted from Donchitos/Claude-Code-Game-Studios (MIT): `.claude/genres/chipsets/skate-and-surf.md` @ abc0de7. See `NOTICE.md` beside the skills root.
