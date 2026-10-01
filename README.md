<p align="center">
  <a href="https://adaengine.org">
    <img src="Assets/ae_github_logo.png" alt="Ada logo">
  </a>
</p>

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/AdaEngine/Ada/blob/main/LICENSE)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FAdaEngine%2FAdaEngine%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/AdaEngine/Ada)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FAdaEngine%2FAdaEngine%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/AdaEngine/Ada)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/AdaEngine/Ada)


## What is Ada?

Ada is a game engine fully written in Swift. The main idea is to encourage Swift developers to use this game engine to create fast and impressive games and user interfaces using Swift as their main language. We hope that Ada can become as popular in the GameDev community as Rust and C# are.

<p align="center">
  <a href="https://adaengine.org">
    <img src="Assets/ada-editor.png" width="700" alt="Ada Studio">
  </a>
</p>

## Design Goals

* **Capable:** Offer a complete 2D feature set.
* **ECS:** Ada is based on the data-oriented paradigm using a self-written ECS. Ada has been inspired by Apple's RealityKit framework.
* **Simple:** Ada is easy to use, and our main goal is to enable a quick start and deliver quick results.

## 📕 Docs

* **[API Docs](https://docs.adaengine.org/documentation/adaengine/):** Ada's API docs, which are automatically generated from the doc comments in this repo.
* **[Tutorials](https://docs.adaengine.org/tutorials/adaengine/)**: Ada's official tutorials with how to start your first project.
* **Building & Contributing Guides:** [Building](Sources/AdaEngine/AdaEngine.docc/Building.md), [Contributing](Sources/AdaEngine/AdaEngine.docc/Contributing.md)
* **[Architecture Decision Records](Documentation/ArchitectureDecisions/README.md):** Accepted architectural decisions and their implementation status.

## ⭐️ Examples

* **[Ada Awesome Projects](https://github.com/AdaEngine/AdaEngineAwesome)**: Ada's official Awesome Projects page. Feel free to explore.

* **[Ada Examples](https://adaengine.org/demos/)**: Ada's internal examples.

## Getting started

We recommend checking out the **[Create your first project guide](https://docs.adaengine.org/tutorials/adaengine/createproject)** for a brief introduction.

To draw a plain window with standard functionality use:

```swift
import AdaEngine

@main
struct AdaEditorApp: App {
    var body: some AppScene {
        DefaultAppWindow()
            .windowMode(.windowed)
            .windowTitle("Ada")
    }
}
```

## 👥 Community

If you want to discuss this library or have a question about how to use it to solve a particular
problem, there are a number of places you can discuss with fellow

  * For long-form discussions, we recommend the
    [discussions](http://github.com/AdaEngine/Ada/discussions) tab of this
    repo.

## 👨‍💻 Contributing to Ada

You are welcome to contribute to Ada. Currently, it is under development, and we are working towards our roadmap goals. If you find a bug or have some improvements, we would be glad to see your pull request!
See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## 🛠️ How to build

See the [Building guide](Sources/AdaEngine/AdaEngine.docc/Building.md) for development and integration steps.

Quick start: open `Package.swift` in Xcode 26.3 or build from the command line with `swift build`.
