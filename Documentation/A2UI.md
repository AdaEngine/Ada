# A2UI for AdaUI

`AdaA2UI` is an optional renderer adapter for **A2UI v0.9.1**. It uses AdaUI's
existing `UISceneInstance`, `UICatalog`, bindings, and native controls. There is
no dependency on Compose, an LLM SDK, an agent framework, or a networking client.

## Run the first experiment

From this worktree on macOS:

```sh
./script/build_and_run.sh
./script/build_and_run.sh --verify
```

The Run action launches **A2UIFormDemo** as an application bundle. The script
uses `/private/tmp/adaengine-a2ui-build` by default; set `ADAENGINE_A2UI_BUILD_PATH` to
choose another task-owned cache. Logs and proof artifacts live in
`Demos/A2UIForm/dist/`. `--debug`, `--logs`, and `--telemetry` are also supported.

The demo streams a local agent fixture in arbitrary byte chunks, progressively
renders an NPC form, and binds its name field and toggle to a surface model.
Typing updates the echo label locally. Submission produces an A2UI `action`
envelope and optional model metadata. **Stream update** changes only the heading;
**Malformed update** demonstrates validation and preservation of the previous UI.

`--verify` operates the actual mounted window through AdaUI's input/inspection
APIs, checks focus and selection after a component update, edits the form, taps
the toggle and submit button, rejects an invalid component, and exports a snapshot.
It writes `ui-tree.json`, `action.json`, and `NPCProfile.ui` under `dist/proof/`.
The standalone demo uses a local fixture. Studio's ACP integration is documented
in `Editor/Documentation/A2UI.md`; launch it with `./script/run_studio_a2ui.sh`.

## The catalog contract

Catalog identifier: `https://adaengine.org/a2ui/catalogs/forms/v1`.
This identifier is a capability key, not a remotely fetched resource.

| Component | Properties | AdaUI implementation |
| --- | --- | --- |
| Text | `text`: string or absolute path | Text |
| Column | `children`: static IDs; optional `spacing` | VStack |
| Row | `children`: static IDs; optional `spacing` | HStack |
| Button | `text`: string or path; `action.event` | Button |
| TextField | `text`: writable path; optional literal `placeholder` | TextField |
| Toggle | `label`: string or path; `value`: writable boolean path | Toggle |
| ChoicePicker | optional `label`; writable string `value`; 1–64 literal `{label,value}` options | ChoicePicker |
| Slider | writable numeric `value`; finite ordered `min`/`max`; optional positive `step` | Slider |

Provide `A2UIClient.catalogSchema()` and `A2UIClient.commonTypesSchema()` to the
agent/schema resolver. Advertise `client.capabilities` in transport metadata.
The JSON schemas are bundled in `Sources/AdaA2UI/Resources`.

This client **does not advertise the Basic Catalog**. Unsupported general functions,
local function actions, collection templates, relative collection paths, arbitrary
modifiers, and nonempty themes are rejected. Styling is owned by the host.
The catalog's inputs require writable paths so edits have an explicit data owner.

## Local form validation

TextField, Toggle, ChoicePicker, Slider, and Button accept at most 32 checks.
Each check has a `condition` and a bounded `message`. The registered validation
subset supports `required` (nonblank text, true, a finite number, or a nonempty
array) and `range` (inclusive finite numeric min/max). No recursive expressions
or general function/property evaluation are supported.

```json
{"condition":{"call":"required","args":{"value":{"path":"/npc/name"}}},"message":"NPC name is required."}
```

Use `{"call":"range","args":{"value":{"path":"/npc/health"},"min":1,"max":100}}`
for a numeric condition. Fields show failures inline. Put the relevant checks on
the submit Button too: invalid buttons are disabled, and dispatch rechecks the
current model so retained callbacks cannot submit invalid data. Validation stays
local and sends no network events. Out-of-range numeric values remain editable;
wrong property types and malformed checks still reject the protocol update.

ChoicePicker uses one **string** selection; it does not claim the Basic Catalog's
array-valued selection contract. Empty selection stays empty until explicitly
chosen. Slider displays bounded values and snaps interaction values from `min`.
Host styling remains responsible for appearance; picker options use ordinary
host-styled buttons. The native Slider currently supports mouse/touch input.

Snapshots preserve these controls and compile checks into the ordinary
`formValidation` native modifier with named UI bindings. Exported `.ui` files keep
inline errors and disabled-submit behavior when their inputs change, without an
A2UI client, network, or model. The UI Designer palette exposes both controls.

## Host integration

Add the `AdaA2UI` library product to the application's SwiftPM dependencies.
Keep one `A2UIClient` per originating agent session on the main actor:

```swift
import AdaA2UI
import AdaUI

@MainActor
struct AgentPanel: View {
    let client: A2UIClient

    var body: some View {
        A2UISurfaceView(client: client, surfaceID: "form")
    }
}
```

Feed complete ordered envelopes to `try client.receive(data)`. For JSONL transports,
maintain an `A2UIJSONLDecoder` per connection and pass each successful frame from
`decoder.append(chunk)` to the client. Handle each result independently: an oversized
line produces a failure while neighboring valid frames remain available. At EOF,
pass `decoder.finish()` to the client if present. Framing failures are returned to
the transport adapter; protocol failures also emit an `error` through `onEvent`.

`client.onEvent` receives `A2UIClientEvent`, containing the wire envelope and
transport metadata. The host sends both to the session's owning agent. Dispatch
is synchronous on the main actor; perform asynchronous I/O through the host's
ordered transport queue. Errors use `VALIDATION_FAILED`, a surface ID when known,
a JSON Pointer to the failure, and a correction message.

The four supported incoming messages are `createSurface`, `updateComponents`,
`updateDataModel`, and `deleteSurface`. Component updates upsert complete definitions
in a surface map. Missing children render empty placeholders; definitions arriving
before `root` are buffered. Data-only updates invalidate bindings without replacing
the scene document. Local input does not send network events. Actions resolve their
context from current data at click time. `sendDataModel: true` adds only the originating
surface's model under `a2uiClientDataModel.surfaces` in transport metadata.

JSON Pointer escapes (`~0`, `~1`), object keys containing dots, and existing arrays
are handled independently of `.ui` dotted paths. Data updates replace/upsert values;
omitting `value` deletes an object key. Array deletions retain a null slot because
JSON has no undefined value. Array appends at the current length are supported;
sparse/out-of-range indices are rejected. Omitting `path` or using `/` replaces the
root model. Missing bound values display empty text or false; present values must
match their property's type.

## Ada Studio authoring

Use **Save .ui…** in the demo, or:

```swift
let document = try surface.snapshot()
let yaml = try document.encodedYAML()
```

Open the resulting `.ui` file in Ada Studio's existing UI designer. The snapshot
uses native catalog components, ordered modifiers, and named inputs with current
model values as defaults. Bindings use deterministic aliases so JSON Pointer keys
cannot collide with the document's dotted path semantics. Buttons export their
server event names as host-owned actions. A game's host can bind these inputs to
its own state and register those actions through `UIBindingContext`.

Snapshots are a one-way authoring handoff: they do not persist the transport,
stream history, or A2UI action-context mappings, and designer edits are not sent
back to an agent. Studio's agent chat renders these surfaces and routes submissions
through the existing ACP session; see `Editor/Documentation/A2UI.md`.

## Bounds and validation

Defaults: 1 MiB per envelope, 1024 component definitions per surface, 16 surfaces,
64 graph levels, and 4096 bytes per data pointer. Component IDs are escaped when mapped into scene identity paths to prevent
slash-containing IDs from colliding with nested nodes. The first three limits are
configurable on `A2UIClient`; pointers also have a depth bound. Duplicate IDs within
an update, cycles, incompatible bindings, unsupported properties, and repeated
mounts of one component ID are rejected before publishing a candidate. Deletion
invalidates retained callbacks and recreation mounts a new surface generation.

The existing view runtime supplies state identity. Focus/selection preservation
is tested for updates that keep the input's type and parent path. Moving an input
to another parent or changing its type can recreate it. Rendering currently uses
the existing shared binding invalidation; this is not a claim of Compose-style
fine-grained performance. Profile larger surfaces before expanding the catalog.

## Validation

```sh
ADAENGINE_DISABLE_SWAN=1 swift test --disable-sandbox \
  --scratch-path /private/tmp/adaengine-a2ui-build --filter 'A2UITests|A2UIProtocolTests|A2UIFormControlsTests'
ADAENGINE_DISABLE_SWAN=1 swift test --disable-sandbox \
  --scratch-path /private/tmp/adaengine-a2ui-build --filter AdaUITests
./script/build_and_run.sh --verify
```

The tests exercise real AdaUI input events, progressive component arrival,
reactive bindings, atomic rejection/recovery, outgoing action/model metadata,
JSONL fragmentation and size recovery, pointer semantics, lifecycle isolation,
and `.ui` snapshot loading through the ordinary scene runtime.

Reference: [A2UI v0.9.1 specification](https://a2ui.org/specification/v0.9.1-a2ui/).
