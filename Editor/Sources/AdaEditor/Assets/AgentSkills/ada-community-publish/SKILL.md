---
name: ada-community-publish
description: Submit an AdaScript app from Mobile Studio to Ada Cloud Community review, including title, description, cover and screenshots. Use when the user requests publication or a new release.
---

# Community publication

Use `editor.community.submit` when the user asks to publish the current app or submit it for review. It packages the saved project, uploads images and submits a permanent release with status `pending`. Review approval updates the same public app; submitting does not make it immediately public.

Prepare a concise title (up to 100 UTF-8 bytes), description (up to 5000 UTF-8 bytes), a required cover, and zero to five screenshots. Use the user's supplied metadata, or draft accurate text from the app. Cover and screenshot arguments are project-relative PNG/JPEG/WebP paths, each at most 5 MB. Use `editor.play.capture` for a real game screenshot and inspect it with `editor.image.read`; a generated cover should not be described as gameplay proof.

Save source and scene changes before submitting. Check AdaScript diagnostics and scene validation; use visible Play to verify controls and presentation when available. Resolve material errors before submission. Public player packages allow Sources/Assets, 64 MB and 512 files; native libraries, external resources, custom plugins and script UI are unavailable.

Cloud sign-in and Cloud Pro are required. If unavailable, report the error and direct the user to Studio Cloud settings. Do not request credentials in chat or bypass moderation with temporary Web publishing. A retry of identical content reuses the submission; changed content creates a release of the same app. If a timeout leaves the result uncertain, retry the same content once and report any remaining error with its release ID when available.

Return the submitted release number, ID and status. Say that approval is pending; do not claim publication or review completion from a successful submission.
