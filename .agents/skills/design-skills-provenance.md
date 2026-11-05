# Studio UI/UX Guidance Provenance

The practical guidance in [ui-ux-pro-max](ui-ux-pro-max/SKILL.md) is adapted from
[nextlevelbuilder/ui-ux-pro-max-skill](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill)
at revision [b7d5353e0130feb8c5574ef1251f8a1db1873ccb](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill/tree/b7d5353e0130feb8c5574ef1251f8a1db1873ccb).
The original MIT notice is retained in [LICENSE](ui-ux-pro-max/LICENSE).

## Maintained scope

The repository retains two contributor skills for Studio UI work:

- [adaengine-studio-design](adaengine-studio-design/SKILL.md): the local proposal, implementation,
  and review workflow, governed by the [Studio rules](../../AGENTS.md#ada-studio-visual-design-rules).
- [ui-ux-pro-max](ui-ux-pro-max/SKILL.md): curated UI construction and verification covering
  controls, layout, states, forms, focus, accessibility, touch, async feedback, and readable text
  using existing Studio fonts and theme roles.

The skill name remains for existing references. This is a curated local adaptation, not the full
upstream package. Its entrypoint and two references are maintained as Markdown.

## Removed at the contributor's request

The full import was narrowed to practical UI work. Font binaries/catalogs, font pairing,
visual style and palette catalogs, product/landing-page recommendations, branding, banners,
presentations, decorative canvas examples, and external creative generators are removed.
Studio's application font resources are unchanged.

Search/design-system generators, installers, API helpers, datasets, and their tests/fixtures
are removed together with those discarded capabilities. Retained guidance invokes none of those
tools and requires no Python/Node package, credentials, or network service. Validation concerns
maintained skill documents/links; behavior tests and visual checks still belong to the actual
Studio implementation being changed.

This scope reduction does not turn earlier failed upstream checks into passes. Historic results
remain in earlier local reports. Contribution checks must assess the current change honestly,
including tooling limitations caused by removing executable files.

## Updating

Adapt useful interaction/validation guidance deliberately. Preserve Studio's theme, font assets,
Material Icons/Symbols, and platform boundaries. Do not reimport the creative bundle or regenerate
alternative fonts, visual styles, or palettes during routine UI work.
