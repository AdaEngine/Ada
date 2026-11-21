---
name: ada-genre-management-tycoon
description: "Run a business or a place (tycoon), balancing money, staff and customers. Genre defaults for Ada Studio game builds; matches briefs such as: tycoon, management, business sim, shop or restaurant sim, theme park, trading, economy sim, a game like RollerCoaster Tycoon or Two Point Hospital"
---

# Genre: management-tycoon
*Part of the genre library: load `ada-genres` for matching, the camera-token legend and online stand-ins; `ada-genres-mashups` when the idea joins genres.*

**Camera:** `strategy`, an angled pan and zoom; `static` for one room that fits the window.

## Design defaults

- **money-in-out**: Income and costs are both on screen, each with where it comes from. Why: the
  player can tell why the money went down. Break it when: the money is hidden on purpose, a cozy
  shop with no money worries.
- **goals-near-far**: A goal for now, one for the day and one for the run are always on screen. Why:
  there is always a next thing, and a natural place to stop. Break it when: it is a sandbox with no
  goals the user asked for.
- **day-summary**: Each day ends with a summary of what was earned and spent, and the game saves
  there. Why: the day closes cleanly, and the next one starts with a plan. Break it when: time runs
  without days, a factory that never stops.

## Feel

- **placement-feedback**: Building snaps to a grid with a ghost preview and its price; placing it
  lands with a snap and a sound, and it starts working at once. Why: every placement answers
  straight away, so building is quick and a mistake is cheap. Break it when: nothing is placed, or
  the layout is fixed and the game is the prices.
- **money-ticks**: Money counts up as customers pay, each payment rising from the spot where it was
  made. Why: the player sees their layout earning, coin by coin. Break it when: money moves only
  between days, a spreadsheet game the user asked for.
- **watch-them-work**: Customers and staff walk the floor where you can watch them, and queues and
  idle spots show. Why: the player finds a problem by watching it. Break it when: the business is
  run from menus and reports, a trading desk or a stock market.
- **near-done-ding**: A goal close to done shows how close it is, and finishing it rings with a
  small celebration. Why: the next goal pulls the player on, and reaching one feels earned. Break it
  when: there are no goals, a sandbox the user asked for.

## Feel variants

- **busy**: Busy and bustling: a crowd that keeps coming, quick fixes, a rush at peak hours.
- **calm**: Calm and tidy: a slow trickle, time to arrange things just right, nothing urgent.

## Choices that shape the pitch

- **What you run:** one place you lay out, a shop, park or hospital (default) · a production chain
  of machines whose ratios are the puzzle · a town of services and roads.
- **Stakes:** money runs out and the run ends, winnable at full pace (default) · a score at the end
  of a few days, no way to fail · a sandbox with no money worries.
- **Progression:** new buildings unlocked by goals (default) · expand to a new site and start again
  stronger (prestige) · set scenarios with a target each.
- **What the player sees:** angled pan and zoom, `strategy` (default) · one room, `static` · from
  above, `topdown`.
- **Feeling:** the player feels ongoing planning by fixing one bottleneck and spotting the next,
  because each expansion puts pressure somewhere new and the floor shows where.

## Later, beyond the first slice

- Staff with their own needs and moods, inspectable one by one
  → not verified in Studio yet: ask for it after play and the agent will try it without a verified path
- Research trees → grow it across later milestones
- Several currencies → add it as its own feature milestone
- Marketing and rival businesses → not verified in Studio yet: ask for it after play and the agent will try it without a verified path
- Loans → iterate on it after play, in the same project
- Several sites → grow it across later milestones
- A scenario editor → not verified in Studio yet: ask for it after play and the agent will try it without a verified path
- Long-run balance of money made and spent → grow it across later milestones

## In a mashup

Management leads resource flow and the diagnostics that show it. A life sim leads the daily rhythm
and relationships, and saves stay safe to stop after a day. A roguelite leads how a run ends and
what carries over. Cozy building leads placement tolerance and decoration. An action half, a
platformer between shop days, leads its own levels.

---

Adapted from Donchitos/Claude-Code-Game-Studios (MIT): `.claude/genres/chipsets/management-tycoon.md` @ abc0de7. See `NOTICE.md` beside the skills root.
