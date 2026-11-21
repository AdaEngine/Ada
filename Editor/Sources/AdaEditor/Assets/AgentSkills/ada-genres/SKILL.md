---
name: ada-genres
description: "Match a game brief to one of the 69 ada-genre-* genre sheets and apply genre defaults for camera, feel, scope and online stand-ins. Load when a brief names or implies a genre, joins genres, or asks for online play, VR, a phone or a console."
---

# Ada Genres

The genre library gives each game build genre-appropriate defaults: how the camera behaves, which feel rules the genre's best games share, what the first playable slice contains and what waits for later. Each genre is its own skill (`ada-genre-platformer`, `ada-genre-tower-defense`, ... 69 in all), discovered through `editor.skills.list` and loaded with `editor.skills.read`.

## Match a brief to genres

1. Take the genre words from the user's own brief ("a game like Hades", "cozy farming", "bullet hell") and call `editor.skills.list` with them as the query. The genre skills carry their matching phrases in their descriptions, including reference games.
2. Read the best-matching `ada-genre-*` skill and apply its defaults: camera, design defaults, feel rules, first-slice scope. Genres are matched by meaning, never shown as a menu to the user.
3. When the idea joins two or more genres, load `ada-genres-mashups` before choosing systems. When the look is not yet decided, load `ada-genres-art-direction` and write the art direction into the design document (the `DESIGN.md` of `ada-autonomous-studio`, section "Art direction").
4. Record the chosen genre and its key defaults in the project's design/progress notes so later sessions keep them.

Every sheet line is a hypothesis from the upstream research (the genre's best-received games), not a measurement; the user's explicit words always win over a sheet. First-slice variety floors (enemy kinds) are minimums for acceptance criteria, never caps.

## Camera tokens

Genre sheets name cameras with short tokens. Build them with the engine's components:

- `follow2d` — a 2D camera following the player: `Camera2DController` on the camera entity (offset for look-ahead, `deadZone`, `smoothingTime`, limits, `snapsToPixels` for pixel art) and `CameraTarget2D` on each followed entity.
- `static` — a fixed camera; nothing moves the view. Place one camera entity and compose the scene to fit.
- `topdown` — the world seen from above: a 2D scene with `Camera2DController` follow, or a 3D camera high above with a downward pitch, following through a script.
- `strategy` — an angled overhead view with pan and zoom: a pitched 3D camera (or an orthographic 2D view) moved by input through a script; keep unit scale readable.
- `orbit` — a 3D camera that circles behind the character: a script positions the camera from the character's transform each frame, with collision-aware distance where needed.
- `chase` — an `orbit` variant locked behind a vehicle, with speed-based distance.
- `first` — first-person: the camera sits at the character's head and turns with the look input.
- `fixed` — set 3D angles that follow the action (a side-view 3D stage, a fixed board view): a script moves the camera along with the player at a constant offset.

Where a sheet's camera token and the project's existing camera disagree, the project's convention wins for an existing game; the sheet wins for a new one.

## Online play, VR and other devices

Studio builds local games: nothing here runs over a network. When the brief asks for online play, name the level in the design document and build the stand-in, saying so in plain words:

| Level | What the user asks for | What Studio builds instead |
|---|---|---|
| on one screen | friends at one screen or keyboard | that, as asked: it is not online at all |
| async | leaderboards, ghosts, daily challenges, turns over days | a daily seed from the date with a code to share, a local leaderboard, a ghost of your own best run |
| session | a match or co-op on separate machines | players on one screen, and bots in the empty seats, named as bots |
| dedicated servers | ranked or competitive play against strangers | bots in the seats, named as bots |
| persistent world | a world many players share at once, an MMO | bot players on this machine, named as bots, and the character saved locally |

- More than one level asked for (a co-op game with a leaderboard): name the highest and list each stand-in.
- A stand-in never proves the online game: a bot is not a person. It shows whether the idea is fun, not whether it holds up over a network.
- VR: Studio has no verified VR path; say so and build the flat-screen version.
- Phone: follow `ada-game-builder`'s touch rules (shared actions, visible controls, safe areas). Keyboard simulation cannot verify touch input; mark that check manual.
- Console: console ports go through the platform holders' programs; the desktop or mobile build is where the game starts.

## Traceability

`SOURCES.md` beside this skill lists the upstream sources behind the sheets (interviews, manuals, talks). It ships for repository traceability; agents cannot read it through tools and do not need it to build.

---

Adapted from Donchitos/Claude-Code-Game-Studios (MIT): `.claude/genres/` @ abc0de7. See `NOTICE.md` beside the skills root.
