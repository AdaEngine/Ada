---
name: ada-genre-sandbox
description: "An open space of materials and tools to make, break or play with, and no set goal. Genre defaults for Ada Studio game builds; matches briefs such as: creative sandbox, physics sandbox, destruction sandbox, voxel building, crime sandbox, a game like Minecraft creative, Garry's Mod or Teardown"
---

# Genre: sandbox
*Part of the genre library: load `ada-genres` for matching, the camera-token legend and online stand-ins; `ada-genres-mashups` when the idea joins genres.*

There is no tested way to build deep simulation yet: a first slice sandbox is one small space with a
few materials and tools whose rules are few and readable, never a whole simulated world.

**Camera:** `first`, building and breaking up close; `orbit` around a small build site;
`follow2d` for a side view of falling sand and powders.

## Design defaults

- **few-materials**: A small set of materials, each with one plain property (wood burns, stone is
  heavy, glass shatters), that act the same everywhere. Why: the player invents uses from rules they
  can predict. Break it when: a building toy where materials differ only in look.
- **try-list**: The game opens straight into the space with every tool ready and a short list of
  things to try, ticked off as they happen and never required. Why: no goal, but never a blank page.
  Break it when: the user wants set challenges, a bridge that must hold.
- **undo-and-reset**: One key undoes the last thing placed or broken, and one puts the whole space
  back. Why: experiments are free, so the wild idea gets tried. Break it when: the mess is meant to
  stay, a town that remembers the trouble you caused.

## Feel

- **chain-reactions**: What you set going keeps going: fire spreads along wood, a pushed stack
  topples into the next, a spark sets off a barrel. Why: watching your setup play out is the reward.
  Break it when: a calm building toy where nothing moves once placed.
- **breaks-with-weight**: Broken things split into pieces thrown along the hit, each material with
  its own crack and thud, and the debris stays a while. Why: destruction reads as physical, and the
  space remembers what you did. Break it when: nothing breaks, a building toy.
- **snap-build**: Placed pieces snap to a grid with a ghost preview and join their neighbours
  neatly. Why: anyone can build something that looks right. Break it when: loose props are the toy,
  a pile of objects to fling and stack.
- **build-then-use**: One key switches from building to using what you built, at once: the cart
  rolls, the tower is climbed, the trap goes off. Why: a creation matters when it does something.
  Break it when: the build is the art, a model to look at.

## Feel variants

- **builder**: Calm builder: snapping blocks, placed pieces that stay put, a tidy grid.
- **toybox**: Physics toybox: loose props with weight that roll, stack, tip and fall.
- **wrecker**: Wrecker: everything breaks into pieces, fire spreads, and the mess is the fun.

## Choices that shape the pitch

- **The toy:** blocks to build with (default) · props to fling and stack · a built place to tear
  down · a town that reacts to trouble, a crime sandbox (There is no tested way to build most of it
  yet).
- **Goals:** none, a list of things to try (default) · set challenges, a bridge that must hold a
  cart · a need to survive, which makes it the survival-crafting genre.
- **The space:** one small hand-made yard (default) · a generated patch of land.
- **What the player sees:** first person, `first` (default) · around a build site, `orbit` · a side
  view of falling sand, `follow2d`.
- **Feeling:** the player feels creative ownership by building something and then using it, because
  the pieces snap together easily and the thing works.

## Later, beyond the first slice

- A world that keeps running out of sight → not verified in Studio yet: ask for it after play and the agent will try it without a verified path
- People and police who react to trouble → not verified in Studio yet: ask for it after play and the agent will try it without a verified path
- Vehicles you build and drive → not verified in Studio yet: ask for it after play and the agent will try it without a verified path
- Ragdoll bodies that stumble and fall → not verified in Studio yet: ask for it after play and the agent will try it without a verified path
- Buildings that collapse when their supports go → not verified in Studio yet: ask for it after play and the agent will try it without a verified path
- Wires, switches and logic → add it as its own feature milestone
- Saving creations and loading them again → iterate on it after play, in the same project
- Building together with friends → needs a server: not built by Studio; offer the local stand-in from `ada-genres`

## In a mashup

The sandbox leads materials and what the tools do to them. Survival-crafting leads needs and
threats, and the materials become recipes. A puzzle half leads goals, and checks that each challenge
can be solved. Racing leads handling when you drive what you built. A management half leads money
when building costs.

---

Adapted from Donchitos/Claude-Code-Game-Studios (MIT): `.claude/genres/chipsets/sandbox.md` @ abc0de7. See `NOTICE.md` beside the skills root.
