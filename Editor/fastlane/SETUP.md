# App Store Connect builds

Run commands from `Editor/`. Fastlane generates `AdaEditor.xcodeproj` from
`project.yml`, archives the `AdaEditor-iPadOS` scheme in Release, and exports an
App Store IPA. The public configuration contains only the bundle ID
`org.adaengine.editor` and development team `8PYCRS3EA3`.

## Upload either platform with the Xcode account

For a Mac already signed into the developer account in Xcode, use automatic
signing and Xcode's App Store Connect upload. This route does not require the
Fastlane API key or a manually selected distribution profile:

```bash
BUILD_NUMBER=2 MARKETING_VERSION=1.0 bundle exec fastlane upload_xcode target:ios
BUILD_NUMBER=2 MARKETING_VERSION=1.0 bundle exec fastlane upload_xcode target:macos
```

Choose the version and build number before running. Archives and logs are saved
under `build/appstore/ios` and `build/appstore/macos`. The lane verifies the
archive's signature, bundle ID, version, and build number before uploading.
Xcode may raise the uploaded build number if needed to avoid a collision.
`ADAEDITOR_DERIVED_DATA` can point to an existing task-owned build cache.

To retry an upload from the same archive, pass `skip_archive:true` with the same
target, `BUILD_NUMBER`, and `MARKETING_VERSION`. The account must be authorized
to use automatic distribution signing. Upload completion does not establish
Apple's processing result; check the build in App Store Connect afterward.

## Prerequisites

- macOS with Xcode 26.2 or newer, its iOS SDK, and command-line tools selected.
- Ruby 3.3, Bundler 2.6.0, and XcodeGen (`brew install xcodegen`).
- The complete AdaEngine checkout, including Git submodules
  (`git submodule update --init --recursive` from the repository root).
- An Apple Distribution certificate **with its private key** already installed
  in an unlocked keychain, plus an installed App Store provisioning profile for
  this bundle ID and team. The profile must support the app's Game Center entitlement.
- For uploads: an existing iOS app record in App Store Connect and a team API key
  with permission to upload builds (Developer or higher).

```bash
gem install bundler -v 2.6.0
bundle _2.6.0_ install
cp fastlane/.env.example fastlane/.env
```

Edit the ignored `fastlane/.env`: set `IOS_PROVISIONING_PROFILE` to the exact
installed profile name, `BUILD_NUMBER` to a positive integer higher than the last
uploaded build for this version, and optionally `MARKETING_VERSION` (default `0.1.0`).
Build numbers are explicit: no Apple credentials or network query are needed to
choose one. Coordinate numbers between local and CI uploads.

## Build only

```bash
bundle exec fastlane ios build
```

No App Store Connect credentials are needed for this lane. It uses local signing
assets and does not log in to Apple or download/create certificates or profiles.
Package resolution may still require network access. Manual signing is applied
only to the generated iPadOS Release target and restored after the build.

Outputs are under the ignored `Editor/build/testflight/` directory:
`AdaEditor.ipa`, `AdaEditor.xcarchive`, dSYMs, build logs, and isolated DerivedData.
Each run reuses these output paths; copy artifacts elsewhere if retaining builds.

## Build and upload

Supply `ASC_KEY_ID` and `ASC_ISSUER_ID` privately, and exactly one of:

- `ASC_KEY_FILEPATH`: path to a private `.p8` file outside the checkout. Relative
  paths resolve from `Editor/`.
- `ASC_KEY_BASE64`: Base64-encoded `.p8` contents, suitable for a CI secret.
  Base64 is an encoding, not encryption; this value is a secret too.

```bash
bundle exec fastlane ios beta
```

The lane uploads the newly built IPA and returns without waiting for Apple's
processing. It does not submit for external beta review or configure tester groups.
Check processing, export compliance, and tester availability in App Store Connect.

## Public repository and CI

Commit the Gemfile, lockfile, Fastfile, and empty `.env.example`. Keep Apple account
credentials, API key IDs/issuer IDs and private keys in an ignored local `.env` or
your CI secret store. Do not pass secrets as command-line lane options or print
the environment. Team ID and provisioning profile names may be public.

For CI, install the certificate/private key into a temporary unlocked keychain
and install the profile before running the lane. Inject API variables from the
secret store, use a unique `BUILD_NUMBER`, then remove signing material and the
temporary keychain in an unconditional cleanup step. This configuration deliberately
does not contain signing assets, a credentials repository, or Apple login details.

The editor's `.gitignore` excludes local env files, common signing file formats,
Fastlane API-key JSON files, and build artifacts. Ignore rules are a guardrail;
review staged files before publishing, and never force-add signing material.

References: [Fastlane build_app](https://docs.fastlane.tools/actions/build_app/),
[API key authentication](https://docs.fastlane.tools/actions/app_store_connect_api_key/),
[TestFlight uploads](https://docs.fastlane.tools/actions/testflight/).

## macOS channels

`AdaEditor-Distribution` / `AdaEditor-macOS` and iPadOS are the App Store / TestFlight
channel. They expose only AdaScript templates and reject SwiftPM/hybrid projects
before changing manifests or starting tools. AdaScript compilation and playback
use the embedded runtime. Existing Swift projects are not converted automatically.

`AdaEditor-Standalone` is the website channel: AdaScript and SwiftPM, App Sandbox
disabled, Hardened Runtime enabled. Both Mac channels use the same bundle ID and
app name; install one at a time. The channel is embedded in the host Info.plist
(`AdaEditorDistribution`), because Xcode target compilation flags do not propagate
to the SwiftPM executable. Unlabelled app bundles default to AdaScript only.

Run from `Editor/` with an installed **Developer ID Application** certificate and
its private key. This is a different identity from Apple Distribution. Prepare a
notarytool Keychain profile locally, then run:

```bash
BUILD_NUMBER=3 MARKETING_VERSION=1.0 NOTARYTOOL_PROFILE=AdaEngine \
  bundle exec fastlane mac website
```

This generates the project, archives and exports the standalone app, checks its
signature/channel/entitlements, submits it for notarization, staples and validates
the ticket, assesses it with Gatekeeper, and creates a versioned ZIP plus SHA-256
under `build/standalone/`. Publish that ZIP on the website only after this lane
succeeds. The lane does not upload to the website or to TestFlight.

`bundle exec fastlane mac standalone` with the same version/build variables exports
a signed app without notarization; it is an intermediate artifact, not a completed
website release. `ADAEDITOR_DERIVED_DATA` selects the build cache. No certificate,
private key, or notarization credential belongs in the repository.

## Sparkle updates (standalone macOS only)

The standalone target embeds `AdaEditorUpdater.framework` and Sparkle 2.9.6.
The SwiftPM executable loads this optional framework after launch. Store targets
neither link nor embed it, and the App Store archive check rejects updater
frameworks. Use separate DerivedData directories for Store and standalone release
jobs to avoid stale products with the same app name.

Sparkle checks the HTTPS appcast automatically. Scheduled checks show an **Update**
button in the editor and project launcher; clicking it opens Sparkle's release
notes and installation UI. **Check for Updates…** is always available in the
standalone application menu. Automatic installation is disabled. All open
workspaces save before the updater starts and again immediately before restart;
a failed save postpones installation until the user saves and retries Update.

Download the official [Sparkle 2.9.6 tools](https://github.com/sparkle-project/Sparkle/releases/tag/2.9.6).
Create the signing key once, keep it across all releases, and back it up securely:

```bash
/path/to/Sparkle/bin/generate_keys --account AdaEngineEditor
```

Only the public key belongs in build configuration. The private key stays in
Keychain, or in a CI secret file referenced by `SPARKLE_PRIVATE_KEY_FILE`; its
contents are never passed on the command line. Do not generate a new production
key for every release.

The website lane now additionally requires these settings:

```bash
export SPARKLE_TOOLS_DIR=/path/to/Sparkle/bin
export SPARKLE_PUBLIC_ED_KEY='<public key from generate_keys>'
export SPARKLE_FEED_URL=https://adaengine.org/updates/appcast.xml
export SPARKLE_DOWNLOAD_URL_PREFIX=https://github.com/AdaEngine/AdaEngine/releases/download/editor-v1.0-3/
BUILD_NUMBER=3 MARKETING_VERSION=1.0 NOTARYTOOL_PROFILE=AdaEngine \
  bundle exec fastlane mac website
```

The URLs above describe the proposed hosting layout; this change does not deploy
that endpoint or create a GitHub release. Any HTTPS archive host is supported.
`SPARKLE_KEY_ACCOUNT` defaults to `AdaEngineEditor`. Optional
`SPARKLE_RELEASE_NOTES` points to an HTML fragment, embedded in the appcast.
`SPARKLE_PREVIOUS_APPCAST` points to the existing feed: provide it on fresh CI
workers to preserve entries for older supported macOS versions. Local runs reuse
`build/standalone/updates/appcast.xml`. Delta generation is disabled so each new
GitHub release only needs its own ZIP.

After notarization and stapling, the lane signs the final ZIP with EdDSA, generates
and validates `build/standalone/updates/appcast.xml`. Upload the versioned ZIP and
checksum to the release named by the download prefix **first**, verify the download,
then atomically publish appcast.xml at `SPARKLE_FEED_URL`. Keep existing release
assets immutable. Publishing the feed before the archive creates broken updates.

Both `mac standalone` and `mac website` reject missing/invalid feed URLs or public
keys before building. Local Xcode builds with empty update settings remain usable;
manual update checks explain that the channel is not configured.

Validation:

```bash
SPARKLE_TOOLS_DIR=/path/to/Sparkle/bin ruby fastlane/tests/update_feed_test.rb
```

This creates a disposable app archive and Ed25519 key outside the repository,
runs the actual Sparkle generator, and independently verifies the resulting ZIP
signature. It does not sign or publish a production release.

The standalone lane explicitly signs Sparkle's nested Updater, Autoupdate and XPC
helpers with Developer ID and secure timestamps before signing the enclosing
framework and application. An outer framework signature alone can pass local
verification while failing Apple's notarization checks.
