---
name: ada-genre-pet-raising
description: "Raise and care for a creature that grows from how you treat it. Genre defaults for Ada Studio game builds; matches briefs such as: virtual pet, creature raising, creature simulation, a game like Tamagotchi, Neko Atsume or Viva Piñata"
---

# Genre: pet-raising
*Part of the genre library: load `ada-genres` for matching, the camera-token legend and online stand-ins; `ada-genres-mashups` when the idea joins genres.*

**Camera:** `static`, one room or garden that fits the window; `topdown` for a garden to walk
around.
**Research:** needs primary research: the source research has one creature-raising entry, a Later one, and
a few entries on caring for an animal or a companion. It has no entry for a pet that grows through
stages shaped by its care, or for a pet's mood shown in its face and body.

## Design defaults

- **few-needs**: A pet has a few needs, food, play and rest, each a bar that falls slowly, and one
  care action fills each. Why: the player always knows what the pet wants. Break it when: the
  creature has no needs, one to watch and pose.
- **sad-not-lost**: A neglected pet turns sad and grows slower, but never falls sick or leaves. Why:
  the player can step away and come back without guilt. Break it when: the user wants the old
  pocket-pet stakes, a pet that can be lost.

## Feel

- **pet-answers**: Petting, feeding or playing gets an instant answer, a hop, a purr, a burst of
  hearts, different for each action and each mood. Why: care feels returned, so the player wants to
  give more. Break it when: the aloof pet is the joke, a cat that ignores you.
- **alive-when-idle**: Left alone, the pet wanders, naps, plays with a toy and watches the cursor.
  Why: it seems alive, not a menu waiting for clicks. Break it when: a tiny pocket-pet screen of a
  few pixels is the look.

## Feel variants

- **doting**: Doting: one pet, lots of petting and play, a reaction to everything.
- **visitors**: Visitors: put out food and toys, and creatures drop by while you are away.
- **garden**: Garden: plant the right things, and the creatures that like them move in.

## Choices that shape the pitch

- **The creature:** one pet raised from an egg (default) · visitors drawn by what you leave out, as
  in Neko Atsume · a garden of creatures that move in, as in Viva Pinata.
- **Stakes:** a sad pet, never a lost one (default) · a pet that falls sick and needs a cure · a
  pet that runs off if neglected long enough.
- **Time:** only while the game is open (default) · on the real clock while you are away, capped
  (away time).
- **What the player sees:** one room, `static` (default) · a garden to walk, `topdown`.
- **Feeling:** the player feels affection by caring for the pet and seeing it answer, because every
  action gets a reaction and the pet grows from their care.

## Later, beyond the first slice

- Breeding and passing looks on → add it as its own feature milestone
- Many pets with their own wants that meet and squabble → not verified in Studio yet: ask for it after play and the agent will try it without a verified path
- Creatures whose own legs find their way over any ground → not verified in Studio yet: ask for it after play and the agent will try it without a verified path
- A shop of food, toys and outfits → iterate on it after play, in the same project
- Mini-games to play with the pet → iterate on it after play, in the same project
- Pets shown to friends or entered in contests → needs a server: not built by Studio; offer the local stand-in from `ada-genres`
- Where the pet came from, told as a story → grow it across later milestones

## In a mashup

Pet raising leads care, needs and growth. A creature collector leads catching and battles, and care
fills the time between them. A farming half leads the day, and the creatures help with the work. An
idle game leads the real clock and time away. A racing or fighting half leads its contest, and care
sets the pet's strengths.

---

Adapted from Donchitos/Claude-Code-Game-Studios (MIT): `.claude/genres/chipsets/pet-raising.md` @ abc0de7. See `NOTICE.md` beside the skills root.
