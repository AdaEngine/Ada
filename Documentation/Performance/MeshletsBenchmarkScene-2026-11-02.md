# Внешняя benchmark сцена для рендерера и мешлетов

- Дата выбора: 2026-11-02.
- Выбрано: **Intel Sponza 2022**, два уровня нагрузки: Base и Base + Ivy.
- Статус: оба архива закреплены по SHA256; native importer, camera poses и Hi-Z pixel equivalence проверены; baseline снят. Geometry-bound gate открыт.
- Машиночитаемый descriptor: [intel-sponza.json](../../Tools/3DAssets/BenchmarkScenes/intel-sponza.json).
- Контекст: [P0 baseline](MeshletsP0-2026-11-02.md), [ADR-0028](../ArchitectureDecisions/0028-meshlets-and-portable-cluster-culling.md).

## Выбор сцены

[Intel GPU Research Samples](https://www.intel.com/content/www/us/en/developer/topic-technology/graphics-research/samples.html) публикует Sponza в glTF и дополнение Ivy с полностью геометрическими растениями. Base даёт архитектуру, коридоры и occlusion; Ivy добавляет крупные opaque draws для проверки отсечения внутри одного part. Сцена используется как внешний P0 baseline; geometry-bound bottleneck ещё предстоит доказать.

Статистика ниже вычислена по accessors/mesh primitives/node references **из glTF внутри официальных архивов**, а не по рекламному числу полигонов. Сохраняются исходные material boundaries и mesh instances.

| Характеристика | Base | Ivy add-on | Вместе |
| --- | ---: | ---: | ---: |
| Triangles, с учётом mesh nodes | 3747018 | 5065558 | 8812576 |
| Meshes | 115 | 2 | 117 |
| Primitives / parts | 405 | 2 | 407 |
| Самый крупный part, triangles | 84602 | 4905636 | 4905636 |
| Материалы | 27 OPAQUE, 1 BLEND | 2 OPAQUE | 29 OPAQUE, 1 BLEND |
| Geometry buffer | 139973456 bytes | 269978952 bytes | 409952408 bytes |

Base содержит 83 opaque parts размером не менее 10000 triangles; каждый mesh используется одним mesh node. В Ivy оба part opaque и больше 100000 triangles. Поэтому тяжёлый профиль проверяет и много отдельных parts, и очень крупную геометрию внутри одного draw.

Geometry-профиль исключает 8140 BLEND triangles Base: остаются 3738878 triangles / 401 part / 112 meshes; с Ivy — 8804436 triangles / 403 parts. Три BLEND-only mesh records удаляются, ссылки `node.mesh` перенумеровываются; сами nodes и transforms сохраняются. PBR-профиль сохраняет все исходные primitives, включая BLEND.

## Источники и формат

| Asset | Официальный download | glTF entry |
| --- | --- | --- |
| Base | [main_sponza.zip](https://cdrdv2.intel.com/v1/dl/getContent/830833), 3987608266 bytes | `main_sponza/NewSponza_Main_glTF_003.gltf` |
| Ivy | [pkg_b_ivy1.zip](https://cdrdv2.intel.com/v1/dl/getContent/726656), 1383921436 bytes | `pkg_b_ivy/NewSponza_IvyGrowth_glTF.gltf` |

Оба архива полностью загружены во внешний cache. В descriptor закреплены SHA256 архивов, glTF entries и geometry buffers; при извлечении зависимостей проверяется ZIP CRC. Receipt содержит длины и SHA256 каждого исходного файла и созданного geometry-профиля. Оригинальные glTF, buffers, PNG и credits сохраняются без изменений.

Все primitives имеют glTF mode 4 (triangle list); required extensions отсутствуют. Base содержит 72 PNG images и optional `KHR_lights_punctual`, Ivy не объявляет extensions. Draco, meshopt compression, KTX2 и DDS для выбранных glTF не требуются.

Текущий `NativeGLTFLoader` не реализует `KHR_lights_punctual`: optional extension игнорируется с warning. Benchmark задаёт свои фиксированные lights. Native import и runtime pixels проверены в Windows baseline ниже; для PBR требуется указанная ниже отдельная адаптация exporter rounding error.

В обоих архивах есть `credits_license.txt`: он содержит текст CC-BY-4.0 и отдельное introductory usage notice. Сохранять полный файл и авторские credits вместе с отдельно загружаемыми данными; descriptor не меняет лицензию сцены на лицензию AdaEngine. Крупные сторонние binaries/textures не добавляются этим срезом в Git.

## Почему этот профиль полезен для мешлетов

Предыдущая плоская сетка P0 не показала geometry bottleneck на RTX 4070. Здесь можно смотреть из коридора в атриум, проходить за колоннами и менять этаж: видимая доля реальной пространственной геометрии меняется. Статическая opaque Ivy также укладывается в семантическую область v1 без skinning, morphs и alpha-mask foliage.

Число triangles само по себе не закрывает performance gate. Сначала снять CPU preparation/encode, GPU geometry/prepass и frame throughput; отдельно провести resolution и geometry/opaque controls. Большой CPU draw submission cost и fragment shading могут по-прежнему доминировать.

Есть конкретное ограничение текущего дизайна: compacted indices для одного Ivy part занимают до **56.14 MiB на slot**, около **168.42 MiB на ring из трёх slots**. Это уже выше стартового P0 budget 32 MiB/view. В GPU-срезе понадобится обоснованный desktop memory profile либо другой способ emission; нельзя объявить Ivy поддержанной, пока весь тяжёлый part молча использует legacy fallback. На этом этапе бюджет не повышается.

## Протокол сравнения

1. **Dataset:** Base и Base + Ivy как отдельные presets. Исходные transforms, vertex/triangle order, material boundaries и instances сохраняются. Не объединять meshes и не упрощать geometry для получения нужного результата.
2. **Камеры:** атриум, нижний коридор и верхняя галерея. [Versioned routes](../../Tools/3DAssets/BenchmarkScenes/intel-sponza-routes.json) задают исходные camera keyframes, linear position / shortest-arc nlerp, 600 samples, FOV 60°, near 0.05 и far 200. glTF camera −Z переводится в AdaEngine +Z локальным поворотом Y на π. Движение привязано к sample index. Это маршруты рендеринга без character collision; имена обозначают области сцены.
3. **Geometry profile:** opaque subset, фиксированный простой материал и lighting, без screen-space effects. Один BLEND material Base явно исключается из этого профиля и отражается в counters. Source mesh files не изменяются; profile применяется при setup benchmark.
4. **PBR profile:** исходные материалы и PNG 4096×4096, фиксированные lighting/shadow settings и одинаковое разрешение. Отдельный `benchmark-pbr.gltf` исправляет единственную погрешность экспорта: `materials/12/emissiveFactor/2` у `light_bulb`, `1.00000012 → 1`. [glTF schema](https://raw.githubusercontent.com/KhronosGroup/glTF/main/specification/2.0/schema/material.schema.json) ограничивает emissiveFactor диапазоном [0, 1]; исходник отклоняется строгим importer как `invalidMaterial(12)`. Остальные значения, границы parts, buffers, textures и transforms сохраняются. Точная коррекция закреплена в descriptor и receipt; production validation не ослаблена. SSAO/SSR выключены, PBR включает directional shadows с тремя cascades, geometry — без shadows. Postprocess/AA не меняются между A/B; anti-aliasing — none.
5. **Режимы:** текущий CPU visibility; текущий GPU Hi-Z; затем meshlet frustum и meshlet Hi-Z после их реализации. Не приписывать подготовке сцены существование будущих режимов.
6. **Метрики:** per-view batch-size histogram, eligibility/fallback reasons, candidate/submitted triangles, memory peak, CPU extraction/list/encode, GPU pass time при доступности и frame throughput. GPU time не подменяется CPU update duration. На Windows нужен внешний GPU profile либо отдельная timestamp instrumentation.
7. **Correctness:** baseline pictures для фиксированных poses, независимые shadows, Hi-Z off/on и движения за колонны. Пропавший объект или изменённое качество не считаются ускорением. Новые golden GPU cases остаются под `Render3DGPUTests`.
8. **A/B:** минимум три чередующиеся пары с прогревом shaders/assets, raw samples и одинаковыми profiles. Загрузку/декодирование ассетов, route construction, readback и debug overlays исключать из steady-state timing.

## Другие проверенные варианты

- [Amazon Lumberyard Bistro / ORCA](https://developer.nvidia.com/orca/amazon-lumberyard-bistro) — полезная вторая сцена для exterior/interior и независимого результата. Официальный источник указывает CC-BY-4.0 и FBX/Falcor. Проверенная [glTF-версия NVIDIA RTXDI](https://github.com/NVIDIA-RTX/RTXDI-Assets/tree/main/bistro) использует `KHR_materials_pbrSpecularGlossiness`, `KHR_materials_transmission` и `MSFT_texture_dds`, которые текущий native importer не реализует. Перед честным PBR benchmark нужна проверенная конвертация материалов/textures.
- Сцена `Sponza` в Khronos Sample Assets — другой asset variant. Его [LICENSE.md](https://github.com/KhronosGroup/glTF-Sample-Assets/blob/main/Models/Sponza/LICENSE.md) указывает Cryengine Limited License Agreement для model files. Этот вариант не используется как источник выбранного dataset.

## Воспроизведение

`script/fetch_benchmark_scene.py` загружает два закреплённых архива с resume, проверяет длины/SHA256 и извлекает только glTF dependencies и полные notices. Исходники и derived profiles находятся во внешнем cache, а не в Git. `receipt.json` получает `status: complete` только после успешной подготовки обоих архивов. Около 5.37 GB архивов; вместе с resume chunks и извлечёнными файлами нужно больше свободного места.

```powershell
python script/fetch_benchmark_scene.py
python script/fetch_benchmark_scene.py --verify
python -m unittest discover -s script -p test_fetch_benchmark_scene.py
python script/webgpu_validation_package.py .build-codex/meshlets-p0/validation-package

# Native WebGPU; use the pinned Tint from Tools/Tint.
$env:ADAENGINE_WEB_EXPORT = '1'
$env:ADAENGINE_GOLDEN_WEBGPU = '1'
$env:TINT_EXECUTABLE = 'D:/Development/AdaEngine/.build-tools/tint/bin/x86_64-windows/tint.exe'
$env:ADAENGINE_SHADER_SOURCE_ROOT = 'D:/Development/AdaEngine'
$env:ADAENGINE_SPONZA_BASELINE = '1'
$env:ADAENGINE_SPONZA_ASSETS = 'D:/Development/AdaEngine/.build-codex/benchmark-assets/intel-sponza/assets'
$env:ADAENGINE_SPONZA_ROUTES = 'D:/Development/AdaEngine/Tools/3DAssets/BenchmarkScenes/intel-sponza-routes.json'
$env:ADAENGINE_SPONZA_OUTPUT = 'D:/Development/AdaEngine/.build-codex/sponza-baseline'
swift test --package-path .build-codex/meshlets-p0/validation-package --scratch-path .build-codex/meshlets-p0 -c release -Xswiftc -enable-testing --no-parallel --filter Render3DGPUTests/SponzaBenchmark
python script/summarize_sponza_baseline.py .build-codex/sponza-baseline/sponza-baseline.json
```

Paths в примере заменить на путь своего checkout. На Metal использовать `ADAENGINE_GOLDEN_METAL=1` вместо WebGPU selector. Defaults: оба presets, оба quality profiles, три routes, 1280×720, 60 warmup + 600 measured frames, три чередующиеся пары Hi-Z off/on. Env overrides с префиксом `ADAENGINE_SPONZA_`: `PRESET` (`sponza-base` / `sponza-ivy` / `all`), `QUALITY` (`geometry` / `pbr` / `all`), `ROUTE` (route id / `all`), `WIDTH`, `HEIGHT`, `FRAMES`, `WARMUP`, `ROUNDS`. Для разных controls нужны отдельные output directories.

Все GPU suites остаются вложены в serialized `Render3DGPUTests`. Опциональный benchmark не запускает загрузку по сети из теста и не меняет обычный renderer path. Внешние assets нужны только при opt-in. На каждой паре сравниваются exact pixels в трёх фиксированных poses, с проверкой содержательного изображения. PNG readback и import исключены из throughput timing. Сводка отклоняет неполные/дублированные A/B rounds; raw JSON сохраняется после каждой законченной пары. При прерывании это частичный отчёт, а не полный baseline.

Geometry profile сохраняет двусторонность исходных opaque материалов, включая Ivy; `singletonTriangles` ещё не является полной meshlet eligibility. Cone culling для double-sided материалов должен оставаться выключен.

Освещение фиксировано: directional light intensity 3, rotation Euler [-0.4, 0.5, 0], без импортированных lights, skybox и IBL. PBR использует exposure +3 EV для читаемости затенённого интерьера, geometry — 0 EV; auto exposure выключена, tone mapper — ACES. Экспозиция одинакова между Hi-Z off/on. Все исходные textures сохраняют разрешение; суммарная оценка 75 уникальных RGBA8 textures с mip chain — 6.25 GiB. Это оценка текстурных данных, не измеренный process/VRAM peak.

## Native baseline: результат

Windows 11 Pro 10.0.26300, Ryzen 9 7900X, RTX 4070, driver 610.88 / 32.0.16.1088, Swift 6.3.1, native WebGPU / Dawn D3D12. Swan `790df787281e9cf1c2358a11bb42b2ec2df01029`, Dawn 148.0.7778.97. Release с `-enable-testing`; использован task-local Dawn bundle из уже имеющегося pinned cache, без изменения общей `.build`. Сборки и загрузки во время финальных замеров не выполнялись; активность общего desktop не контролировалась.

Два завершённых прогона: 72 измерения при 1280×720 и 36 geometry-controls при 640×360, всего **64800 measured frames**, три чередующиеся пары на каждый случай. Все **162 exact pixel comparisons** Hi-Z off/on прошли. Каждый контрольный кадр и последний измеряемый кадр дополнительно проверяют фактическую матрицу камеры: она совпадает с запрошенной позой в том же кадре. Стенд публикует world matrix своей root-камеры до preUpdate; обычная postUpdate propagation сама по себе дала бы задержку камеры. В отчёте закреплён `cameraPoseProtocol: same-frame-root-world-pose-v1`.

[Raw 720p](../../Evidence/Meshlets/Sponza-2026-11-02/native-720p.json), [полная CPU/census сводка](../../Evidence/Meshlets/Sponza-2026-11-02/native-720p.md), [raw 360p](../../Evidence/Meshlets/Sponza-2026-11-02/geometry-360p.json), [360p summary](../../Evidence/Meshlets/Sponza-2026-11-02/geometry-360p.md), [provenance и hashes](../../Evidence/Meshlets/Sponza-2026-11-02/manifest.json).

Ниже median drain-inclusive ms/frame по всем трём раундам, без выбора лучшего. Это throughput, не GPU pass time и не percentile отдельного кадра. Native WebGPU использует окна по 90 submissions с queue completion; import, warmup, readback, geometry digest и отдельные CPU diagnostics исключены из throughput.

| Preset | Profile | Route | 720p Hi-Z off | 720p Hi-Z on | 360p Hi-Z off |
| --- | --- | --- | ---: | ---: | ---: |
| Base | geometry | atrium | 2.129 | 2.541 | 1.988 |
| Base | geometry | ground-floor-corridor | 2.399 | 3.012 | 2.524 |
| Base | geometry | upper-gallery | 2.341 | 2.640 | 2.551 |
| Base | PBR + shadows | atrium | 6.319 | 6.907 | — |
| Base | PBR + shadows | ground-floor-corridor | 7.455 | 8.169 | — |
| Base | PBR + shadows | upper-gallery | 7.673 | 8.203 | — |
| Base + Ivy | geometry | atrium | 2.110 | 2.889 | 2.243 |
| Base + Ivy | geometry | ground-floor-corridor | 2.737 | 2.869 | 2.447 |
| Base + Ivy | geometry | upper-gallery | 2.646 | 3.132 | 2.424 |
| Base + Ivy | PBR + shadows | atrium | 6.452 | 7.326 | — |
| Base + Ivy | PBR + shadows | ground-floor-corridor | 7.554 | 8.381 | — |
| Base + Ivy | PBR + shadows | upper-gallery | 7.510 | 8.267 | — |

В конечных poses geometry Base содержит 1.65–3.01 млн triangles / 168–309 batches; с Ivy — 6.72–8.08 млн / 170–311 batches. Histogram всех batches — один instance: крупная геометрия действительно доходит до renderer, batching не превращает её в прежний instanced control. Это потенциал для meshlet coverage, а не полный material/deformation eligibility.

Уменьшение числа pixels в четыре раза не даёт устойчивого ускорения geometry-профиля; добавление 5.07 млн Ivy triangles также не вызывает сопоставимого роста времени. Hi-Z в этом capture не ускоряет ни один 720p профиль. Разброс и общий desktop не позволяют трактовать небольшие проценты как надёжную границу. **Geometry-bound bottleneck не подтверждён**, GPU pass timestamp samples — 0; CPU app-update wall time не заменяет GPU profile. PBR здесь одновременно включает исходные материалы и shadows, поэтому разницу с geometry нельзя приписать одним текстурам.

Потенциальный compacted index output для видимой Ivy-сцены — 76.87–92.42 MiB на один slot, около 230.62–277.27 MiB на ring из трёх slots, без scratch и static meshlets. Это выше исходного 32 MiB/view budget ADR. Никакой такой memory allocation этим срезом не добавлена; resident peak VRAM/process memory не измерялся.

Проверки: Release focused product собран; оба финальных Sponza runs прошли; 11 visibility/indirect/camera-motion/resize/frame-reuse/metrics regressions прошли (`prepareCost` opt-in пропущен); 7 проверок загрузчика и 3 проверки сводки прошли; Tint hash/reader/writer smoke прошли. Офлайн-проверка подтвердила SHA256 обоих архивов и всех 85 prepared files. [Regression log](../../Evidence/Meshlets/Sponza-2026-11-02/regression.log), [asset verification](../../Evidence/Meshlets/Sponza-2026-11-02/asset-verification.log), [receipt](../../Evidence/Meshlets/Sponza-2026-11-02/assets-receipt.json). Shader/backend production sources не изменены.

Metal, browser runtime, full root test matrix, full native validation script, exclusive CPU encode time и GPU timestamps этим Windows-срезом не проверены.

**Решение:** сцена подключена как воспроизводимый внешний baseline. P0 performance gate остаётся открытым; следующий performance-срез — GPU timestamps/profile на целевом backend и проверка memory strategy перед GPU meshlet rollout. CPU builder/schema можно готовить независимо; meshlet renderer и новые режимы этим срезом не реализованы.
