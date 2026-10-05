# AdaEditor

AdaEditor is a standalone SwiftPM package for the AdaEngine editor. It contains the `AdaEditor` executable target, UI resources, and tests for editor logic.

## Structure

- `Package.swift` — the editor package manifest.
- `Sources/AdaEditor` — the editor application's source code.
- `Sources/AdaEditor/Assets` — editor assets, including images and fonts.
- `Tests/AdaEditorTests` — editor tests.
- `project.yml` — the XcodeGen configuration for generating the Xcode project.

## Dependencies

The package depends on:

- the local `AdaEngine` package in the parent directory (`.package(path: "..")`).

## Building and Testing

Run the following commands from the `Editor` directory:

```bash
swift build
swift test
```

## Generating the Xcode Project

Install XcodeGen if it is not already installed, then run:

```bash
cd Editor
xcodegen generate
open AdaEditor.xcodeproj
```

The generated project uses the local `AdaEditor` SwiftPM package. To build and run the editor, select the `AdaEditor (Editor)` scheme that Xcode creates for the package's executable product.

## Command Line

The standalone macOS bundle also includes the `adastudio` command-line entry for
project inspection, validation and AdaScript app builds. See [CLI](Documentation/CLI.md)
for commands, SDK prerequisites and the JSON contract. iOS uses its existing
embedded validation and Play services.

## TestFlight

Fastlane can build a signed iPadOS IPA (`bundle exec fastlane ios build`) or build
and upload it (`bundle exec fastlane ios beta`). See
[TestFlight setup](fastlane/SETUP.md) for signing prerequisites, versioning, and
private environment variables. No credentials belong in the public repository.

## Offline Documentation

Open **Help > AdaEngine Documentation**, or use the **Documentation** button on the welcome screen or editor toolbar. The native SwiftUI reader includes full-text guide search, section navigation, Back/Forward history, and copyable code examples. On macOS it opens a reusable window; on iPadOS it opens an in-app reader with a Done button.

The bundled library contains the editor guide and substantive Markdown articles from the AdaEngine and AdaScripting DocC catalogs. It works without internet or a source checkout. Generated API reference pages and external websites are not bundled; external links are labeled **Internet**.

After changing a source article, regenerate and verify the checked-in snapshot:

```bash
python3 scripts/update-offline-documentation.py
python3 scripts/update-offline-documentation.py --check
```

The snapshot lives in `Sources/AdaEditor/Assets/Documentation/catalog.json` and ships through the existing SwiftPM `Assets` resource copy, including the macOS and iPadOS app wrappers. The generator preserves code examples, removes DocC presentation metadata, and validates internal article links.

### Android

Standalone macOS Studio supports **Build → Export to Android…** and Android
Run Destinations with connected devices and AVDs. Swift and AdaScript projects
use the native Swift/WebGPU Android host. Configure **Settings → Android** and
see [Android export and run](Documentation/Android.md).
