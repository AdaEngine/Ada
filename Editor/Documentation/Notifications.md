# Notifications and Activity

The bell at the bottom right opens the application-wide notification history and
Activity panel. Closing a toast marks it read and preserves its history entry.
Informational toasts hide after eight visible seconds; warnings, errors, and
requests for attention stay until dismissed or resolved. At most three cards are
shown at once. History retains the latest 500 records in Application Support.

Notification Settings controls system delivery, sound, and source categories.
System permission is requested only when the user enables delivery. Agent/build/
test results and requests for attention are delivered while the packaged app is
inactive. Foreground delivery uses the editor cards. No APNs registration or
remote push service is included.

## Producing events

`EditorNotificationCenter.post` accepts a stable event ID, source, importance,
project label, operation ID, and serializable `EditorNotificationAction` values.
Reposting an ID updates its history entry without sending another system alert.
Actions route to the original project and session; never store a closure or an
unvalidated command in a notification payload. Streamed text and logs are not
notification events.

`EditorActivityCoordinator.begin/update/needsAttention/resume/finish` owns run
state independently of the selected chat. Supply a cancellation closure only
when the executor can stop the actual work. Late completion after cancellation
cannot change its terminal state or deliver a second result. On relaunch, saved
unfinished local operations become interrupted rather than appearing to run.

## iPad background execution

On iPadOS 26+, an executor may call
`EditorContinuedProcessing.shared.request(for:coordinator:)` immediately after a
user-started activity is registered. The activity must have a positive total work
count and a real cancellation handler. The executor must continue reporting
completed units; do not invent percentages for open-ended agent work.

The adapter registers before submitting, uses `.fail`, and reports foreground-only
fallback in Activity if registration or submission fails. The system owns the
Live Activity UI. Cancellation/expiration stops the executor. Waiting for user
input releases background execution; resuming the in-app operation does not
silently obtain another background grant. Finish is sent exactly once.

The existing ACP subprocess service is macOS-only and does not opt in. This
infrastructure does not add an iPad agent backend. iPadOS 18 remains supported
without continued processing. There is no WidgetKit extension or custom ActivityKit
presentation.

## Validation

Run from `Editor/`, using an isolated scratch directory:

```sh
swift test --scratch-path /tmp/adaeditor-notifications-build --filter 'EditorNotification|EditorAgentStreamingTests|EditorAgentTests|EditorAgentChatUITests'
```

For a controlled on-device check, build Debug with XcodeGen and launch with
`ADA_EDITOR_BACKGROUND_TEST=1`. Notifications settings then exposes **Run background
diagnostic**. Tap it, leave the app, observe the system Activity, and test both
completion and cancellation. It verifies 120 temporary file records over about
two minutes, reports real completed units, and removes its own temporary file.
The check runs only after the button tap. Scheduler acceptance and system UI must
be checked on the device; a simulator or successful build alone does not prove
background execution.

For local alerts, enable notifications in the packaged application, start a build
or agent run, deactivate the app, and inspect the result and Open action. Repeat
with notification permission denied and with the app relaunched from a delivered
notification. Verify that the original project/chat opens without duplicating the
event.
