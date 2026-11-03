# Подготовка и внедрение мешлетов в AdaEngine

- **Дата:** 2026-11-02.
- **Обновлено:** 2026-11-03.
- **Статус:** P0 baseline, Windows offline builder/sidecar, CPU reference и native WebGPU frustum v1 реализованы. P3–P4 имеют проверенный native WebGPU срез; Metal hardware acceptance, P5–P6 и performance rollout gate открыты.
- **Дизайн:** [ADR-0028](../ArchitectureDecisions/0028-meshlets-and-portable-cluster-culling.md), experimental native v1; расширенный roadmap остаётся Proposed.
- **Результат:** [Meshlets implementation](../Performance/MeshletsImplementation-2026-11-03.md). Актуальные correctness/A/B результаты и ограничения — в этом отчёте.
- **Дополнительный пользовательский срез:** [иерархический meshlet LOD и тени](../Performance/MeshletLODAndShadows-2026-11-03.md); отдельное расширение исходного frustum-only плана. Оно не закрывает Hi-Z/cone/browser/Metal acceptance.
- **База:** checkout `a7f0ce13`, существующие CPU visibility/LOD/batching и GPU Hi-Z из ADR-0020.

Цель подготовки — доказать полезность отсечения внутри больших моделей, закрепить asset/GPU contracts и получить последовательность небольших проверяемых изменений. Первая версия обслуживает статические opaque singleton draws; текущий instancing сохраняется. Аппаратные mesh shaders и виртуализированная геометрия — последующие направления.

## 1. Порядок и точки решения

```text
P0 baseline и целевые сцены
  -> P1 builder/toolchain spike и формат sidecar
  -> P2 CPU asset foundation и reference renderer
  -> P3 geometry override и Metal frustum-only GPU
  -> P4 native WebGPU parity
  -> P5 shared Hi-Z, optional cone и регрессии
  -> P6 browser acceptance и итоговые A/B
  -> решение о rollout и необходимости native mesh shaders
```

Завершение P0–P2 означает готовую CPU-подготовку, oracle и обоснованный GPU-контракт. Завершение P3–P6 означает проверенную реализацию на явно перечисленных устройствах. Это разные результаты; число пройденных этапов не заменяет performance evidence.

Фактический порядок native среза изменён под доступный Windows host: общий geometry override и оба backend source processors добавлены, а hardware correctness сначала проверяется на WebGPU/D3D12. Наличие Metal кода не закрывает Metal gate. Native v1 содержит три пакетных compute pass с parallel block/draw prefix scan и stable scatter, а fully-visible part сохраняет исходный draw без compaction. Отдельная карта мешлетов показывает реальные cluster IDs, использует diagnostic expanded-vertex cache до 512 MiB и серый fallback; это не карта GPU rejection.

## 2. Подготовка P0–P2

### P0 — измерить исходный renderer

- [x] Зафиксировать commit и task-owned diff; unrelated изменения текущего checkout не включать в feature.
- [x] Снять existing `Render3DGPUTests/Benchmarks` baseline в release и сохранить конфигурацию/результаты (native WebGPU; Metal отдельно).
- [x] Подготовить workloads с понятной лицензией: большой procedural mesh, occluder, all-visible, repeated instances, small-parts и четыре импортированные garden models.
- [x] Подключить Intel Sponza Base / Base + Ivy с pinned sources, geometry/PBR profiles, fixed routes и native Hi-Z A/B + resolution control. [Отчёт](../Performance/MeshletsBenchmarkScene-2026-11-02.md).
- [ ] Подтвердить geometry-bound крупную production-модель/сцену. Synthetic density/resolution controls на RTX 4070 этот gate не закрыли.
- [x] Снять triangles/part count, LOD, число batches и распределение `batchRange.count` после batching.
- [ ] Измерить CPU extraction/list/encode и отдельно GPU geometry/prepass на Metal. На native WebGPU записать доступный frame wall time без названия «GPU time».
- [x] Выполнить source audit asset cache/export lookup, import topology conversion, backend buffer usages и ring reuse. Native WebGPU regression tests пройдены; Metal/browser lifetime stress остаётся отдельной проверкой.

**Результат:** baseline report с hardware/OS/driver/Swift/Swan versions, scene hashes, resolution, camera path, shaders/postprocess, warmup и разбросом. Зафиксировать target workload, memory budget и A/B thresholds из ADR. Мешлеты в этой фазе ещё не ускоряют renderer.

Реализованный срез M0 и evidence: [P0 report](../Performance/MeshletsP0-2026-11-02.md). Шесть workloads и три controls прошли pixel comparisons, instancing сохранён; 11 regression tests прошли. Exit gate остаётся открытым: 32768–2097152 triangles дали почти одинаковый median throughput, GPU geometry bottleneck не доказан. Не объявлять M0 performance gate закрытым по факту готовности harness.

### P1 — проверить builder и форматы

- [x] Закрепить meshoptimizer 1.3 / `9e1f07b159d3cb777f1c67ed31fc11fd117986f4`, file SHA-256/MIT; собрать standalone C++ scan adapter на Windows clang++ без GPU.
- [ ] Проверить offline toolchain на macOS и headless Linux.
- [x] Runtime/WASM SwiftPM graph не получает offline C++ dependency; native tool живёт в `Tools/Meshlets` / `.build-tools`.
- [x] Зафиксировать float32/list/fan контракт с production importer; strips остаются legacy, unsupported sparse preparation отклоняется явно.
- [x] Сравнить 64/64, 64/96, 64/126 по utilization, duplicated references, end-to-end preprocessing и размеру sidecar: [evidence](../../Evidence/Meshlets/Preparation-2026-11-03).
- [ ] Дополнить profile comparison измерением bounds tightness и повторениями на других production assets.
- [x] Проверить точную triangle sequence scan-профиля; native adapter разворачивает remap и отклоняет loss/reorder. Spatial reorder не реализован.
- [x] Зафиксировать little-endian header/part/cluster records, checked decoder, 64-byte GPU descriptor и 20-byte indirect arguments. Runtime geometry fingerprint + source/dependency SHA-256 receipt задокументированы.
- [x] Сохранить winding, seams, дубликаты и degenerates; default 64/96 и explicit reference scan проверены.
- [x] Native missing/stale/corrupt sidecar fallback проверен; sidecar лежит рядом с model URL, absolute cache paths в сцене не нужны.
- [ ] Проверить полноценный export packaging/resource lookup, hot reload и browser delivery.

**Native Windows gate:** CPU-only pinned tool обрабатывает Sponza/Ivy без GPU; точная source sequence сохранена, malformed/stale данные отклоняются. Cross-platform toolchain/export gates остаются открыты. Наличие CPU foundation не закрывает performance gate.

### P2 — построить CPU reference

- [x] Optional immutable data у `Mesh.Part`, decoder/validation и cached source indices/descriptors на generation. Scan order совпадает с source, отдельной перестановки индексов нет.
- [x] Sidecar подключён в `ModelAsset3D`; geometry identity и O(1) buffer/count guards сохраняют корректный fallback при замене source buffers.
- [ ] Довести native hot reload/export lifecycle и проверить смену source/sidecar generation в полном asset workflow.
- [x] `disabled/cpuReference/gpu`, старые сцены decode в `disabled`; native GPU processor реализован.
- [x] CPU frustum, affine AABB transform, coalesced ranges, counters и отдельная карта cluster colors.
- [x] Native all-visible/frustum pixels и CPU/GPU indices сравниваются с оригиналом; cone/Hi-Z отсутствуют, references не перезаписываются ради feature.
- [x] Shared geometry не строится в render loop; eligibility после batching сохраняет многоэкземплярные draws на legacy.

**Gate подготовки:** подтверждены topology/bounds/ABI и реальные pixels, рассчитаны memory ceilings, reference воспроизводим. Для начала P3 не требуется обещание ускорения CPU reference.

## 3. Срезы реализации

Каждый PR включает ближайшие тесты и актуализацию документации. Цель размера — примерно 300–600 строк source/test на reviewable slice; большой backend/scan срез разделять по доказуемым инвариантам. Это ориентир, не повод оставлять production path незаконченным.

Текущее состояние: M0 performance gate открыт; M1–M5 реализованы в описанном native объёме, M6–M8 имеют source/native WebGPU реализацию, но Metal hardware gate открыт. M9–M12 остаются будущей работой; M13 имеет начальные native проверки/A/B, не rollout acceptance.

| Срез | Этап | Содержание | Зависит от | Критерий готовности |
| --- | --- | --- | --- | --- |
| M0 | P0 | Baseline scenes/report, eligibility histogram и memory/submission audit | — | Воспроизводимый baseline; выбран geometry-bound singleton workload |
| M1 | P1 | Standalone pinned meshoptimizer scan adapter, C API, offline preparation | M0 | Windows CPU generation/provenance реализованы; другие host toolchains остаются открыты |
| M2 | P1 | Immutable schema, checked decoder/writer, input validation и bounds | M1 | Triangle coverage, sidecar corruption/version tests, explicit GPU ABI |
| M3 | P2 | Asset sidecar/cache/export integration и per-generation GPU upload | M2 | Cold/cache/stale/reload paths; source geometry всегда доступна |
| M4 | P2 | Settings, eligibility, CPU reference ranges и debug view | M3 | Старые сцены и instancing без изменения поведения; CPU/golden equivalence |
| M5 | P3 | Per-item geometry override и instance-source selection | M4 | Main geometry override; shadows/motion/contact используют корректные original bindings |
| M6 | P3 | Metal resources/ring, segmented scan/scatter и indexed arguments | M5 | GPU readback совпадает с CPU; multi-segment, all/none, capacity и completion tests |
| M7 | P3 | Metal main-pass integration, frustum-only A/B | M6 | Реальные pixels и первый end-to-end performance report |
| M8 | P4 | Native WebGPU WGSL processor, usages и indirect integration | M7 | Layout/scan parity, real pixels, Tint/validation suite |
| M9 | P5 | Shared current-frame prepass/Hi-Z preparation для legacy и meshlet paths | M8 | Один prepass/pyramid на view; существующие GPU visibility и independent instance bindings не сломаны |
| M10 | P5 | Optional meshlet Hi-Z, current-depth rules и disocclusion regressions | M9 | Camera/object motion, occluder removal, odd sizes и near plane без false rejection |
| M11 | P5 | Optional cone culling с ограничением transforms/materials | M8 | Rigid/uniform-positive cases совпадают; reflected/shear/nonuniform/ortho fallback проверен |
| M12 | P6 | Browser export, sidecar delivery и Swan/WASM runtime acceptance | M8, M10 | Рабочий экспорт на указанном браузере/устройстве; native results отдельно |
| M13 | P6 | Full regression, A/B и rollout recommendation | M7–M12 | Correctness/performance/memory gates и перечень проверенных конфигураций |

M11 можно выполнить после frustum-only parity независимо от Hi-Z, но не смешивать его эффект с первыми A/B. M12 включает новую resource type в export manifest; успешная WASM компиляция без доставленного sidecar и pixels не закрывает этап.

Таблица выше сохраняет исходные зависимости проектирования, а не утверждает полное закрытие всех platform gates. В реализованном v1 production meshlets при `gpuOcclusion == true` используют `legacyOcclusion` fallback; shared prepass/pyramid и meshlet Hi-Z из M9–M10 ещё отсутствуют. Карта partition не запускает compaction, поэтому её timings не являются timings GPU visibility.

## 4. Правила, которые нельзя потерять между срезами

1. Builder и GPU loop не создаются в render hot path; source/derived geometry immutable в рамках поколения.
2. GPU v1 не делает draw на каждый meshlet: один compacted index segment и один indirect command на eligible singleton coarse draw.
3. Eligibility проверяется **после** существующего batching. Instanced batches не разбиваются для прохождения eligibility.
4. Исходные source buffers сохраняются. При ошибке переключаются вместе index buffer/count, arguments и instance binding.
5. Hi-Z optional, текущего кадра, общий на view; frustum-only работает без depth prepass.
6. Main camera mask не управляет shadows/motion/contact, collision/navigation или ray tracing.
7. Нет synchronous readback/frame allocation в обычном render loop; diagnostic readback только asynchronous opt-in.
8. Geometry generation/device identity входят в cache key; GPU completion управляет переиспользованием и освобождением ресурсов.
9. Unknown material/deformation, missing sidecar, resource limit и unsupported backend используют текущий renderer с измеримым fallback reason.

## 5. Матрица проверки

| Уровень | Проверка | Что доказывает |
| --- | --- | --- |
| CPU unit/property tests | Triangle multiset/winding/seams, bounds, invalid inputs, profile limits | Builder сохраняет геометрию; culling bounds консервативны |
| Asset integration | Real temporary source+sidecar, corruption/stale `.bin`, LOD mapping, reload и export lookup | Production loader/cache действительно использует sidecar или fallback |
| ABI | Swift/MSL/WGSL offsets, 20-byte indirect arguments и typed output index format | CPU/GPU читают одинаковые данные |
| Backend compute | GPU readback indices/arguments против CPU, scan across workgroups, zero results, multiple segments | Алгоритм compaction работает на реальном backend |
| GPU pixels | Legacy vs clusters; frustum/cone/Hi-Z по отдельности; transforms и камеры | Нет потерь/подмены геометрии в реальном raster path |
| Pass regressions | Independent shadows, motion/contact, temporal effects, MASK/BLEND, skin/morph, instancing | Feature isolation и fallback сохраняют существующее поведение |
| Lifecycle/resource | Ring completion, concurrent views, growth, resize, reload, close, allocation failure/limit | Нет stale bindings, use-after-free или частично потерянной модели |
| Browser | Export bundle + HTTP runtime + pixels на указанном browser/device | Работает WASM/JS integration и доставка derived asset |
| Benchmark | Alternating A/B, CPU/frame/GPU timings, память и counts | Выигрыш проверен для конкретной нагрузки и устройства |

Все новые root tests используют Swift Testing. GPU cases находятся внутри `Render3DGPUTests` для сериализации process-wide renderer. CPU-only тесты не выдают headless mock за выполнение GPU compute.

## 6. Команды подготовки и проверки native v1

Основные suites и offline commands уже существуют. Запускать подходящую конфигурацию на нужном устройстве; этот раздел — инструкция воспроизведения, не отчёт о выполнении на всех backend.

```powershell
# CPU preparation; native builder outside SwiftPM/runtime graph.
python script/build_meshlet_tool.py
python script/prepare_meshlets.py path/to/model.gltf --builder native
python -m unittest script/test_prepare_meshlets.py
swift test --filter MeshletGeometryTests
swift test --filter Render3DMeshletSettingsTests

# Real GPU meshlet indices/pixels/import/fallback coverage (enable selected backend).
swift test --filter Render3DGPUTests/Meshlets

# Existing nearest visibility regressions.
swift test --filter MeshVisibilityLOD3DTests
swift test --filter VisibleMesh3DListsEquivalenceTests

# Existing native WebGPU validation, from repository root in bash.
bash script/validate_webgpu.sh
python script/ensure_tint.py --check

# Existing Metal golden frames and performance harness: on a Metal host.
$env:ADAENGINE_GOLDEN_METAL = '1'
swift test --filter Render3DGPUTests
$env:ADAENGINE_PERF = '1'
swift test -c release -Xswiftc -enable-testing --filter Render3DGPUTests/Benchmarks

# Complete owning/regression checks after implementation.
swift test --parallel
git diff --check
```

Для WebGPU validation требуется совместимый Swan/Dawn и рекомендованный Swift 6.3.2 по `AGENTS.md`; package language/concurrency contracts проверять по текущему manifest. Для браузера дополнительно нужен настоящий экспорт и runtime smoke, не только этот native script. При stale-cache toolchain mismatch не менять общую `.build`, повторить команду с одним task-owned `--scratch-path` и переиспользовать его дальше. Environment flags задавать в отдельной test session либо восстанавливать после запусков.

## 7. Отчёт по окончании и rollout

Результат реализации должен содержать platform matrix с точными устройствами/версиями, source/profile hashes, coverage/golden результаты, CPU/GPU/frame times, persistent/transient peak и fallback distribution. Сравнивать baseline legacy, legacy Hi-Z, meshlets frustum-only и meshlets Hi-Z; cone — отдельное измерение. Включить all-visible и instanced negative controls.

Предложенные пороги: не менее 10% выигрыша median frame time на target workload; не более 3% median и 5% p95 регрессии на controls; память в согласованном P0 budget. Требуются минимум три чередующиеся A/B пары и разброс ниже проверяемой границы. Меньшее число треугольников само по себе gate не закрывает.

До достижения gates `disabled` остаётся default. В отчёте явно указать одно решение: рекомендовать opt-in на проверенном классе устройств; продолжить исследование из-за измеримого bottleneck; либо остановить portable rollout и сохранить CPU asset foundation. Native mesh shaders исследовать по конкретному bottleneck (например, index compaction bandwidth), отдельным срезом с новой capability/pipeline спецификацией.

## 8. Подготовка считается завершённой, когда

- [x] Native P0 baseline воспроизводим и действительно содержит singleton draws; counts и exact pixels проверены.
- [x] Внешняя Sponza-сцена проверена через production importer/renderer; 64800 measured frames и 162 exact Hi-Z comparisons прошли.
- [ ] Целевая production geometry-bound нагрузка подтверждена; P0 performance gate закрыт.
- [x] P1 native Windows builder/profile/sidecar contract закреплён и запускается без GPU; другие host toolchains остаются открыты.
- [x] P2 native topology/bounds/source lookup и reference pixels проверены; полный hot reload/export lifecycle остаётся открытым.
- [ ] Риски instancing, shader deformation, pass bindings, ring reuse и export имеют конкретные решения и тесты.
- [x] Native GPU frustum slices реализованы с completion-protected ownership и checked formats; Metal hardware/browser acceptance остаются открыты.

Реализованы P0 foundation и experimental native frustum v1: offline scan/sidecar, CPU/GPU rendering и отдельная карта мешлетов. [Implementation report](../Performance/MeshletsImplementation-2026-11-03.md) фиксирует фактическую проверку и A/B. Hi-Z/cone, Metal hardware, browser/export, полный lifecycle и performance rollout сохраняют отдельные незакрытые gates; default остаётся `disabled`.
