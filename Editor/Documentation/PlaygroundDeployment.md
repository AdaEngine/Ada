# Playground deployment — 30 October 2026

Production: [Ada Playground](https://playground.adaengine.org/games).
Snapshot recorded in Europe/Moscow; release identifiers use 29 October UTC.

## Delivered behavior

Games, Create, My projects, Account and the browser editor use the WebUI shell
and the shared Cloud panels. The fixed Player runs on a separate HTTPS origin.
Private project creation and saving are available worldwide: only AIService and
Workspace receive the Studio-specific worldwide override. Other production
Cloud services retain their regional configuration.

Hosted Ada AI remains disabled and no provider key is configured on either
server stage. The BYOK provider registry is available; this rollout did not
perform a funded OpenRouter generation or settle AI credits.

## Immutable artifacts

- Backend image: adaengine-cloud:20261029-playground-v3.
- Image ID: sha256:57ebc1eee182d14654ebf82a55505f293b8df46d3542084feea5bfc77bbd3412.
- Backend release: /opt/adaengine-cloud/releases/20261029-playground-v3.
- Edge release: /opt/adaengine-cloud/releases/20261029-playground-edge-v4.
- Static assets: /opt/adaengine-cloud/releases/20261029-playground-assets-v4.
- Preview hosts: studio-preview.play.adaengine.org and
  studio-preview.play-test.adaengine.org.
- Runtime API: 4, universal profile; WASM 78.7 MiB, gzip 26.6 MiB.

The backend was assembled from the exact previously deployed source archive,
with an additional Playground origin and the three browser tool names missing
from that deployed baseline. The final AIService-only layer preserves the other
nine verified service binaries. Source allowlists, checksums, build logs and the
deployment manifest are retained on the host under
/opt/adaengine-cloud/build/20261029-playground-v3 and
/opt/adaengine-cloud/build/20261029-playground-origin-v1.

## Changes required for this release

- Restricted direct CoreFoundation use in StudioValue to supported native
  platforms; the existing portable path builds on WASI.
- Preserved native atomic Movie Maker writes and used the supported regular
  write on WASI.
- Regenerated the native browser contract from the successfully built Studio:
  12 components, 146 input bindings and 31 API types.
- Added nine missing activity messages to both localization catalogs.
- Started the completed-frame watchdog after engine startup. A first load still
  requires an actual rendered frame; the parent's total load deadline remains.
- Preserved the Playground origin, named HTTPS routes, isolated static mounts
  and Studio-only regional override in the Cloud deployment source.

## Verification performed

- macOS Release build and Swift 6.3.2 release WASM export passed.
- Pinned Tint hash/conversion smoke, reactor ABI and exact origin allowlist passed.
- WebUI: 168 Node tests passed, including slow startup and stalled-frame tests.
- Website routing/auth/panel tests: 54 passed.
- Studio portable core: 9 Swift Testing tests passed.
- EditorLocalizationTests: 8 passed, including mounted language changes and
  Russian layout checks. Both catalogs contain 2614 matching messages.
- Cloud release tests: 90 passed. These tests do not replace the live checks below.
- Real email/PKCE sign-in in test, original-host binding, host-only cookies and
  foreign-origin rejection passed.
- All 38 actual browser tool schemas reached API-key validation; a forbidden host
  tool was rejected. The probe stopped before a provider request.
- Browser checks covered mounted English/Russian switching, creation of 2D/3D
  workspaces, actual engine pixels, transform editing, Undo/Redo, save/reload
  persistence and Play/Stop. Keyboard focus was refreshed after tab reload.
- The separately approved publication test used the public built-in 3D template,
  a zero-value sandbox entitlement and a temporary Publishing moderator.
  Public TLS upload, trusted Player assembly, pending/approved moderation,
  public game HTTPS, WASM range delivery and revocation to HTTP 410 passed.
- The synthetic negative upload was rejected by the real archive validator.

The publication client identifies itself as AdaPlaygroundDeploymentSmoke/1.0.
Cloudflare rejected Python urllib's library-default identity with error 1010;
the descriptive application identity follows its
[documented guidance](https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-1xxx-errors/error-1010/).
No Cloudflare protection or TLS verification was disabled.

## Backups, isolation and cleanup

- Fresh test backup: /opt/adaengine-cloud/backups/test/20261029T184745Z.
- Fresh production backup: /opt/adaengine-cloud/backups/prod/20261029T202831Z.
- SHA256SUMS and isolated restore of all ten databases and stored objects passed.
- Twenty Cloud service containers are healthy; 58 containers are running.
- Unrelated container IDs and the HTML bytes of seven Cloud/Store/Console sites
  were preserved. Sloppy containers and routes were retained.
- Sandbox Pro, the temporary moderator and the QA publication were revoked.
  The disposable QA account and its sessions were removed, and stored QA cookies
  were deleted.
- Only identified cache records belonging to this task were pruned. Live,
  previous release and builder images were retained.

## Recovery

The previous backend is
/opt/adaengine-cloud/releases/20261023T233838Z-4b71811-pro-grants,
image sha256:c389cddea0933665c17ca9e2d9c1b0f54f1df7a27c0ba06e9f1044ce1b8b0eba.
The release's private rollback directory contains the pre-activation environment
and edge metadata. The last verified edge before production was
/opt/adaengine-cloud/releases/20261029-playground-testedge-v4.
The original shared edge remains at
/opt/adaengine-cloud/releases/legal-20261023T221514Z.

Rollback must select the recorded configuration and image together and preserve
the existing Caddy volumes. This release adds no database schema migration;
database restoration is a separate recovery operation.

Local evidence and build logs are under /tmp/ada-playground-20261029.
Source fixes remain uncommitted in the owning repositories; unrelated concurrent
workspace changes were preserved.

## Provider update — 30 October 2026

The assistant now offers OpenAI, Codex (OpenAI API), and OpenAI-compatible in
BYOK mode. The existing reserved provider is presented as OpenRouter in BYOK and
Ada AI in hosted mode. Custom connections accept an HTTPS Base URL, Model ID,
Chat Completions or Responses, and optional image capability. API keys remain
required and are isolated by provider/address in tab memory.

The new providers connect directly from the browser with cookies/referrer
omitted and redirects rejected. Compatible endpoints must allow CORS from the
current Playground origin, SSE and function tools. No user endpoint is accepted
by the Cloud server proxy. Codex uses OpenAI API billing and Studio's browser
tool loop; no Codex CLI harness or ChatGPT subscription sign-in was deployed.
Available model presets follow the official API catalog; individual API project
access is established only by a successful request.

Static assets: /opt/adaengine-cloud/releases/20261029-playground-providers-assets-v2.
Test edge: /opt/adaengine-cloud/releases/20261029-playground-providers-testedge-v2.
Production edge: /opt/adaengine-cloud/releases/20261029-playground-providers-prodedge-v2.
Source/asset manifest, validation logs and per-stage activation results are in
/opt/adaengine-cloud/build/20261029-playground-providers-v2.
The backend image and isolated Player are unchanged from the release above.

Validation: all 176 WebUI tests, the production web build, catalog checker
(2630 messages per language), and all 8 EditorLocalizationTests passed. Tests
exercise both streaming protocols, images, function calls/results, encrypted
reasoning and message-phase continuity, saved assistant input replay, truncation/failure rejection, key isolation, and a complete
agent file-write/tool-result cycle with Undo. Actual test-browser checks covered
English/Russian switching, custom connection fields, model choices and key
isolation. OpenAI's CORS preflight returned HTTP 200. No funded provider generation
was performed; these checks do not establish a real account's model access.

Fresh backups: test 20261029T224918Z and production 20261029T225047Z. Checksums
and isolated restoration of ten databases plus stored objects passed. Activation
checks require exact public static hashes, strict HTTPS, routing, stable bytes for
seven unrelated sites, and unchanged IDs for every container except the edge
proxy. Application/Sloppy containers, server secrets, payments and databases are
preserved. Production rollback selects the test edge above (old production
assets, new test assets); the complete prior edge for the final v2 update is
/opt/adaengine-cloud/releases/20261029-playground-providers-prodedge-v1.
The pre-provider edge remains at /opt/adaengine-cloud/releases/20261029-playground-edge-v4.

Local logs and artifact manifests: /tmp/ada-playground-providers-20261029 and
/tmp/ada-playground-providers-*.log.
