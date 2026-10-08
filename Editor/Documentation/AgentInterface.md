# Agent Interface

Desktop Ada Studio has two presentation modes, selected with **Editor / Agent**
in the top toolbar. Editor is the default. The choice is remembered for each
project on this computer.

Agent Interface follows the session-oriented arrangement of the supplied
JetBrains Air reference: a session tree on the left, conversation tabs and
transcript in the central area, and the composer at the bottom. Messages, context
and composer share a centered column up to 800 points wide; narrower panes use
the available width. Session tabs and their Retry/New Session actions remain on
one full-width toolbar, with the actions anchored on the right. **New Session**
creates a persisted project conversation. **Add Project** uses Studio's existing
project picker and opens the selected project in its own workspace window.
**Agent Settings** opens the existing agent/provider catalog and configuration.
The session tree represents the project belonging to the current window;
this version does not aggregate sessions from multiple projects in one tree.

## Documents and results

Completed tool events containing diff payloads list changed files under the
selected session and above the composer. Reads, failed tools and unfinished edits
do not count as changes. This list describes reported agent changes across the
session; it is not a Git working-tree diff or a rollback snapshot.

Clicking a changed file opens its current project document through the same loader
used by Editor. **Show Workspace** opens the existing document workbench beside
the conversation in wide windows. In smaller windows it occupies the central
area; **Back to Chat** returns to the conversation. The result panel fills its
allocated area directly, with an 8-point divider gap in the side-by-side layout;
closing it restores the conversation to the full available width. Code, scenes, asset previews
and scene Play use their existing implementations. **Editor** restores the full
editor with its Inspector and tool panels. Existing selection-to-chat actions
remain available in the document workspace and return to the conversation with
an unsent selection-backed draft. Project-file search opens its selected result
in the document area while keeping Agent Interface active.

Neither mode switching nor closing the result area closes document models,
saves/discards dirty buffers, or cancels the agent. The editor's panel preferences
are independent of Agent Interface. The document models survive switching;
transient view state such as scroll positions is not guaranteed to be retained.

## Sessions and execution

Both modes use the same project-scoped session store and agent service. Switching
chats keeps each session's unsent text, attachments, selected-code context and
chat mode in memory. Unsent drafts are not persisted across app restarts.
One turn runs at a time in each project window. Switching chats does not cancel
that turn, and later events are saved to its original session. The tree marks the
running session; other chats show that another session is running and cannot send
until it finishes. Stop interrupts the running turn even while viewing another
chat. Provider/model controls still come from the existing agent configuration.

The mode switch is available in the shared desktop workspace. The dedicated
iPhone UI and iOS agent implementation are outside this feature's scope.
