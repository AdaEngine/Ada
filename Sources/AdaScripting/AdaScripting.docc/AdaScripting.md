# ``AdaScripting``

Write gameplay systems in Ada Script while keeping entity filtering and access planning in AdaEngine's native ECS.

@Metadata {
    @DisplayName("Ada Script")
}

## Overview

Ada Script is AdaEngine's scripting layer for gameplay and declarative AdaUI. Its source files use the `.ada` extension. The current implementation uses an embedded language runtime, while the public API, diagnostics, and tooling consistently present Ada Script concepts.

Annotations are not only syntax. AdaEngine resolves every query into native archetypes and component columns and publishes its component access to the scheduler.

Use Ada Script for gameplay rules that benefit from quick iteration. Keep rendering backends, custom data structures, and other low-level or performance-critical facilities in Swift.

```ada
@system(scheduler: "update")
class MovementSystem {
    @query(Transform, Movement)
    var movers;

    func update(context) {
        for (var entity in movers) {
            var position = entity.transform.position;
            var velocity = entity.movement.velocity;
            position[0] += velocity[0] * context.deltaTime;
            position[1] += velocity[1] * context.deltaTime;
            entity.transform.position = position;
        }
    }
}
```

AdaEditor projects configure automatic script discovery by default. For an existing Swift package, follow <doc:GettingStartedWithAdaScript> to enable the build plugin and register the generated script plugins.

## Topics

### Essentials

- <doc:GettingStartedWithAdaScript>
- <doc:AdaScriptLanguage>
- <doc:AdaScriptAnnotations>
- <doc:AdaScriptLibraries>

### ECS Integration

- <doc:AdaScriptECS>
- <doc:AdaScriptDiagnosticsAndPerformance>

### User Interfaces

- <doc:AdaScriptViews>

### Runtime API

- ``AdaScriptPlugin``
- ``AdaScriptSource``
- ``AdaScriptError``
- ``AdaScriptView``
- ``AdaScriptViewRegistry``
