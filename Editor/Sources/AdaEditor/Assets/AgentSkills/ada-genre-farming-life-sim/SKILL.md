---
name: ada-genre-farming-life-sim
description: "Farm through the seasons and build a life in a small town. Genre defaults for Ada Studio game builds; matches briefs such as: farming, life sim, social sim, cozy village life, a game like Stardew Valley, Animal Crossing or The Sims"
---

# Genre: farming-life-sim
*Part of the genre library: load `ada-genres` for matching, the camera-token legend and online stand-ins; `ada-genres-mashups` when the idea joins genres.*

**Camera:** `topdown`, the farm and town from above; `strategy` for a house you build and watch,
a game like The Sims.

## Design defaults

- **bed-ends-day**: The clock runs through the day, which starts and ends at home; going to bed ends
  it with a summary of what was earned and what is ready tomorrow, the game saves there, and staying
  up too late costs little. Why: each day closes cleanly with a plan for the next, and stopping is
  always safe. Break it when: time runs without days, a house watched around the clock.
  [harvest-moon-manual-1], [stardew-2]
- **crops-by-season**: Seeds are planted and watered, grow over a few days into a crop to pick and
  sell, and a season of set length changes what will grow; some crops keep giving after the first
  harvest. Why: each day's chores build toward a harvest, and the season gives the plan an edge.
  Break it when: the farm is a garden for its own sake, with no seasons. [harvest-moon-manual-1]
- **one-neighbour**: A neighbour or two walk the town; talking or giving a gift fills a friendship
  meter, and they remember the last gift and talk about their own lives. Why: the town is people,
  not only fields. Break it when: a farm alone on purpose, a quiet homestead. [iwata-ac-2]

## Feel

- **field-shows-work**: Watered soil turns dark at once, each crop shows a new stage every morning,
  and a ripe crop looks ripe. Why: the farm reads at a glance, and each morning shows the work paid
  off. Break it when: the farm is a ledger of fields run from menus. [wada-1]
- **tool-on-tile**: The tile a tool will hit is marked before the swing, and holding the button
  works along a row. Why: chores are quick, and a stray click never wastes a seed. Break it when:
  free scattering is the charm, a wild garden sown by hand.
- **harvest-pop**: A picked crop pops up into the bag with a soft sound, and the night's sale counts
  up line by line in the summary. Why: days of care pay off in one moment. Break it when: harvests
  are sold in bulk from a menu, a farm run as a business.
- **nothing-lost**: A missed watering means a crop waits a day and never dies, and the clock stops
  in menus and while talking. Why: the player plans without fear and can stop at any time. Break it
  when: the harvest must feed you through a winter, a survival farm. [wada-1]

## Feel variants

- **cozy**: Cozy and slow: a long day, no energy to run out, nothing urgent.
- **planner**: Busy and planned: a short day, energy that runs out, every hour a choice.
- **village**: Village life: a small garden, more neighbours, gifts that change what they say.

## Choices that shape the pitch

- **The life:** a farm you grow and sell from (default) · a house to furnish and neighbours to visit
  · a family whose needs you guide, as in The Sims.
- **The day's limit:** the clock (default; a day clock) · an energy bar as well
  · none, at your own pace.
- **Stakes:** none, a missed day only waits (default) · a target by a festival at the end of the
  season · bills each night that a full day's work just covers.
- **What the player sees:** from above, `topdown` (default) · an angled room you build in,
  `strategy`.
- **Feeling:** the player feels ongoing planning by going to bed with tomorrow's harvest in mind,
  because each day closes cleanly and shows what is coming.

## Later, beyond the first slice

- Seasons and a calendar of festivals → grow it across later milestones
- Townsfolk on daily schedules → not verified in Studio yet: ask for it after play and the agent will try it without a verified path
- Needs and moods for every person, as in The Sims → not verified in Studio yet: ask for it after play and the agent will try it without a verified path
- Friendships that grow into romance → add it as its own feature milestone
- Fishing, mining and cooking on the side → add it as its own feature milestone
- Barn animals to care for → add it as its own feature milestone
- Machines that turn crops into goods → add it as its own feature milestone
- Tool and house upgrades → iterate on it after play, in the same project

## In a mashup

Farming leads the daily rhythm, the calendar and the save at night. Management leads the money when
the farm is a business. Fishing leads the cast and the catch, and the fish sell in the same bin. A
dungeon or action half leads its fights, and the day clock still runs. A creature collector leads
catching, and the creatures help on the farm. A visual novel leads the conversations.

---

Adapted from Donchitos/Claude-Code-Game-Studios (MIT): `.claude/genres/chipsets/farming-life-sim.md` @ abc0de7. See `NOTICE.md` beside the skills root.
