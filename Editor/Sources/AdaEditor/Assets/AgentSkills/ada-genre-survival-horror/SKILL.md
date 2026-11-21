---
name: ada-genre-survival-horror
description: "A weak player, scarce resources; fleeing matters as much as fighting. Genre defaults for Ada Studio game builds; matches briefs such as: horror, top-down horror, camera-watching horror, a game like Resident Evil, Silent Hill or Five Nights at Freddy's"
---

# Genre: survival-horror
*Part of the genre library: load `ada-genres` for matching, the camera-token legend and online stand-ins; `ada-genres-mashups` when the idea joins genres.*

**Camera:** `orbit`, close over the shoulder; `first` through the eyes; `fixed` for set angles
room by room; `topdown` for top-down horror; `static` for a room watched through cameras.

## Design defaults

- **scarce-supplies**: Ammo and healing are few and found by searching, and what turns up leans
  toward what the player is short of. Why: every bullet matters, and running away is a real choice.
  Break it when: action horror against hordes, with plenty to shoot.
- **small-inventory**: A few slots, shown on one screen, and a box in the safe room for the rest.
  Why: picking something up is a choice that shapes the route. Break it when: a short chase with
  nothing to carry.
- **safe-room-save**: A safe room that nothing follows into holds the save point and the box, and
  progress is kept only there. Why: relief after pressure, and a reason to push one more room. Break
  it when: the safe place is what turns unsafe, a house that changes as you loop it.

## Feel

- **hear-it-first**: The hunter is heard before it is seen, from its side and louder as it nears,
  over a low, uneasy hum that rises with the danger. Why: dread builds before the threat appears,
  and the player can act on what they hear. Break it when: a silent stalker is the twist, and the
  quiet is the warning.
- **look-costs**: Checking the map, the inventory or a detector does not pause the game. Why:
  looking costs attention, so even a menu is tense. Break it when: a slower puzzle horror, where the
  inventory is a safe moment to think.
- **dark-and-light**: The dark hides the edges of the screen, and the player's light shows only what
  is ahead. Why: what cannot be seen is filled in by fear. Break it when: horror in plain daylight,
  where the threat is in full view.
- **hunter-backs-off**: One threat hunts by sight and sound, searches where it last saw the player,
  and backs off for a while after a long chase. Why: tension rises and falls instead of becoming
  constant noise. Break it when: no hunter at all, the horror is in the place.

## Feel variants

- **dread**: Slow dread: long quiet, one hunter, sounds that might be nothing.
- **action-horror**: Tense fights: more monsters, just enough ammo, aim that has to hold steady.
- **helpless**: Helpless: no weapon at all, only hiding and running.

## Choices that shape the pitch

- **The threat:** one hunter that stalks you (default) · many slow monsters to fight or avoid ·
  something watched on cameras that comes closer while you look away, as in Five Nights at Freddy's.
- **Weapons:** a few, with scarce ammo (default) · none, hide and run · one that is loud and draws
  the hunter.
- **What the player sees:** over the shoulder, `orbit` (default) · through the eyes, `first` · from
  above, seeing only what the character sees, `topdown` · a room and its cameras, `static`.
- **Saving:** in the safe room (default) · a save costs an item · checkpoints.
- **Feeling:** the player feels psychological dread by listening for the hunter while searching a
  room, because looking costs attention and the sound comes before the sight.

## Later, beyond the first slice

- A hunter that learns where you hide → not verified in Studio yet: ask for it after play and the agent will try it without a verified path
- A mansion of locked doors, keys and puzzles → grow it across later milestones
- A story told through notes and changed rooms → grow it across later milestones
- An inventory of shapes that fit a grid → iterate on it after play, in the same project
- Easier encounters after repeated deaths → iterate on it after play, in the same project
- Sound blocked by walls and doors → add it as its own feature milestone
- Hiding from a hunter that hears the microphone → not verified in Studio yet: ask for it after play and the agent will try it without a verified path
- Co-op horror with voice → needs a server: not built by Studio; offer the local stand-in from `ada-genres`
- A remixed second playthrough → grow it across later milestones

## In a mashup

Horror leads what the player can know and the pace of threats. A shooter leads aiming and gun
feedback, survival leads scarcity and the inventory, and no game stacks every mercy rule or every
awareness limit by default. Co-op leads rescue and communication, and horror the local threat.
Stealth leads detection, and horror the pace. A walking sim leads the story.

---

Adapted from Donchitos/Claude-Code-Game-Studios (MIT): `.claude/genres/chipsets/survival-horror.md` @ abc0de7. See `NOTICE.md` beside the skills root.
