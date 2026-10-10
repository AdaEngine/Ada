# Community publishing

Open a project in Mobile Studio and tap **Publish** in the project toolbar.
Enter a title and description, choose a cover from Photos, and optionally add up
to five screenshots. The form stores its draft and copies selected images into
the project's `.ada/publication-images` folder. These publishing files are not
included in the playable package.

Sign in to Ada Cloud and activate Cloud Pro. **Submit for review** packages the
saved AdaScript project, uploads the images, creates or updates its Cloud page,
and submits a permanent release for moderation. Successful submission shows the
release number. An error keeps the form available for correction and retry.

New releases use the same page and public app link. The current approved release
remains available while the new one is reviewed; approval replaces the app visible
in Community. The server retains release history. Studio currently has no release
history or rollback UI. Publishing state is scoped by Cloud server, account and
project ID on this device; another device does not automatically inherit that
binding. An uncertain first page-creation response can leave an unused draft page.

Packages use the public player's Sources/Assets layout and limits: 64 MB, 512
files, 16 MB per asset and 512 KB per source. Sources resolved for device preview
are included. External resources, native libraries, custom plugins and script UI
cannot be published. 3D and multiplayer packages declare player API v2. Image
uploads are limited to 5 MB each. Compilation and packaging do not prove that
gameplay, rendering or controls are correct; exercise the app in Play first.

## Agent workflow

The bundled `ada-community-publish` skill is discoverable with
`editor.skills.list/read`. The `editor.community.submit` tool accepts `title`,
`description`, a project-relative `cover` path, and an optional `screenshots`
array. It uses the same packager and publication state as the form. Desktop
submission rejects unsaved open documents. The agent reports the release ID,
number and review status; it cannot approve its own release.

The tool needs an existing Cloud session and Pro. Credentials stay in the host;
the agent does not supply tokens. Captured Play images can be used as screenshots.
Repeated identical submissions reuse the accepted release; changed content or
metadata creates a new release of the same app. The ZIP upload uses the Cloud
operation ID retry mechanism, preserving an uncertain upload across retries.
