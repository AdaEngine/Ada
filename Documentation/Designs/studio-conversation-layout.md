# Desktop Studio conversation layout

Status **Accepted**

Use one conversation layout for the Agent Chat panel and Agent workspace. Draw on the compact header, inline draft and caret-level completion shown in the supplied references. Use Studio's theme, bundled Material Symbols, text roles, and project document controls.

## Header and workspace

Show the current conversation title in a short header with a New Session action. In the editor sidebar, move session selection into a history menu that also provides access to the existing session actions. In Agent, use the existing left project session list for switching and keep the existing workbench available beside the chat with square outer corners. In narrow Agent layouts, expose session selection from the header when the tree cannot fit. Show connection, running, failure and retry status when it affects the current chat. Selection remains visible independently of hover.

## Conversation and draft

Render messages as a flat reading column with compact message spacing. Use the full width of the available conversation pane in both desktop chat surfaces. In a fresh conversation, place the draft at the top of the reading column. An empty prompt shows “Message agent - @ to include context, / to include skills and commands”. Localize the hint and wrap it to the available prompt width. Once the first user message appears in the transcript, display it in a full-width block within the reading column, with a subtly contrasting Studio surface, a thin border and a small corner radius. The agent reply follows below on the transcript surface. Apply the same message treatment to subsequent turns. A new chat opens with the draft and any current connection feedback. After an agent reply, next-message suggestions populate the draft when selected. Keep the file, image, selected code and scene annotation chips beside the draft. Use short labels and explicit remove actions. Keep tool output, permission prompts and interactive A2UI surfaces in the transcript.

When the first user message appears, dock the composer at the bottom, directly above the footer. Keep it docked for any conversation with prior user messages, including restored sessions. Anchor a short footer with Add Context, the existing provider selectors and Send or Stop. A newly created conversation starts with the draft at the top again. At narrow widths, allow selectors to overflow without covering Send or Stop. A footer action that edits the draft makes it visible. Keep the draft and keyboard focus through session switches and streaming updates. Scrolling back into history retains the reader's position.

## Completion

Reuse existing ACP, skill and project context completion results. Anchor slash and mention completion near the editor caret, bounded by the available panel. Open toward available space and scroll long result lists. Use existing keyboard selection, acceptance, Escape dismissal and focus return. Show file or image chips after explicit selection, with the draft still editable before sending.

## Acceptance and documentation

Verify the initial draft, the transition on first send, the separate user message block, the docked draft during streaming and after reopening, long and streamed transcripts, both workspace widths, English and Russian, attachment creation and removal, keyboard and pointer navigation, connection errors, permission and A2UI interactions, and disabled or running states. Confirm session drafts and open documents continue to survive mode switching. Exercise the existing transcript, suggestion and workspace tests with the changed rendering. Update the user guide in Editor/Documentation/AgentInterface.md and the discoverable editor-guide navigation. Use the native desktop Studio on the supported desktop platforms for visual checks.
