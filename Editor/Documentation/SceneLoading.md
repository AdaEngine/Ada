# Large scene loading

The editing viewport prepares imported models, their authored LOD alternatives and
Spine skeletons asynchronously before installing the scene. It uses the parsed,
possibly unsaved document model. Closing the viewport or replacing the document
cancels preparation; generation checks prevent an older request from installing.
Large scene documents also decode off the UI actor before the viewport is created.
Installation suspends the preview's hosted frames and yields between small batches
of entities, allowing the editor UI to continue drawing its last completed texture.

JSON scenes parse component values through Foundation's JSON value parser and
decode the small typed document envelope separately. YAML scenes keep their
existing decoder. The editing world omits physics-body geometry because it has
no physics simulation; the source document and Inspector retain the complete
payload, and Play uses the ordinary physics-loading path.

`EditorSceneAssetCache` retains strong asset handles in the preview world. Repeated
references, including nested scenes, reuse one imported model. Reloading authored
scene data reuses unchanged model files and prunes resources absent from the new
scene. Modification date and size changes of a model/skeleton file trigger a fresh
import. An invalid model produces entity warnings without preventing the rest of
the scene from opening. The cache is released with the world.

Model material import shares identical encoded texture contents across model
documents. Cache identity also includes color interpretation, sampler settings
and render device. Materials remain separate mutable objects. The texture index
contains weak references, so it does not retain unused GPU textures. Edited image
contents produce a different key on import.

The native glTF importer validates each complete strided accessor range before
reading through one borrowed byte buffer. Floating-point attributes use unaligned
little-endian loads; normalized integers and sparse overrides retain their
existing conversion rules. Out-of-range offsets fail before pointer access.

These are loading and resource-sharing improvements. Scene zones and individual
texture mip levels are still loaded in full; this does not implement world or
texture streaming.

## Reproducing the Last Autumn workload

Run the focused ownership, cancellation, changed-file and texture tests:

```powershell
swift test --package-path Editor --filter EditorSceneAssetCacheTests
```

Select a real scene for the editing-viewport benchmark:

```powershell
$env:ADAEDITOR_PREVIEW_BENCHMARK = 'D:\Development\LastAutumn\Assets\Scenes\Courtyard.ascn'
$env:ADAEDITOR_PREVIEW_BENCHMARK_REPORT = 'D:\Temp\courtyard-preview.json'
swift test --package-path Editor --filter realPreviewBenchmark
```

The report records document decode time, total preview load time, maximum main
actor gap, entity counts, import counts and warnings. Its renderer is headless;
native window responsiveness and displayed scene contents require a separate
Studio check. Follow the Windows dependency setup in `AGENTS.md` when building
manually, and use the normal complete distribution for native validation.

The independent `EditorRuntimeScenePreparationTests.realScenePreparationBenchmark`
uses `ADAEDITOR_SCENE_BENCHMARK` and `ADAEDITOR_SCENE_BENCHMARK_REPORT`. It measures
asset preparation, rather than the full editing-viewport load. Keep that scope
distinction when comparing measurements.

### Courtyard measurements (Windows, 2026-10-27)

The Debug/headless workload contains 1,918 authored entities, 17,549 runtime
entities and 638 distinct model imports, including the authored LODs. Assets and
scene contents were not reduced. Measurements from this optimization run:

| Measurement | Initial measurement | Final measurement |
| --- | ---: | ---: |
| Runtime scene asset preparation, same benchmark | 365.54 s | 82.90 s |
| Full editing preview, including document decode | 112.67 s | 76.86 s |
| Longest UI-actor gap during editing preview | 10.32 s | 0.63 s |
| Preview process peak working set | 9,476 MiB | 2,654 MiB |

The initial editing-preview measurement already included asynchronous asset
preparation and texture sharing; it is an intermediate baseline, rather than an
unmodified-engine measurement. The final preview also exercises the production
file/document opening path: the request returns in 0.018 s and document decoding
finishes in the background after 20.65 s. All 638 models import once and no model
or skeleton load failures occur. The headless fixture does not register project
gameplay components, so their unknown-component warnings are expected.

These timings describe this machine and Debug workload, not native Release FPS
or a guarantee of frame-perfect loading. GPU presentation is validated separately
in a complete Windows Studio distribution.

Native acceptance used the complete `scene-loading-release-20261027-r2` Windows
distribution. The original Last Autumn project restored `Courtyard.ascn`; the
resource-loading message was visible, menus responded during preparation, and the
loaded viewport displayed textured buildings, road and autumn trees. No scene or
asset contents were edited for this check. This establishes loading/presentation,
not gameplay physics or an FPS benchmark.
