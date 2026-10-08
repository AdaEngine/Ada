# Building Ada

This guide covers two scenarios:
- Development build for working on Ada itself.
- Using Ada as a dependency in your own app.

## Requirements

- Swift 6.2 toolchain
- Xcode 26.3 (macOS) or Visual Studio Code with the Swift extension
- Git

## Development build

1. Clone the repository:

```bash
git clone https://github.com/AdaEngine/AdaEngine.git
cd AdaEngine
```

2. WebGPU (first build). If you plan to use WebGPU, run the tint build plugin once (this executes `Plugins/WebGPUTintPlugin/WebGPUTintPlugin.swift`):

```bash
swift package plugin build-tint
```

This command downloads the Dawn/Tint sources from GitHub and builds the `tint` binary. SwiftPM will ask to allow network access for the plugin. Confirm the prompt to proceed.

3. Open `Package.swift` in Xcode 26.3, or build from the command line:

```bash
swift build
```

4. Run tests:

```bash
swift test --parallel
```

5. (Optional) Run SwiftLint if you have it installed locally:

```bash
swiftlint --config .swiftlint.yml
```

## Using Ada in your app

### Xcode

1. Open your project in Xcode 26.3.
2. Go to `File > Add Packages...`.
3. Enter the package URL: `https://github.com/AdaEngine/AdaEngine.git`.
4. Choose a version range and add the package to your app target.
5. Import the module in your code:

```swift
import AdaEngine
```

### Swift Package Manager

Add Ada to your `Package.swift`:

```swift
// Package.swift
let package = Package(
    name: "MyGame",
    dependencies: [
        .package(url: "https://github.com/AdaEngine/AdaEngine.git", from: "X.Y.Z")
    ],
    targets: [
        .target(
            name: "MyGame",
            dependencies: ["AdaEngine"]
        )
    ]
)
```

Replace `X.Y.Z` with the latest release tag.

If your app enables WebGPU, run the tint build plugin once in the Ada package directory before the first build:

```bash
swift package plugin build-tint
```

SwiftPM will ask to allow network access for the plugin. Confirm the prompt to let it download the Dawn/Tint sources.

## Exporting a Web app

Ada includes an experimental WebAssembly export command for browser-hosted games.

Requirements:

- Swift 6.3.2 release toolchain.
- `swift-6.3.2-RELEASE_wasm` installed with `swift sdk install`.
- A game executable product that depends on `AdaEngine`. Add `AdaWeb` if the app needs browser-specific helpers.

Swift.org documents the current WebAssembly SDK installation flow at:
<https://www.swift.org/documentation/articles/wasm-getting-started.html>

Export a package product:

```bash
swift package --allow-writing-to-package-directory \
  export-web \
  --product MyGame \
  --output dist/web
```

If several WASM SDKs are installed, pass the SDK id explicitly:

```bash
swift package --allow-writing-to-package-directory \
  export-web \
  --product MyGame \
  --swift-sdk swift-6.3.2-RELEASE_wasm
```

The plugin emits `index.html`, `main.js`, `runtime.mjs`, the built `.wasm`, `package.json`, `ada-web-manifest.json`, `ada-resource-manifest.json`, copied SwiftPM resource bundles, and copies a package-level `Assets` directory when present. Use `npm install && npm run serve` in the output directory to serve the bundle locally.
