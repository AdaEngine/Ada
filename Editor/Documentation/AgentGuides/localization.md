# Localization

Read this reference only when the task touches this area. Return to [the editor guide](../../AGENTS.md) for routing and shared rules.

Paths in code spans and commands retain their original `Editor/` working-directory context unless explicitly repository-relative; Markdown links resolve from this file.

This inventory was originally recorded on **2026-10-04** and subsequently maintained. Implementation and test links identify existing coverage, not a validation run or platform acceptance.

## Localization (required for every UI change)

- Ada Studio supports **English (`en`) and Russian (`ru`)**. Always write
  user-facing text for localization, including labels, tooltips, placeholders,
  menus, dialogs, accessibility labels, empty states and app-authored errors.
- Add or update both translations automatically in the same change, under
  `Sources/AdaEditor/Assets/Localization/en.json` and `ru.json`. Do not leave
  Russian translations for a follow-up task. Use clear, friendly Russian that
  a young reader can understand; keep product names and code/API identifiers.
- Use `L10n.text("Text with \(value)")` for interpolated UI messages and
  `L10n.tr(key)` when rendering a stable key supplied by a model or UI helper.
  Preserve numbered placeholders in both catalogs. Never concatenate translated
  sentence fragments or translate user text, source code, file paths, persisted
  enum values, protocol keys or accessibility identifiers.
- `EditorLocalization` owns the saved app language. The default follows the
  system's preferred languages, selecting Russian or English with English as
  fallback. Desktop General > Language and mobile Settings expose System,
  English and Russian; changes update mounted UI through Observation.
- Keep routing, settings page IDs and automation identifiers language-independent.
  Translate at presentation boundaries. Shared AdaUI and native platform UI must
  use the same preference; do not independently check `Locale.preferredLanguages`.
- Run `python ../script/check_studio_localization.py` from `Editor/` and
  `swift test --filter EditorLocalizationTests` after changing
  localized UI. Test switching languages with the existing view mounted, and
  check that longer Russian text fits the affected controls.
