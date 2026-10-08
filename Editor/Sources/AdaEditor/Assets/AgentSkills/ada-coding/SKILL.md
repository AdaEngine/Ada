---
name: ada-coding
description: Implement and validate Swift, AdaScript, shader, and project-file changes in Ada projects.
allowed-tools: files.read, files.write, terminal, editor.gravity.diagnostics, editor.gravity.completion, editor.gravity.hover, editor.gravity.definition
---

# Ada Coding

- Identify whether the project is AdaScript-only or SwiftPM-backed before selecting commands.
- Follow existing neighboring code, component registrations, plugins, and generated-source contracts.
- For AdaScript, use project diagnostics and the in-process AdaScript build. Do not invent Swift-only APIs.
- For `.ada` and `.gravity` source, use the Gravity LSP skill and editor Gravity tools for diagnostics, completion, hover, and definitions. Keep Swift source on SourceKit-LSP.
- For Swift, use the project package model and the narrowest applicable build or test.
- Preserve unrelated edits and report exact validation scope. Build output is not proof of runtime behavior when the change affects rendering or interaction.
