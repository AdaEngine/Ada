# Example AdaScript library

Copy this directory into the root of a new GitHub repository, choose your own library ID,
commit the files, and create a release tag such as `v1.0.0`.

In AdaEditor, open **Settings → Project → AdaScript Libraries** and install that repository
at the tag or commit. In the game's AdaScript code:

```swift
import { remainingHealth } from "@example.gameplay/Sources/Health";
```

`remainingHealth(100, 25)` returns `75`. See the engine's **AdaScript Libraries** documentation
for dependencies, offline sharing, systems, and platform limitations.
