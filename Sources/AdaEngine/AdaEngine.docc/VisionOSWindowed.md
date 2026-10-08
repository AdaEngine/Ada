# visionOS Windowed Mode

Run Ada apps in visionOS Shared Space using the existing `WindowGroup` scene model.

## Overview

Ada's first visionOS milestone is windowed rendering. Apps launch as normal visionOS windows backed by UIKit scenes, `MTKView`, and the Metal render backend. Existing apps that use `WindowGroup` do not need a new public API for this mode.

```swift
import AdaEngine

@main
struct VisionOSWindowedApp: App {
    var body: some AppScene {
        WindowGroup {
            Text("Ada on visionOS")
                .padding()
        }
    }
}
```

Windowed mode intentionally does not create a Full Space, stereo renderer, ARKit session, or `CompositorServices.LayerRenderer` surface. Those belong to a later immersive rendering milestone.
