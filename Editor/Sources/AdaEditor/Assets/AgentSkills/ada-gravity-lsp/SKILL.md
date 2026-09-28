---
name: ada-gravity-lsp
description: Inspect and navigate AdaScript (.ada) and Gravity (.gravity) source with AdaEditor's Gravity language service.
allowed-tools: files.read, files.write, editor.project.context, editor.gravity.diagnostics, editor.gravity.completion, editor.gravity.hover, editor.gravity.definition, editor.output.read
---

# Gravity LSP

- Use the opened document when the agent is editing it; pass a project-relative `path` for another `.ada` or `.gravity` file.
- Use `editor.gravity.diagnostics` after source changes and before calling a change validated. These are language-service diagnostics; use the AdaScript build workflow separately for project-level validation.
- Use `editor.gravity.completion`, `editor.gravity.hover`, and `editor.gravity.definition` to ask the same project-aware Gravity workspace service used by AdaEditor.
- Positions are zero-based LSP coordinates. `character` counts UTF-16 code units, including when the line contains emoji or other non-BMP characters.
- Gravity tools do not apply edits. Make changes through the open document or project file workflow, then request diagnostics again.
- `.ada` and `.gravity` use Gravity tooling. Keep Swift files on SourceKit-LSP.
