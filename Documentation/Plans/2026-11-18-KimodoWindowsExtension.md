# Kimodo Windows extension implementation

The approved [design](../Designs/kimodo-windows-extension.md) defines the
Windows release, first-party package, and Animator workflow.

## Implementation sequence

1. Establish the package and process contracts. Pin the upstream Kimodo revision,
   runtime and model revision. Exercise packaging against tampered archives and
   run the protocol against a local test process. Stage a published-form package
   using an isolated development signing key. Keep release signing in CI.
2. Add a deterministic SOMA-to-humanoid transfer in `AdaAnimation`. Verify rest
   pose, asymmetric arm movement, parent-space rotations, and forward root
   translation on a real skeletal hierarchy. Exercise normal `AnimationLibrary`
   compilation and playback with the generated tracks.
3. Add the Windows Studio package installer and process host. Reuse Studio's
   archive and process infrastructure where it supports the required behavior.
   Verify signature before activation, retain an active version on failed
   installation, and reject mismatched jobs and incompatible rig revisions.
4. Add the File menu action and Animator workflow. Use the approved mockup and
   existing preview and save paths. Add English and Russian strings. Verify the
   installed editor with a real project, including cancellation and save/reopen.
5. Publish the signed ZIP from the separate
   [Kimodo Motion Plugin repository](https://github.com/AdaEngine/Kimodo-Motion-Plugin).
   Point the Ada Store listing at the public release when available. Test the
   release archive on a clean Windows installation with WSL 2 and CUDA, including an upgrade.

## Release configuration

Set `KIMODO_RELEASE_PRIVATE_KEY` as a GitHub Actions secret in the plugin repository.
Set the corresponding base64 Ed25519 public key as `KIMODO_RELEASE_PUBLIC_KEY` in
both repositories. Set `KIMODO_MINIMUM_STUDIO_VERSION` in the plugin repository to
the Studio version that includes the installer. A `kimodo-v` tag in the plugin
repository builds the extension and creates a draft release with the ZIP attached.
The private preview ZIP uses a development key that must match the preview Studio build.

In the Store frontend build, set `VITE_KIMODO_EXTENSION_VERSION` and
`VITE_KIMODO_STUDIO_RELEASE` to the verified public releases. Set
`VITE_KIMODO_DEMO_URL` to the hosted preview clip under `/showcases/`. The Store
displays its card when the extension and Studio release versions are configured.

## Evidence and delivery

- Record focused Red, Green and Refactor tests for archive activation, the
  process protocol, and animation conversion. Run editor and animation suites.
- Record successful cold and warm Kimodo jobs on the RTX 4070, including peak
  memory, setup size and generated clip behavior. Model access is a prerequisite
  for this evidence. Exercise the default, busy, error, ready and narrow Studio
  layouts and capture rendered Windows screenshots.
- Update [AnimationAuthoring.md](../../Editor/Documentation/AnimationAuthoring.md)
  and its entry in [EditorGuide.md](../../Editor/Documentation/EditorGuide.md).
  Verify the manual installation and wave example in the staged release.
- Submit the finished changes and output evidence for independent review. Run
  the contribution checks and verify the final task status before release.
