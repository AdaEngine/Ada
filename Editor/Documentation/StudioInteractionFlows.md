# Studio interaction flows

Run repeatable workbench gestures from YAML on macOS with a graphical session and a supported GPU. The separate interaction host opens Studio's workbench on a disposable scene project. It uses the window input queue, including the same hit testing and pointer capture as a desktop gesture.

## Run the example

From the repository's `Editor` directory, build and run the interaction host:

```sh
ADAEDITOR_INTERACTION_HOST=1 swift build --product adastudio-flow
ADAEDITOR_INTERACTION_HOST=1 swift run adastudio-flow Tests/StudioInteractionHost/Fixtures/workbench.yaml
```

The example selects a cube, moves it along the X gizmo, checks the committed position and undo depth, then undoes it. It cancels another move after sending intermediate motion and verifies that the preview and document are restored. It then drags the cube onto a group in Hierarchy and verifies reparenting, rejects a cycle and undoes the valid drop.

## Run through AdaMCP

Start a fresh `adastudio-flow --stdio` process with an AdaMCP-compatible Content-Length framed client. For example, configure the AdaMCP router with `--stdio-command "/absolute/path/to/adastudio-flow --stdio"`. Call `editor.ui.run_flow` with `source` set to the contents of the same YAML file. Use `ui.find_nodes` to look up identifiers or `ui.get_tree` to inspect the full AdaUI hierarchy. The tool and CLI execute the same runner. Use a fresh host for a repeatable initial scene.

The repository contains a check that runs the example through both interfaces:

```sh
python3 Tests/StudioInteractionHost/check_flow.py .build/debug/adastudio-flow
```

## Flow format

Set `version: 1` and `profile: studio-ui`. A flow contains up to 64 steps and 64 KiB of YAML. Each step has one command.

- `tapOn` takes an accessibility `id` in the workbench window.
- `drag` takes `from`, either `to` or `by`, and `durationMs`. Targets use an `id`. For the X gizmo use the viewport surface ID with `anchor: translate.x` on `from`. Offsets use logical points. Add `end: cancel` to cancel after intermediate motion.
- `pressKey` supports `key: z` with `modifiers: [main]` for undo or `[main, shift]` for redo.
- `assertScene` takes an entity ID and checks its local `position`, `parent` or `undoCount`. Position uses an optional absolute `tolerance`.

A flow returns a JSON report. A failure includes the step number, command, diagnostic, recent input trace and, when available, the workbench screenshot path. The CLI returns a failing exit status. For an unavailable gizmo, check that the fixture scene is active, the cube is selected and the Move tool has drawn its handles.

The initial profile covers the macOS workbench, one fixture project and the X translation handle. Play game scenarios, OS dialogs, and file drags use separate verification paths.
