# Meshlets v1 — реализация и проверка, 2026-11-03

## Реализованный контракт

Первая версия добавляет подготовленные кластеры без упрощения модели, CPU reference, GPU frustum culling и отдельную карту кластеров. Обычный renderer остаётся значением по умолчанию для движка и старых сцен. Sponza явно включает экспериментальный GPU-режим; кнопка переключает `disabled / cpuReference / gpu`, соседняя «Карта мешлетов» показывает разбиение цветом.

Native WebGPU проверен на Windows / RTX 4070 / D3D12, Swift 6.3.1, pinned Swan/Dawn 148. Metal processor реализован, но на этой машине не собран и не проверен на устройстве. Browser processor пока возвращает `nil`. Это frustum-only версия: совместное meshlet Hi-Z и cone culling остаются отдельными этапами. При включённом существующем Hi-Z используется прежний renderer.

### Подготовка данных

`script/build_meshlet_tool.py` собирает отдельный CPU tool с meshoptimizer 1.3, commit `9e1f07b159d3cb777f1c67ed31fc11fd117986f4`, проверяя исходники и лицензию по SHA-256. C++ dependency не попадает в SwiftPM runtime/WASM graph. `script/prepare_meshlets.py --builder native` пишет adjacent `.gltf.meshlets` и JSON receipt. Python reference scan используется для независимого сравнения. Профиль 64 вершин / 96 треугольников сохраняет исходную последовательность всех треугольников, включая winding, повторения и degenerates.

Полная Sponza + Ivy: **8 812 576 треугольников, 122 845 кластеров, 407 primitives**. Исходные `.gltf`/`.bin` не изменены. Подготовлены также оба `lighting-pt.gltf`; мешлеты не являются PT LOD и не ускоряют программный BVH tracer. Provenance и сравнение 64/64, 64/96, 64/126 находятся в `Evidence/Meshlets/Preparation-2026-11-03`.

Дисковый формат `ADAMSHL1` version 1 — явные little-endian поля, header 24 байта, part 28, cluster 32. Reader ограничивает размер 64 MiB и проверяет размеры, диапазоны, coverage, конечность bounds, дубликаты part identity и normalized-geometry digest. Неподдерживаемый, устаревший, отсутствующий или повреждённый sidecar оставляет исходную геометрию. Source-buffer identity/index-count replacement инвалидирует prepared data. Изменение содержимого GPU buffer на месте требует пересоздания поколения mesh; автоматический derived-file hot reload/export packaging пока не добавлен. При ручной доставке sidecar должен лежать рядом с моделью.

### Рендер и ограничения

Eligibility проверяется после прежнего coarse culling, LOD и batching: static opaque PBR, singleton batch, triangle list, prepared data и draw pass, явно реализующий `MeshletGeometryDrawPass`. Instancing, MASK/BLEND, skin/morph, Shader Graph, parallax, force-visible и неизвестные passes сохраняют обычную геометрию. В этом наборе Ivy использует OPAQUE; четыре BLEND draw архитектуры остаются fallback.

CPU reference объединяет соседние видимые диапазоны. GPU использует консервативный world AABB / шесть frustum planes с теми же правилами, включая affine reflection, nonuniform scale и shear. Полностью содержащийся в frustum part сразу использует исходный draw. Для частичных частей три compute-прохода на view классифицируют кластеры, выполняют prefix scan по группам из 256 потоков и scatter индексов. Порядок primitives сохраняется; остаётся один indexed indirect draw на исходный coarse draw, а не draw на кластер. GPU ABI: descriptor 64, view 144, indexed arguments 20 байт.

Compute и потребляющий raster находятся в одном command buffer; ring slot освобождается completion handler либо при уничтожении неотправленной команды. Исходные buffers остаются для fallback, теней, motion и contact passes. При отказе allocation/capability/indirect исходные index buffer и count восстанавливаются вместе. Обычные кадры не делают CPU readback GPU counts.

Лимиты: один buffer до 128 MiB, device-owned immutable upload cache до 256 MiB, transient resources до 192 MiB на ring slot, неактивный draw-resource cache до 32 MiB на slot; до 65 536 кластеров на draw и 524 288 на encode. Лимиты устройства проверяются дополнительно. Это отдельные бюджеты, а не общий физический GPU-memory ceiling. Кэши сохраняются при переключении режима Off и освобождаются с владельцами.

### Карта мешлетов

`DebugView3D.meshlets` показывает стабильный цвет настоящего local cluster ID. Геометрия целиком сохраняет силуэт; серым отмечены surfaces без подходящей карты. Диагностический expanded vertex stream создаётся при первом запросе, ограничен 512 MiB и использует один draw на part. Он не запускает ненужную visibility compaction. Карта переключает демку в full-scene raster и отключает DLSS для вывода 1:1; PT остаётся отдельным режимом. Время и память карты не входят в production A/B.

## Проверка

Контрольная release-сборка через `script/validate_webgpu.sh` прошла **48 тестов в 13 suites за 28,573 секунды**. Фильтр: `Meshlet|Render3DDebugViewSettingsTests|PathTracing|DLSS|Temporal3D|SponzaCameraTests|WGPUCommandCompletion`; включены `ADAENGINE_VALIDATE_SPONZA=1` и `ADAENGINE_DLSS_TESTS=1`. Проверка включает свежий SPIR-V → WGSL, настоящие GPU pixels и readback, all/none/partial compaction, несколько draws, границы 255/256/257 и 65 536 кластеров, ring exhaustion/reuse, affine camera/object transforms, карту и fallback нестандартного DrawPass. ModelAsset3D тестируется на реальных временных glTF с missing/valid/stale/corrupt sidecars. PT/DLSS/temporal/camera/completion регрессии также входят в фильтр. Журнал: `Evidence/Meshlets/Implementation-2026-11-03/validate-meshlets-seventh.log.gz`.

`python script/test_prepare_meshlets.py`: **3/3 passed**, включая вызов native builder для трёх профилей. `git diff --check` прошёл. Это проверка выделенного native validation package, не заявление о полном `swift test --parallel` для всего репозитория и всех платформ.

Ранее запущенные соседние suites проверили shadow filtering, skinning batches и прежний WebGPU visibility. Четыре несовпадения старых golden images воспроизводят прежний baseline побайтно: SHA-256 actual PNG совпадают с сохранёнными до meshlets. Сравнение находится в `Evidence/Meshlets/Implementation-2026-11-03/legacy-golden-comparison.json`; references не перезаписывались.

## Методика A/B

`ADAENGINE_SPONZA_PROFILE_MESHLETS=1` сравнивает три режима на полной сцене, без DLSS, локального/летающего света, Hi-Z и карты, с одинаковыми солнечными тенями. Прогрев: внешний вид 3 секунды и полный поворот галереи 6 секунд. Затем gallery rotation и stationary outside, три чередующихся раунда, по секунде прогрева и четыре секунды измерения: 18 случаев. Окно и разрешение фиксированы.

Измеряются интервалы публикации SceneView и CPU render-graph encoding, **не GPU timestamps и не native Present**. Фактический GPU index count читается только после измерения; это отдельный sample, а не среднее за интервал. Для полностью видимых частей compaction отсутствует, поэтому этот count может отсутствовать законно. Candidate, fast-path и fallback triangles записываются раздельно.

Первый serial-scan prototype оказался медленнее legacy; исходный JSON сохранён как `initial-serial-scan-benchmark.json.gz`. По этому измерению добавлены fully-visible bypass, групповой parallel scan и объединение compute encoding в три прохода на кадр. Числа этого отвергнутого прототипа не используются как результат окончательного варианта.

### Результаты окончательного native прогона

Разрешение всех 18 случаев: **1890 × 843**. FPS каждого повтора вычислен как `1000 / mean(published interval)`, таблица показывает медиану трёх повторов; p95 — медиана трёх отдельных p95. CPU encode — медиана sample timings `Main3DRenderNode`, отдельно от времени кадра.

| Вид / режим | FPS | Mean interval, ms | p95, ms | Main CPU encode, ms |
| --- | ---: | ---: | ---: | ---: |
| Галерея / disabled | 122,79 | 8,144 | 10,206 | 2,460 |
| Галерея / cpuReference | 116,17 | 8,608 | 10,943 | 2,467 |
| Галерея / gpu | 102,75 | 9,732 | 11,837 | 3,748 |
| Снаружи / disabled | 56,33 | 17,751 | 35,764 | 5,640 |
| Снаружи / cpuReference | 52,53 | 19,035 | 38,558 | 7,382 |
| Снаружи / gpu | 64,09 | 15,603 | 35,407 | 5,605 |

Галерея: FPS повторов legacy 122,79 / 123,08 / 120,89, GPU 102,75 / 99,94 / 108,28. Mean interval GPU хуже примерно на 19,5%; CPU encoding также дороже. Отсечение действительно выполняется: в последних samples 134–136 compacted draws, 56–58 fully-visible draws, четыре alpha fallback; compacted index count 1 546 164–1 592 766. Этот count не включает fully-visible/fallback draws и не является средним за движение.

Снаружи все 403 eligible parts проходят fully-visible bypass, compaction и её readback отсутствуют; остаются четыре alpha fallback. FPS повторов legacy 56,33 / 54,13 / 60,02, GPU 64,06 / 68,78 / 64,09. Положительную разницу нельзя приписывать meshlet rejection: оно здесь ничего не отсекает. Большие p95 и вариативность публикации требуют отдельного pacing/native-Present исследования, прежде чем считать этот контроль доказательством ускорения. CPU encode практически одинаков.

**Rollout gate не пройден:** на целевом gallery path остаётся регрессия, переносимость и полный контрольный набор ADR также не закрыты. Feature готова для функционального исследования и визуальной диагностики, но ускорение на этой Sponza не подтверждено. Engine default остаётся `disabled`; demo предоставляет явное сравнение режимов. Следующие исследования: сокращение per-draw uniform uploads/CPU planning, более тесные bounds либо spatial reorder с отдельными correctness gates, затем shared Hi-Z или native mesh shaders. Они не включены неявно в этот frustum-only результат.

Raw/summary JSON и stdout/stderr сохранены в `Evidence/Meshlets/Implementation-2026-11-03`. Живая демка проверена на переключение карты; карта показывает пол, стены, колонны, арки и Ivy полной сцены. Снимки галереи и внешнего вида сохраняются там же.
