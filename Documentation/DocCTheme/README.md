# AdaEngine DocC Theme

The visual system is intentionally quiet: neutral surfaces, fine separators, compact navigation, and a restrained AdaEngine violet for links and focus. Light and dark appearances use the same structure and contrast hierarchy. API references and tutorials share the same flat surfaces and modest corner radii.

The DocC archive is themed after generation so the source documentation stays compatible with standard DocC tooling.

```sh
node scripts/apply-docc-theme.mjs docs
```

The command copies the palette and runtime assets into the archive and injects them into every generated HTML entry point. It is idempotent and preserves an optional DocC hosting base path. The stylesheet covers both API documentation and DocC's tutorial overview, chapter, step, code-preview, assessment, and next-tutorial surfaces.

AdaScript code fences use the Markdown language identifier `ada`. DocC keeps this as `data-syntax="ada"`; the theme runtime adds Gravity-compatible keyword, annotation, type, string, number, punctuation, and nested-comment highlighting after initial load and client-side navigation.
