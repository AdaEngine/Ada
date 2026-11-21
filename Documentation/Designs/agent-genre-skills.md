# Agent Genre Skills

Status: proposed (Enrich complete, awaiting human approval)
Task kind: feature

## Context

Studio ships bundled agent workflow skills from
`Editor/Sources/AdaEditor/Assets/AgentSkills/` (19 skills today). `ada-game-builder`
and `ada-autonomous-studio` tell the agent how to build and verify a game, but the
bundled catalog contains no game-design genre knowledge: no genre defaults, no
game-feel rules, no mashup or art-direction guidance.

The MIT-licensed project [Claude-Code-Game-Studios](https://github.com/Donchitos/Claude-Code-Game-Studios)
(copyright (c) 2026 Donchitos) publishes a curated genre knowledge base under
`.claude/genres/`:

- `chipsets.yaml` — 69 genres with an `is` line (core verb), a `matches` line
  (brief wording that maps to the genre) and a `variety` floor (minimum enemy
  kinds for a first slice, marked as hypotheses).
- `chipsets/<name>.md` — one sheet per genre: camera default, card defaults,
  Feel rules (each with "why" and "break it when"), feel variants, pitch-shaping
  choices, "later, never in a one-shot" growth lines, and the genre's role in a
  mashup.
- `mashups.md` — combining two genres by per-system ownership, with the "seam"
  concept.
- `art-direction.md` — per-game art direction rules and a brief form
  (Mood / Camera and scale / Shapes / Values / Palette / Detail / Rules /
  Signature).
- `online-and-devices.md` — five levels of online play with local stand-ins.
- `sources.md` — traceability of sheet lines to interviews, manuals and talks.

## Goal

Ship the full genre knowledge base — all 69 genres — as bundled Studio agent
skills, adapted to AdaEngine terminology and verified against engine
capabilities, so that game-building agents apply genre-appropriate defaults for
feel, camera, progression and scope instead of improvising them.

Non-goals: changing `editor.skills.list/read` or any tool implementation;
changing the web exporter; adding engine runtime features; shipping example
projects per genre.

## Settled decisions (Enrich)

1. **Packaging: one skill per genre.** 69 new top-level directories
   `AgentSkills/ada-genre-<name>/SKILL.md`. Rationale: `editor.skills.read`
   returns only `SKILL.md` content, and the web exporter
   (`Editor/WebUI/scripts/agent-resources.mjs`) ships only top-level
   `<dir>/SKILL.md`; auxiliary files would be invisible to agents. Per-genre
   skills need zero code changes and give precise query matching.
2. **IDs: `ada-genre-<name>`** (e.g. `ada-genre-platformer`,
   `ada-genre-tower-defense`), keeping the `ada-` bundled-skill convention.
3. **All 69 genres including online-dependent ones**, with the stand-in policy
   adapted from `online-and-devices.md`: local stand-ins (bots named as bots,
   local leaderboards, daily seeds) are allowed; the skill must state that
   network play is not built and that a stand-in never proves the online game.
4. **Attribution:** a short footer in every adapted `SKILL.md`
   ("Adapted from Donchitos/Claude-Code-Game-Studios, MIT") — the only form that
   survives the web export — plus `AgentSkills/NOTICE.md` with the full MIT
   license text.

## Architecture

New bundled skills (all under `Editor/Sources/AdaEditor/Assets/AgentSkills/`):

- `ada-genres/SKILL.md` — the router. When a brief names or implies a genre:
  match by meaning using `editor.skills.list` queries (genre words from the
  brief), read the matching `ada-genre-*` skill, apply its defaults, and load
  `ada-genres-mashups` / `ada-genres-art-direction` when the idea joins genres
  or needs a look. Carries the online-level table with stand-ins and the rule
  that genre floors are hypotheses, not measurements.
- `ada-genres-mashups/SKILL.md` — adapted `mashups.md`: per-system ownership,
  the seam, what each parent brings.
- `ada-genres-art-direction/SKILL.md` — adapted `art-direction.md`: the rules
  and the brief form, wired to `ada-autonomous-studio`'s `DESIGN.md`.
- `ada-genre-<name>/SKILL.md` × 69 — one adapted chipset sheet each. Front
  matter `description` carries the genre's `is` essence and `matches` wording
  so `editor.skills.list` query matching finds it from natural briefs.
- `AgentSkills/NOTICE.md` — MIT license text and attribution for the adapted
  content.
- `AgentSkills/ada-genres/SOURCES.md` — the upstream `sources.md` kept for
  traceability. Ships inside the native bundle (`.copy("Assets")`) but is not
  readable through agent tools; the router says where it lives in the
  repository.

Content adaptation rules for every genre sheet:

- Source terminology maps to Studio concepts: "the card" → the `DESIGN.md`
  brief of `ada-autonomous-studio`; "one-shot" → the first playable slice;
  "the builder" → `ada-game-builder`.
- Camera tokens (`follow2d`, `orbit`) are replaced by verified engine guidance:
  `Camera2DController`/`CameraTarget2D` in `AdaScene` for 2D follow; 3D orbit is
  authored through scene camera components and scripts. Any camera or API line
  that cannot be verified against the engine is phrased as engine-agnostic
  design intent. No invented API names.
- Feel sections are preserved close to the source (they are engine-agnostic and
  their "why / break it when" framing is the core value), with coyote-time,
  jump-buffering and similar rules expressed as AdaScript-implementable
  behaviors.
- "Later, never in a one-shot" lines keep their growth meaning; lines that
  require servers follow the stand-in policy; lines for capabilities Studio
  does not have are marked "not built by Studio" rather than promised.
- `variety` floors are kept, always labelled as hypotheses, and the router
  suggests them as acceptance-criteria input for `ada-autonomous-studio`.

Integration edits:

- `ada-game-builder/SKILL.md` gains one pointer: when the brief names a genre,
  load `ada-genres` before choosing the slice.
- `ada-autonomous-studio/SKILL.md` gains one pointer: the `DESIGN.md` step uses
  `ada-genres-art-direction`'s brief form and `ada-genres-mashups` for joined
  genres.
- `Editor/Documentation/AgentGuides/agent-tools.md` capability inventory
  updated for the genre skills.

No Swift, WebUI or exporter code changes. `Package.swift` already ships
`.copy("Assets")`; new skill directories need no manifest edits. The web
exporter picks up new top-level skill directories automatically.

## Alternatives considered

- **Family-grouped skills (~8–10 files):** smaller catalog, but every read
  loads unrelated genres and `editor.skills.list` query matching becomes
  coarse. Rejected.
- **Offline documentation articles:** genres are workflow knowledge, not engine
  documentation; mixing them into `editor.docs.search` results blurs the docs
  bundle's purpose and requires generator input changes. Rejected.
- **Tool/exporter support for skill auxiliary files:** real code change and
  new contract surface for no behavioral gain over per-genre `SKILL.md` files.
  Rejected.

## Constraints and risks

- Catalog growth from 19 to ~92 skills: `editor.skills.list` without a query
  returns every entry (id/name/description only, ~10 KB) — acceptable; the
  router instructs agents to always pass a query.
- Adaptation fidelity: 69 sheets must not invent engine APIs. Mitigation:
  engine-agnostic phrasing by default, verified engine references only, and a
  test asserting the expected skill inventory and metadata.
- Upstream drift: the adapted content is a snapshot of the MIT source at
  import time; `NOTICE.md` records the upstream revision. Resyncing is a
  separate future task.
- Mobile hosts: the same `EditorAgentSkillStore` backs the mobile catalog;
  verified by the discoverability test that runs against the shared store.

## Platform impact

Desktop (SwiftPM bundle), mobile (same bundled store) and web (exporter
iterates top-level skill directories) all pick up the new skills without code
changes. No engine runtime, GPU or platform-wrapper impact.

## Acceptance criteria

1. `editor.skills.list` with genre-word queries (e.g. "platformer",
   "metroidvania", "tower defense", "roguelike", "tycoon") returns the matching
   `ada-genre-*` skills; all 69 expected IDs are discoverable.
2. Every bundled skill has non-empty front-matter `name` and `description`
   (required by the web exporter).
3. Every `ada-genre-*` skill carries the MIT attribution footer; `NOTICE.md`
   exists with the full license text.
4. Router, mashups and art-direction skills reference each other and
   `ada-game-builder` / `ada-autonomous-studio` coherently; no genre sheet
   names an API that does not exist in the engine (spot-checked sample per
   camera/feel claim).
5. User-facing documentation delivered (below) and linked from the declared
   navigation.
6. `python script/check_contribution.py` stages pass, including Swift Testing
   for the new catalog tests.

## User documentation plan

- Article: new `Editor/Documentation/AgentGenreSkills.md` — what the genre
  skills are, how agents discover and apply them, the genre list, the online
  stand-in policy, limitations (hypothesis floors, no network play) and the
  MIT attribution.
- Navigation: `Editor/Documentation/AgentCatalog.md`, section "Built-in game
  building workflow", updated to describe the genre skills and link the
  article.
- The offline documentation snapshot inputs are unchanged (`AgentCatalog.md`
  is not bundled offline), so `update-offline-documentation.py` needs no input
  changes; its `--check` still runs in validation.

## Testing

TDD with Swift Testing in `Editor/Tests/AdaEditorTests` (new suite, e.g.
`EditorAgentGenreSkillTests.swift`):

- Red: tests assert the 69 expected `ada-genre-*` IDs, router/mashups/
  art-direction IDs, query matching for representative genre words, non-empty
  metadata and attribution footers — failing before the skills exist.
- Green: add the skills; the same tests pass.
- Web export: unchanged exporter covered by the existing
  `agent-resources.test.mjs` fixture test; no new web code to test.
