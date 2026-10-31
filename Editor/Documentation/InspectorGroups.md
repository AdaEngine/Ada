# Inspector groups and scene hierarchy

Export groups are explicit authoring metadata. Field-name prefixes and nested
serialization paths do not automatically create inspector sections.

AdaScript components, resources and scriptable objects can declare a section:

```ada
@export(group: "Auto Exposure") var minimumEV = -4.0;
@export(group: "Auto Exposure") var maximumEV = 2.0;
@export(group: "Camera/Auto Exposure") var speedUp = 0.5;
```

Swift components use the same path on the existing property wrapper:

```swift
@Component
struct CameraSettings: Codable, Sendable {
    @Export(group: "Camera/Auto Exposure") var minimumEV: Float = -4
    @Export(group: "Camera/Auto Exposure") var maximumEV: Float = 2
}
```

Paths have one to four nonempty names separated by `/`. Deeper paths and empty
names are diagnosed by the component macro or AdaScript schema parser.
Inspector groups collapse independently and keep their first declaration order.
Each header has a subtle tint derived from a stable hash of its component or
scriptable-object ID and full group path. Colors survive restarts, folding and
language changes; the field text keeps the theme's normal contrast.
Saved field names, payload structure and runtime bindings stay the same. Exported
custom structs are not implicitly expanded by this feature.

Native editor descriptors set `EditorComponentField.groupPath` explicitly.
Environment 3D uses authored sections for Auto Exposure, Bloom, Depth of Field,
Skybox/Starfield and other related settings.

The hierarchy search matches entity names without case sensitivity and includes
their ancestors, even when those branches were collapsed. Clearing the search
restores the saved expansion state; searching does not modify the scene.

Use the folder button or **Add Group** in the hierarchy background context menu
to create an empty parent. **Add Child Group** creates one inside the selected
entity. Rename groups to describe their purpose and drag related entities onto
them. These are ordinary parent entities with the usual transform inheritance,
save and undo behavior; check inherited transforms when moving existing objects.

Drag the divider between the hierarchy and viewport to change its width. The
width is remembered on this computer and constrained to leave viewport space.
