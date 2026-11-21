---
name: ada-genre-racing
description: "Drive a vehicle to finish first, or to wreck the others. Genre defaults for Ada Studio game builds; matches briefs such as: driving, kart racer, drift game, time trial, car combat, a delivery against the clock, a game like Mario Kart, Burnout or Crazy Taxi"
---

# Genre: racing
*Part of the genre library: load `ada-genres` for matching, the camera-token legend and online stand-ins; `ada-genres-mashups` when the idea joins genres.*

**Camera:** `chase`; `topdown` for a top-down racer.

## Design defaults

- **laps-and-place**: One closed track and a few laps, with your lap and place on screen, then a
  finish screen with your place and times. Why: a race needs a line to cross and a place to fight
  for. Break it when: the race is point to point, or a delivery against the clock.
- **rivals-close**: A few rival cars race clean lines and stay close, with a slight catch-up for
  whoever trails. Why: the race stays a race to the last lap. Break it when: it is a time trial, the
  same every run, with no rivals and no catch-up.

## Feel

- **easy-drift**: Steering is quick but smoothed, and a held drift starts a slide that is easy to
  hold and to leave. Why: a corner is a choice the player makes, not a spin they suffer. Break it
  when: the user wants a sim, where grip and weight are the challenge.
- **brake-to-turn**: A brake key slows the car hard, and a slower car turns tighter, so every bend
  can be taken by braking before it and steering through. Why: a bend the player cannot slow for
  is a wall, not a corner. Break it when: there is no brake on purpose, a toy or an endless road
  whose bends can all be steered at full speed.
- **turn-in**: At racing speed the car turns sharply enough for the tightest bend on the track, and
  the track is laid out for the car's turning circle. Why: a corner is taken with skill, never
  missed because the car cannot make it. Break it when: the user wants a sim, where the line
  and the braking point are the challenge.
- **speed-shows**: The view widens and the wind rises as you go faster, and reduced motion turns it
  down. Why: speed is felt without the car handling worse. Break it when: the view is fixed from
  above, where the track moving past shows the speed.
- **engine-pitch**: The engine's note climbs with speed and drops when you brake or slide. Why: the
  ear tracks speed while the eyes watch the road. Break it when: the cars are silent on purpose,
  toys pushed by hand or a quiet glider.
- **quick-reset**: Off the track or stuck, one key puts you back on the road facing the right way,
  and a landing from a jump comes down straight. Why: a crash costs seconds, never the race. Break
  it when: wrecking is the game, and a crash ends the run on purpose.

## Feel variants

- **arcade**: Tight and arcade: grippy until you drift, light cars, quick to recover.
- **grounded**: Heavy and grounded: weight, body roll and braking that has to start early.
- **kart**: Kart: tiny turns, hops into drifts, and bumps that cost little.

## Choices that shape the pitch

- **Stakes:** a race for place against rivals (default) · a time trial against your own best run,
  the same every time · wreck the others, with a crash replay.
- **Pickups:** none, pure driving (default) · pickups that help whoever trails · boost earned by
  sliding and near misses.
- **Progression:** one track now (default) · a cup of tracks in a row · cars and parts unlocked
  by results (later).
- **What the player sees:** behind the car, `chase` (default) · from above, `topdown` · the
  cockpit, `first`.
- **Feeling:** the player feels speed on the edge of control by holding a drift through a corner,
  because the slide is easy to start and leaving it at the right moment pays off.

## Later, beyond the first slice

- Cars that deform and handle worse when hit → not verified in Studio yet: ask for it after play and the agent will try it without a verified path
- Force feedback and haptics → not verified in Studio yet: ask for it after play and the agent will try it without a verified path
- Traffic → not verified in Studio yet: ask for it after play and the agent will try it without a verified path
- Car upgrades and tuning → add it as its own feature milestone
- A career of cups → grow it across later milestones
- Split-screen races → iterate on it after play, in the same project
- Ghost replays shared online → needs a server: not built by Studio; offer the local stand-in from `ada-genres`
- Online races → needs a server: not built by Studio; offer the local stand-in from `ada-genres`
- Switching between vehicles → not verified in Studio yet: ask for it after play and the agent will try it without a verified path

## In a mashup

Racing leads handling, and a time trial keeps its rules the same every run while a race may help
whoever trails. An RPG leads progression. A sandbox leads what the world offers. A creature
collector leads the collection and the party, and racing leads the race itself.

---

Adapted from Donchitos/Claude-Code-Game-Studios (MIT): `.claude/genres/chipsets/racing.md` @ abc0de7. See `NOTICE.md` beside the skills root.
