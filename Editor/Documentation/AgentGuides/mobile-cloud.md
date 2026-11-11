# Mobile, Community and Cloud

Read this reference only when the task touches this area. Return to [the editor guide](../../AGENTS.md) for routing and shared rules.

Paths in code spans and commands retain their original `Editor/` working-directory context unless explicitly repository-relative; Markdown links resolve from this file.

This inventory was originally recorded on **2026-10-04** and subsequently maintained. Implementation and test links identify existing coverage, not a validation run or platform acceptance.

### Mobile and supporting features

Mobile Studio's project settings include Publish, opening title/description, cover and
up to five screenshot fields. Cloud sign-in and Pro are required. Saved AdaScript
projects are packaged on-device and submitted as permanent Community releases in
`pending` review; approval updates the same app card. Identical retries reuse the
submission and uploaded media. Native libraries, external/custom resource roots,
custom plugins and script UI are unavailable in the public player.
The bundled `ada-community-publish` skill and `editor.community.submit` tool share
this path on mobile and desktop; desktop requires saving dirty documents first.
Coverage: [EditorPublicationTests.swift](../../Tests/AdaEditorTests/EditorPublicationTests.swift).
Guide: [CommunityPublishing.md](../../Documentation/CommunityPublishing.md).

iPhone has dedicated project/files/code/scene/Play/chat/activity/settings screens,
image attachments, screenshot markup and voice input. Dictation uses on-device
`SpeechAnalyzer`/`SpeechTranscriber` on iOS/visionOS 26+ (language model downloads on
first use) and falls back to `SFSpeechRecognizer` on older systems or unsupported locales. The shared workspace and
mobile flow have separate implementations and tests.
The iPhone project home and iPad launcher use Studio/Community tabs. Catalog,
search, sorting, details, screenshots and navigation are shared AdaUI views under
`UI/Community`, with no SwiftUI/UIKit dependency. The public client requests PNG
media for the engine's portable decoder. Play rechecks the selected publication. AdaScript API-v1/v2 packages download with
release pinning and SHA-256 verification and run in a separate embedded world/VM;
web builds delegate opening to `Application.openURL` (Android ACTION_VIEW).
The 3D player uses `SceneView(useSceneCameras: true)` to route active authored
cameras into the offscreen viewport while preserving projection and transforms.
API v2 adds 3D rendering/models/physics, scoped `@scriptable` objects and native
Cloud multiplayer. Players choose Solo, Host or Join by code; hosting requires
Cloud sign-in. Room compatibility is bound to the immutable published release,
not authored network settings. The community player rejects native libraries,
external projects/plugins and script UI. It restricts
virtual asset roots from preparation through world teardown, keeps scriptable
registrations local to the game world, and instruments loops/functions with limits;
this is not a separate process or a total native/GPU memory sandbox.
Browsing needs no Cloud sign-in. Studio and Community retain separate navigation;
the last tab restores on launch, and workspace navigation focuses Studio while
preserving its Build/Files/Play tabs.
The home tab bar hides during Studio navigation so it does not overlap workspace controls;
Both mobile tab bars use automatic placement: a vertical glass strip on phone
displays with a side safe area, or bottom controls with 6-point padding on ordinary
displays. Native hinge updates expose angle, posture and opening percentage through
the AdaUI environment and `WindowHingeChanged`. The old simulated Foldable Preview
selector and saved preview setting have been removed; legacy projects still decode.
The public catalog currently returns up to 100 entries. The Android mobile host
reuses the mobile screens and adds NativeActivity services for keyboard input,
Back, document selection, dictation, speech output and encrypted credentials.
Build it with `Platforms/Android/studio.py`; see [AndroidMobile.md](../../Documentation/AndroidMobile.md).
Android background agent execution, clipboard image paste and Google Play Billing
remain unavailable. Compilation and packaging checks do not establish interaction parity.
Entry points: [EditorCommunityView.swift](../../Sources/AdaEditor/UI/Community/EditorCommunityView.swift),
[MobileEditorHomeTabs.swift](../../Sources/AdaEditor/UI/Community/MobileEditorHomeTabs.swift),
[EditorCommunityClient.swift](../../Sources/AdaEditor/Cloud/EditorCommunityClient.swift).
Coverage: [EditorCommunityTests.swift](../../Tests/AdaEditorTests/EditorCommunityTests.swift).
Bundled offline documentation provides search, sections, history and copyable
examples. Appearance/input settings, notifications/background activities,
achievements/Game Center, cloud account/settings and standalone update UI exist.
Shared AdaUI settings switches place labels and controls at opposite row edges,
with animated thumb movement and track tint; settings rows omit On/Off text.

Cloud Pro includes 500 shared monthly AI credits. Browser Studio selects hosted Coder Next from the server registry and shows remaining/used/reserved credits and renewal; missing service is distinct from an empty balance. BYOK/local connections remain independent.

Ada Cloud AI wallet integration uses the existing account session for catalog,
balance, cursor-paginated usage, quotes, reservations, lookup and cancellation.
Credit counters appear on the start screen, shared workspace toolbar and iPhone navigation;
Cloud settings show available/used/reserved credits and cycle activity. AI credits
are separate from Cloud publishing Pro. Missing/disabled service and signed-out
states do not imply a zero balance. Hosted Ada AI uses the shared Cloud account transport, Coder Next tool loop and server wallet. Desktop selects the built-in Ada AI entry; mobile selects Ada AI in Providers. Tool mutations require approval; Cloud conversations persist separately from external runtime sessions. Provider keys and settlement stay server-side, and external/BYOK agents remain independent.

Native Ada AI exposes `editor_web` with `search`, `fetch` and `download` through its project-scoped
tool host. Ask/Plan allow search and page reading; Build also permits downloads
through the existing write approval flow. External desktop agents retain the
same tools through AdaMCP, and mobile agents through their host bridge. Browser
Studio's hosted catalog omits these actions. Coverage:
`EditorCloudWebToolTests`, `EditorCloudAgentTests`, `EditorWebToolTests`.

Entry points: [EditorCloudAIClient.swift](../../Sources/AdaEditor/Cloud/EditorCloudAIClient.swift),
[EditorAICreditsModel.swift](../../Sources/AdaEditor/Cloud/EditorAICreditsModel.swift).
Coverage: [EditorAICreditsTests.swift](../../Tests/AdaEditorTests/EditorAICreditsTests.swift),
[EditorCloudAILiveTests.swift](../../Tests/AdaEditorTests/EditorCloudAILiveTests.swift).

Entry points: [MobileEditorRootView.swift](../../Sources/AdaEditor/UI/Mobile/MobileEditorRootView.swift),
[EditorDocumentation.swift](../../Sources/AdaEditor/Documentation/EditorDocumentation.swift),
[EditorCloudAccount.swift](../../Sources/AdaEditor/Cloud/EditorCloudAccount.swift).
Guides: [Notifications.md](../../Documentation/Notifications.md),
[Achievements.md](../../Documentation/Achievements.md), [README.md](../../README.md).
