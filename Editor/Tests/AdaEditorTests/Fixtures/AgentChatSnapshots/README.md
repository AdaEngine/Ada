# Agent chat screenshot tests

The `saga-metal/` PNGs are references for the compact desktop transcript at 1× in English. `EditorAgentSnapshotTests` mounts the actual AdaUI transcript, draws it through SAGA Metal, and compares the resulting pixels with the PNGs. The test target also exercises ACP streaming separately with a local fixture.

Run the screenshot suite from the repository root on a Mac with Metal. Use a separate Swift Testing invocation because the other editor suites can initialize the process-wide renderer in headless mode.

```sh
ADAEDITOR_CHAT_SNAPSHOTS=1 swift test --package-path Editor --filter EditorAgentSnapshotTests
```

The test writes `*-actual.png` and `*-difference.png` on a pixel mismatch. Red pixels in the difference image exceed the per-channel tolerance. Set `ADAEDITOR_CHAT_SNAPSHOTS_OUTPUT` to choose the output directory. The default is `AdaEditorChatSnapshots` inside the system temporary directory.

Record references only for intentional visual changes. Review the changed PNGs and rerun the comparison command after recording.

```sh
ADAEDITOR_CHAT_SNAPSHOTS=1 ADAEDITOR_CHAT_SNAPSHOTS_RECORD=1 swift test --package-path Editor --filter EditorAgentSnapshotTests
```
