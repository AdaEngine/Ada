# AdaUI animation transactions and presentation transitions

AdaUI supports `withAnimation`, `Binding.animation`, `.animation(_:value:)`,
`withTransaction`, and `.transaction(_:)`. A transaction applies to one update.
Deferred Observation invalidations capture that update's transaction; unrelated
asynchronous tasks do not retain it after the synchronous scope ends.

`GeometryReader` and observable custom layouts retain the update policy until
their deferred layout pass. Nested implicit animations reuse the same controller
and advance once per frame; independent subtrees retain their own durations.
A subsequent unanimated update does not reuse an earlier animation transaction.

```swift
withAnimation(.easeInOut(duration: 0.3)) {
    path.append("details")
}

withAnimation(nil) {
    isPresented = false
}

var transaction = Transaction()
transaction.disablesAnimations = true
withTransaction(transaction) {
    selection = nextSelection
}
```

`animation(_:value:)` supplies an animation when its monitored value changes.
Other updates inherit the current transaction. An unrelated change must still
update immediately when there is no animation. `disableAnimation()` suppresses
animations in a subtree, including the built-in presentation transitions.

## Built-in presentation transitions

- `NavigationStack` pushes from the trailing side and pops toward the trailing
  side. Screens retained along the current path preserve their view state.
- `TabView` uses fade and scale for both default and custom tab styles. Cached
  tab content is reattached when selected again.
- `sheet(isPresented:)` and `sheet(item:)` present a centered, size-constrained
  modal with a dimmed backdrop, fade, and scale.
- `fullScreenCover` slides the presented content vertically.

These containers animate by default using a 0.28-second ease-in-out curve.
An explicit transaction can change the animation or disable it with `nil`.
Sheets and covers use the modified view as their presentation host. Attach these
modifiers to the root content container when they should cover the entire window.
Initial mounting does not animate. Closing a sheet or cover retains the outgoing
content until the transition finishes, even when its item binding is already nil.

```swift
content
    .sheet(isPresented: $showSettings) {
        SettingsView()
    }
    .fullScreenCover(isPresented: $showPlayer) {
        PlayerView()
    }
```

Presentation transitions interpolate drawing transforms and opacity while
keeping layout at the destination size. Hit testing uses the inverse presentation
transform. Outgoing screens do not receive new input; modal backgrounds remain
blocked during dismissal. `onDisappear` and task cancellation happen when the
outgoing subtree is detached at completion. A reversal starts from the current
presentation, preserving retained nodes.

The generic frame-animation path still runs layout for size changes; it is
separate from these container presentation transitions.

## Demo and validation

The demo lives in AdaExamples at
`Examples/EngineDemos/Demos/UI/NavigationTransitionsExample.swift`. Run its adjacent
`run-navigation-transitions.sh` on macOS with an AdaEngine revision containing
these APIs. Add `--autoplay` to cycle
through push, pop, tabs, sheet, and cover with slower transitions for inspection.
The script stages and launches a SwiftPM `.app` bundle in a task-local scratch
folder. Set `ADA_UI_TRANSITIONS_BUILD` to choose a different scratch directory.

Focused tests live in `TransactionScopeTests`, `PresentationTransitionTests`,
`AnimationRuntimeRegressionTests`, and `UIAnimationControllerTests`. Existing
animation, navigation, tab, and visibility tests cover the integration paths.
