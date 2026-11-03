# Contributing to AdaEngine

Thanks for considering a contribution. We welcome fixes, features, docs, and examples.

## Requirements

- Swift 6.2 toolchain
- Xcode 26.3 (macOS) or Visual Studio Code with the Swift extension
- Git

## Getting started

1. Fork the repo and clone your fork.
2. Create a topic branch from `main`.
3. Make your changes with focused commits.

## Development workflow

Follow [the contributor workflow](Documentation/Designs/contributor-workflow.md) and
[the command guide](.agents/knowledge/workflow.md). These requirements apply to humans and agents.

- A new standalone capability follows Task → Enrich → Design → human approval → Plan → Code → Review.
  Design documents are English-only and must be given to the human for explicit approval before proceeding.
- Extending/reworking an existing subsystem is an improvement, including adding a new serializer format.
  Update its design, or create a concise design if missing. Fixes within an existing contract do not
  require a separate set of permanent task documents.
- Implement testable behavior with [TDD](.agents/skills/adaengine-tdd/SKILL.md), run scripted checks,
  and obtain [independent subagent review](.agents/skills/adaengine-review/SKILL.md). The reviewer
  returns implementation defects and escalates necessary design changes to the human.

Set up the tools explicitly in a Python 3.11+ virtual environment. The standard-library runner
retains Python 3.9 compatibility; the full analyzer dependencies require a newer interpreter:

```text
python -m venv .build-tools/contribution-venv
# Activate that environment, or use its Python executable directly.
python -m pip install -r script/contribution-requirements.txt
python script/check_contribution.py plan
python script/check_contribution.py check
python script/check_contribution.py install-hooks
```

The final command opts into pre-commit/pre-push checks and preserves existing hooks, including Git LFS.
Full logs remain under ignored `.build-tools/contribution/`; summaries list passed/failed/blocked checks.
Missing tools or required platform evidence prevent completion. Hooks do not replace required CI checks.
See [the knowledge base](.agents/knowledge/README.md) for architecture, Swift, platform, and security guidance.
See [validation operations](Documentation/ContributorValidation.md) for workflow and documentation delivery commands.

## Build and test

```bash
swift build
```

```bash
swift test --parallel
```

SwiftLint runs as a SwiftPM plugin on supported platforms. If you have SwiftLint installed locally, you can also run:

```bash
swiftlint --config .swiftlint.yml
```

## Code style and conventions

- Follow SwiftLint rules and keep imports minimal.
- Prefer structured concurrency with `async`/`await` and `@Sendable` closures.
- Use `@MainActor` for UI and platform-facing code.
- Avoid global mutable state; prefer actors or atomics when sharing data.

## Documentation

- Update DocC pages for user-facing changes.
- Every feature includes a discoverable user-facing article or a substantial update to its relevant guide.
  Include setup/usage, a verified example, supported platforms, limitations and material performance costs.
  Plan article/navigation alongside the feature, ship it with the code, and have the independent reviewer
  check its accuracy. ADRs, design files and API comments are not substitutes. For example, ray tracing
  needs a usable guide explaining activation, backend support and fallbacks.
- Keep examples short and focused.

## Submitting a pull request

1. Ensure tests pass and new behavior is covered by tests when practical.
2. Write a clear PR description with context and a brief summary of changes.
3. Link relevant issues or discussions.

If a change is large or user-visible, consider opening an issue first to align on scope.

## AI-assisted contributions

Using AI tools is allowed, but the author remains responsible for correctness and quality. When AI is used:

1. Verify code style and conventions match this project.
2. Evaluate any performance impact from AI-generated changes.
3. Review all AI-generated code and text for hallucinations, contradictions, and broken logic.
4. Do not share private data, secrets, or proprietary code unless policy explicitly allows it.
5. Validate licenses and provenance of generated code or suggested dependencies.
6. Confirm APIs exist and usage matches real types and symbols in the codebase.
7. Run relevant tests and linting (at minimum SwiftLint and the affected tests).
8. Add or update tests when behavior changes.
9. Avoid broad refactors suggested by AI unless there is a clear, agreed-upon reason.
10. If AI meaningfully contributed, mention it in the PR description for transparency.
