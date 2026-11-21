# Agent Genre Skills — Implementation Plan

Design: [agent-genre-skills](../Designs/agent-genre-skills.md) (approved 2026-11-21).
Upstream source: `../Claude-Code-Game-Studios/.claude/genres/` (MIT, revision
`abc0de7`, "Release 1.3.0"). The upstream checkout lives outside the repository
and is only read, never modified.

## Owned files

New:

- `Editor/Tests/AdaEditorTests/EditorAgentGenreSkillTests.swift`
- `Editor/Sources/AdaEditor/Assets/AgentSkills/NOTICE.md`
- `Editor/Sources/AdaEditor/Assets/AgentSkills/ada-genres/SKILL.md`
- `Editor/Sources/AdaEditor/Assets/AgentSkills/ada-genres/SOURCES.md`
- `Editor/Sources/AdaEditor/Assets/AgentSkills/ada-genres-mashups/SKILL.md`
- `Editor/Sources/AdaEditor/Assets/AgentSkills/ada-genres-art-direction/SKILL.md`
- `Editor/Sources/AdaEditor/Assets/AgentSkills/ada-genre-<name>/SKILL.md`
  for each of the 69 upstream chipsets (the authoritative name list is the
  upstream `chipsets/` directory; count verified during implementation)
- `Editor/Documentation/AgentGenreSkills.md` (user-facing article)

Modified:

- `Editor/Sources/AdaEditor/Assets/AgentSkills/ada-game-builder/SKILL.md` — one
  pointer line to `ada-genres`
- `Editor/Sources/AdaEditor/Assets/AgentSkills/ada-autonomous-studio/SKILL.md` —
  one pointer line for the DESIGN.md step
- `Editor/Documentation/AgentGuides/agent-tools.md` — capability inventory entry
- `Editor/Documentation/AgentCatalog.md` — navigation: "Built-in game building
  workflow" section links the new article

## Steps

1. **Runner bookkeeping.** Expand task scope with the owned files above
   (`scope --files ...`); declare documentation
   (`documentation --articles Editor/Documentation/AgentGenreSkills.md
   --navigation Editor/Documentation/AgentCatalog.md`).
2. **TDD red.** Write `EditorAgentGenreSkillTests.swift` (Swift Testing):
   - all expected `ada-genre-*` IDs (generated from the upstream chipset list,
     embedded as a literal expected set) plus `ada-genres`,
     `ada-genres-mashups`, `ada-genres-art-direction` are discoverable via
     `EditorAgentSkillStore.discoverSkills`;
   - `editor.skills.list` queries for representative brief words
     ("platformer", "metroidvania", "tower defense", "roguelike", "tycoon",
     "fishing", "rhythm") return the matching genre skill IDs;
   - every bundled skill has non-empty front-matter `name` and `description`;
   - every `ada-genre-*` skill ends with the MIT attribution footer and
     `NOTICE.md` exists in the skills root.
   Record red with `tdd --phase red` running
   `swift test --filter EditorAgentGenreSkillTests` and expecting assertion
   failures (skills do not exist yet). Use an isolated `--scratch-path` if the
   shared `.build` cache mismatches the local toolchain.
3. **Author the shared skills.** `NOTICE.md` (full MIT text + upstream
   revision), `ada-genres/SKILL.md` (router: matching flow, online-level
   stand-in table, hypothesis-floor disclaimer, pointers),
   `ada-genres/SOURCES.md` (upstream `sources.md`, header noting provenance),
   `ada-genres-mashups/SKILL.md`, `ada-genres-art-direction/SKILL.md`.
4. **Author the 69 genre skills.** Per upstream `chipsets/<name>.md`:
   front matter (`name: ada-genre-<name>`, `description` carrying the
   upstream `is` essence and `matches` wording from `chipsets.yaml` for query
   matching); body adapted per the design's adaptation rules (card → DESIGN.md,
   one-shot → first playable slice, builder → ada-game-builder, verified camera
   guidance via `Camera2DController`/`CameraTarget2D` or engine-agnostic
   phrasing, stand-in policy for server features, "not built by Studio" where
   applicable, variety floors labelled as hypotheses); MIT footer last.
   Work in batches by genre family; spot-check every camera/feel engine claim
   against `Sources/AdaScene` and `Sources/AdaEngine` before writing it.
5. **Integration pointers.** One line each in `ada-game-builder/SKILL.md` and
   `ada-autonomous-studio/SKILL.md`.
6. **Documentation.** Write `Editor/Documentation/AgentGenreSkills.md`;
   update `AgentCatalog.md` "Built-in game building workflow" to link it;
   update `AgentGuides/agent-tools.md` inventory.
7. **TDD green + validation.** `tdd --phase green` with the same test command;
   `python script/check_contribution.py run --task agent-genre-skills --stage plan`
   and later `--stage review`; fix findings. No SwiftLint impact expected
   (Markdown/SKILL content + one test file), but lint runs as part of the
   runner profile.
8. **Review and done.** Independent review per `adaengine-review`
   (requires the user's go-ahead for a subagent context in this environment),
   `record-review`, then `verify --stage done`.

## Notes

- `update-offline-documentation.py` inputs are unchanged; run `--check` to
  confirm the snapshot is untouched.
- The pre-existing nested `ada-visual-verification/ada-voxel-models` skill is
  out of scope; noted as an anomaly for a separate task.
