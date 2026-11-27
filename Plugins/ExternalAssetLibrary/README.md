# External Asset Library

This Ada Studio plugin adds a project-local gallery for saved Fab and Unity Asset Store listings. It needs a version of desktop Studio with the native External Asset Library host. Fab files come from the Fab website or launcher. Unity Asset Store files come through Unity. The gallery accepts self-contained GLB models and optional PNG or JPEG covers.

Build the Ada Asset Store upload ZIP with Python 3.

```text
python Plugins/ExternalAssetLibrary/package.py .build-tools/ExternalAssetLibrary.zip
```

In an open Ada Studio project, go to **Project Settings → Studio Tools**, choose **Install Plugin ZIP**, and review and enable the package. Open the gallery from the Studio Tools sidebar. Ada AI access is a separate project setting.

The ZIP contains the release manifest and Studio Tools declaration. [External Asset Library](../../Documentation/Designs/external-asset-library.md) and [Intents and tools for Studio plugins](../../Documentation/Designs/studio-plugin-ai-capabilities.md) describe the host contracts.
