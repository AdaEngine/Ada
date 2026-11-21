---
name: ada-genre-survival-crafting
description: "Gather and craft against hunger and threats, and build a base. Genre defaults for Ada Studio game builds; matches briefs such as: survival, crafting, base building, underwater survival, a game like Don't Starve, Valheim, Subnautica or Minecraft survival"
---

# Genre: survival-crafting
*Part of the genre library: load `ada-genres` for matching, the camera-token legend and online stand-ins; `ada-genres-mashups` when the idea joins genres.*

There is no tested way to build deep simulation yet: a first slice is one small island or clearing,
one night and a few materials and recipes, never a whole simulated world.

**Camera:** `topdown`, angled from above; `first` through the eyes, a game like Minecraft or
Subnautica; `orbit` behind the player, a game like Valheim; `follow2d` for a side view dug
downward.

## Design defaults

- **needs-in-view**: Health, hunger and one need of the setting, warmth or air under water, sit near
  the player, fall slowly and are filled by what is gathered and cooked. Why: the player knows at a
  glance why the next trip matters. Break it when: a peaceful build mode with no needs.
- **recipes-point-ahead**: The craft list shows what can be made now, and greyed recipes show what
  is missing and where it is found. Why: the things the player wants to make give them a direction.
  Break it when: recipes are found by trying combinations, and the discovery is the point.
- **drop-and-return**: Dying drops what was carried where you fell, and you wake at your bed; going
  back gets it. Why: death stings without erasing the run. Break it when: hard stakes, one life and
  the run is over.

## Feel

- **first-night**: Dusk comes soon and is felt, the light dimming and the sounds changing, and the
  first recipes are a fire and a shelter that keep the night out. Why: the open world gets one plain
  first purpose, and the first build matters. Break it when: a creative mode with no danger.
- **gather-thunk**: Each hit on a tree or rock takes a bite out of it with a material sound and a
  spray of bits, the last hit topples it, and the pickups fly to you. Why: the hundredth log still
  feels good to get. Break it when: gathering is from a menu, a survival planner.
- **snap-build**: Walls and floors snap to a grid with a ghost that shows what they cost and whether
  they fit. Why: a shelter goes up fast and looks right. Break it when: free placement is the craft,
  logs laid one by one.
- **home-is-safe**: Inside walls by a fire the music softens, needs fall slower and a rested bonus
  shows. Why: home is felt as safe, so building one matters. Break it when: a wanderer with no base,
  always on the move.

## Feel variants

- **gentle**: Gentle: slow hunger, few threats, room to build.
- **harsh**: Harsh wilds: hunger that bites, a deadly night, every trip a gamble.
- **deep**: Into the deep: under water, air is the clock, danger from every side.

## Choices that shape the pitch

- **The setting:** a wild clearing or island (default) · under water, air the main need · a side
  view dug downward, mining for better ore.
- **Stakes:** drop what you carried and wake at your bed (default) · one life, and the run is over ·
  none, a creative mode.
- **The threat:** night creatures (default) · cold and storms · hunger alone.
- **The world:** a small generated island (default) · a hand-made clearing.
- **What the player sees:** from above, `topdown` (default) · first person, `first` · behind the
  player, `orbit` · a side view, `follow2d`.
- **Feeling:** the player feels creative ownership by turning the first night's shelter into a home,
  because each build solved a real need and is made of what they gathered.

## Later, beyond the first slice

- Weather that soaks, chills and spoils gear → add it as its own feature milestone
- Animals with food and dens that roam on their own → not verified in Studio yet: ask for it after play and the agent will try it without a verified path
- Enemies that hunt by sight and sound → not verified in Studio yet: ask for it after play and the agent will try it without a verified path
- Tool tiers that open new regions → grow it across later milestones
- Bosses whose rewards open a new frontier → add it as its own feature milestone
- Machines that take over the chores → add it as its own feature milestone
- Taming and farming → add it as its own feature milestone
- An inventory that is a grid puzzle → iterate on it after play, in the same project
- Surviving together with friends → needs a server: not built by Studio; offer the local stand-in from `ada-genres`

## In a mashup

Survival leads needs, recipes and the day-night threat. A sandbox leads materials and free building.
A colony sim leads when the player commands others instead of one hero. Horror leads the dread and
the hunter, and survival leads supplies. Farming leads crops and the day's rhythm when food is
grown. An action RPG leads the fights.

---

Adapted from Donchitos/Claude-Code-Game-Studios (MIT): `.claude/genres/chipsets/survival-crafting.md` @ abc0de7. See `NOTICE.md` beside the skills root.
