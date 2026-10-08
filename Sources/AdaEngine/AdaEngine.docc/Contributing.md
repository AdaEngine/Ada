# Contributing to Ada

We welcome contributions of all kinds: bug fixes, features, documentation, and examples.

## Quick start

1. Fork the repository and create a topic branch from `main`.
2. Make your changes and keep commits focused.
3. Run the test suite:

```bash
swift test --parallel
```

4. Open a pull request with a clear description of the change.

## Requirements

- Swift 6.2 toolchain
- Xcode 26.3 (macOS) or Visual Studio Code with the Swift extension

## Code style

- SwiftLint is enforced via the SwiftPM build tool plugin.
- If you have SwiftLint installed locally, you can run it directly:

```bash
swiftlint --config .swiftlint.yml
```

## Tests

- Add or update tests for behavioral changes when practical.
- Prefer targeted tests over broad refactors.

## More details

For the full contributing guide, see:\n- [CONTRIBUTING.md](https://github.com/AdaEngine/AdaEngine/blob/main/CONTRIBUTING.md)
