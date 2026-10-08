# AdaEditor achievements

The editor awards 26 permanent achievements: 20 regular and 6 secret, worth 490 points in total. Settings → Achievements works without a project and without Game Center. Secret names, conditions, and progress remain hidden until earned. Existing projects aren't scanned on opening; a successful edit/save or runtime action is required. Autosave counts as a save. Standard transform/visibility/bounds/editor-gizmo components and the scene root aren't counted toward composition/population goals.

## Storage and account behavior

`Application Support/AdaEditor/achievements.json` contains versioned local profiles. Progress is monotonic; notifications occur once, after persistence succeeds. A corrupt or newer-version file is preserved, and Settings displays the storage error. Notification preference is independent of system notification permission.

Connect Game Center explicitly in Settings. On subsequent app starts, an opted-in connection authenticates again. The first connected player claims guest progress once. Each Game Center player has a separate local profile. Signed-out work uses the local profile and isn't copied into another player's account. Changing accounts while a synchronization request is pending discards the old response. Steam integration is not implemented; `EditorAchievementProvider` is the adapter boundary, and stable editor IDs don't depend on GameKit IDs. No cross-service account linking is implied.

Synchronization loads server progress, merges by maximum, and reports only missing progress. Secret achievements report only 100%. Sync errors retain local progress; retry on the next progress event, authentication, or the Sync button. Imported completion doesn't replay notifications. When restoring completion from Game Center, the displayed date is the local restoration date (GameKit doesn't supply the original unlock date). Seven active days need not be consecutive; only days observed locally are counted, while server progress provides a monotonic lower bound.

## Apple configuration

`project.yml` enables Game Center for macOS and iPadOS and generates `Platforms/AdaEditor.entitlements`. Both wrappers use `org.adaengine.editor`. Local ad-hoc or unsigned builds can validate editor behavior but aren't evidence of a working production Game Center connection. Use the developer team's Game Center-enabled App ID and a matching signed provisioning profile for device/server validation.

All 26 achievements were created and verified in [App Store Connect](https://appstoreconnect.apple.com/apps/6809145006/distribution/gamecenter) on 2026-09-09 for app `6809145006`. Each saved detail page was reopened to check its points, visibility, disabled repeatability, English/Russian titles, and processed images. The total is 490 points with six hidden achievements. `Documentation/GameCenter/app-store-connect.json` records the remote IDs and verification time; `catalog.json` remains the source for localized text and artwork. All cards are currently **Prepare for Submission**. They have not been submitted for review or released, and signed live GameKit synchronization remains unverified. Release the Game Center components with the app after review.

Regenerate the export from the Swift catalog on macOS:

```sh
swiftc Sources/AdaEditor/Achievements/EditorAchievement.swift scripts/export-achievements.swift -o /tmp/export-adaeditor-achievements
/tmp/export-adaeditor-achievements Documentation/GameCenter
```

Apple references: [achievement metadata and artwork](https://developer.apple.com/help/app-store-connect/reference/game-center/achievements), [configuration and review](https://developer.apple.com/help/app-store-connect/configure-game-center/manage-achievements/).

## Verification

Run `swift test --scratch-path /tmp/adaeditor-achievements-build --filter EditorAchievementTests`. The suite uses temporary real files for save conflicts, persistence, history and nested scenes, an injectable provider for account/sync failures, and a headless AdaUI container for Settings interaction. Test builds don't install the application achievement bootstrap and therefore don't award achievements to the developer's profile.

For signed runtime acceptance on macOS and iPadOS: connect a sandbox player; earn a regular and secret achievement; open the Game Center dashboard and verify both; disconnect networking, earn another, restart, reconnect and sync; change player and check profile isolation; disable reward notifications and earn a new achievement. A successful compiler run alone doesn't complete these server checks.
