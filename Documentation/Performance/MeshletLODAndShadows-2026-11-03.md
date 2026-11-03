# Иерархический LOD мешлетов и качество теней

Дата: 2026-11-03. Продолжение [native frustum v1](MeshletsImplementation-2026-11-03.md).

## Изменение поведения

Прежние мешлеты сохраняли все исходные треугольники и только отбрасывали невидимые кластеры. Теперь подготовленный forest содержит настоящие упрощённые родители групп. Для каждой исходной области выбирается либо родитель, либо его потомки. Удалённые области могут стать грубее независимо от близких, внутри одного исходного mesh part. Геометрия разных материалов не объединяется.

Демка явно включает LOD с порогом 2 пикселя; кнопка «LOD» переключает Off / 1 / 2 / 4 / 8 px. Большее значение допускает более грубую геометрию. В движке default остаётся 0 (выключено), старые сцены декодируются без LOD. Режим мешлетов `disabled` сохраняет исходную геометрию. Карта — отдельная диагностика выбранного cut; L0 сохраняет разные цвета ID, L1–L4 получают голубой/оранжевый/розовый/фиолетовый оттенок и показывают счётчики уровней. Это не переименование прежнего PT lighting LOD.

В демке увеличены солнечные карты с 1024 до **2048 пикселей на каскад**, локальные — с 512 до **1024 на face/tile**. Охват солнечных теней увеличен с **30 до 80 метров**; cascade split lambda 0.85 сохраняет большую плотность ближе к камере. Для трёх солнечных каскадов atlas 6144×2048. Локальный atlas имеет шесть faces в строке и до четырёх lights: до 6144×4096. Сохраняется 32-bit float depth: локальный atlas R32F, солнечный RGBA32F. Кнопка «Тени» возвращает baseline 1024/512, 30 m, lambda 0.65 для сравнения. Runtime defaults остальных сцен не изменены.

## Подготовка и точность

`python script/build_meshlet_tool.py` теперь собирает также offline `MeshletLOD`; `python script/prepare_meshlet_lod.py <model.gltf>` пишет adjacent `.gltf.meshletlod` и receipt. Meshoptimizer 1.3 и исходники simplifier/indexgenerator закреплены SHA-256. Новая C++ зависимость остаётся только в offline tool.

Листья группируют до четырёх scan-кластеров и точно сохраняют исходные indices. Родитель объединяет до четырёх соседних узлов и пытается сократить их triangle stream примерно наполовину. Используются LockBorder, absolute error и исходные vertex IDs; после simplify дополнительно сравниваются точные boundary edges. UV/normal seams не свариваются по позиции. Если сокращения нет или изменена граница, родитель не добавляется: группа остаётся forest root. Это может ограничить глубину и выигрыш, особенно на раздельных листьях Ivy.

Error хранит накопленную ошибку simplify с консервативным visual floor `0.001 × diagonal` для reduced parents. Floor предотвращает постоянный выбор zero-error planar parents вблизи; он не является строгой границей ошибки текстурного сигнала. Исходные материалы/вершины сохраняются; новые упрощённые triangle streams могут менять исходный порядок, поэтому exact triangle-sequence контракт v1 относится только к исходным листьям.

`ADAMLOD1` version 1 — отдельный little-endian ресурс до 512 MiB с source digest, index/cluster/node/root tables. Проверяются ranges, конечность bounds/errors, acyclic parent order, вложенные source spans, точные листья, монотонные ошибки и строгое сокращение родителей. Каждый полный cut ограничен исходным index count. Missing/stale/corrupt hierarchy не ломает source geometry и прежний `.meshlets`.

### Полная Sponza + Ivy

| Eligible geometry | Исходные треугольники | Самый грубый forest | Максимальный уровень |
| --- | ---: | ---: | ---: |
| Sponza, 401 opaque primitives | 3 738 878 | 2 172 290 | L4 |
| Ivy, 2 opaque primitives | 5 065 558 | 4 455 592 | L1 |
| Вместе | 8 804 436 | 6 627 882 | — |

Оставшиеся четыре alpha draws (8140 треугольников) сохраняют обычный путь. Coarsest — нижняя граница количества для подготовленного forest, **не обещанное число при обычном положении камеры**. Реальный cut определяется порогом ошибки. Обе полные hierarchy содержат 173 441 flat clusters и 34 657 nodes; оценка их static index/descriptor/node uploads — 150 265 160 байт. Самый большой flat index buffer — 66 174 564 байта; Ivy требует 69 747 clusters в одном LOD draw.

## Runtime и границы версии

CPU oracle и GPU используют одинаковые bounds/error и выбор неперекрывающегося cut. Экранная ошибка считается по unjittered projection и размеру выходного изображения, учитывает affine scale/shear и перспективное изменение clip W; near-plane uncertainty выбирает более мелкие узлы. Frustum rejection остаётся отдельным шагом на текущей jittered projection. Geometry не упрощается и не строится заново в render loop.

GPU сохраняет classify / group prefix / scatter и один indexed indirect draw на исходный eligible item. Scatter копирует один кластер группой из 64 потоков с соседними index loads/stores; dispatch разбит по двум измерениям до 1024 groups в строке. Прежний serial loop на каждый cluster invocation сохранён только в раннем evidence. LOD-only cap увеличен до 262 144 clusters/draw; остальные memory/device limits остаются проверяемыми. Node storage ABI 48 байт, view uniform 224, cluster descriptor 64 и indirect 20. Нередуцируемые parts используют прежний путь без бесполезного обхода и копирования LOD forest.

Карта выводит геометрию выбранных узлов, сливая соседние ranges. При наличии hierarchy она переиспользует один expanded stream между LOD On/Off и камерами; Off выбирает точные листья, вместо выделения второго полного vertex stream. Диагностический cache ограничен 768 MiB; allocation не относится к production performance и возможен серый fallback. Source/full geometry остаётся для независимых shadow/contact passes. LOD не упрощает PT BVH и не добавляет mesh shaders, streaming, cluster occlusion или cone culling.

Temporal motion guides требуют того же выбранного LOD, что и main depth. Для них используется отдельный immutable index cache и CPU cut, а не compacted GPU buffer после освобождения ring lease. При невозможности подготовить согласованные guides main также сохраняет source geometry. Принятый main cut отслеживается отдельно на каждом view/item; GPU/CPU/map fallback не превращается позднее в другой motion cut.

## Проверки

Окончательная native release validation после изменения scatter: **63 tests / 19 suites passed за 40,569 секунды** на Windows / RTX 4070 / Dawn D3D12. `script/validate_webgpu.sh` выполнил свежий SPIR-V → WGSL и настоящие GPU tests; включены Sponza executable/camera и DLSS runtime. Фильтр: `Meshlet|LocalShadowPrecision|ShadowFiltering|Render3DDebugViewSettingsTests|PathTracing|DLSS|Temporal3D|SponzaCameraTests|WGPUCommandCompletion`. В этот прогон входит чтение актуальных cache counters после On/Off/On. Дополнительный предшествующий focused run: 12 tests / 6 suites, 8,411 секунды; журналы не суммируются как разные тесты.

- CPU/GPU readback: fine / mixed / coarse complete cuts, 16 → 10 → 4 треугольника на тестовой поверхности, без ancestor overlap и пропусков source regions; near plane, off-axis frustum и общая hierarchy в разных draws одного command.
- Реальные pixels: совпадение силуэта и плоской текстуры при смешанных уровнях, стабильная карта actual parent geometry и счётчики выбранных уровней.
- Переключение карты On → Off → On: те же finest/coarse pixels и отсутствие повторного allocation. Проверка читает актуальный resource после каждого кадра.
- Реальный glTF loader: hierarchy v1-only / valid / stale / corrupt, без потери исходной геометрии и v1 meshlets.
- Temporal: искривлённые source 8 triangles против плоского parent 2 triangles; первый кадр после перемещения объекта, фактические motion/depth guides и независимый immutable index buffer.
- Shadows: реальное создание и resize atlas 128 → 1024 face pixels, invalidation static faces, упаковка фактического texel size; солнечный atlas 6144×2048. Прежний тест тонкого shadow caster и continuous cascade filtering также прошли.
- Python/native: **5/5 passed**, включая simplify 2048 → 602 triangles, exact boundary preservation, source coverage каждого cut и регрессию против повторного полного обхода всех positions на каждый node.

Остальные платформы не проверены этим прогоном: Metal код добавлен, но acceptance требует Metal-устройства; browser processor остаётся fallback. Полный `swift test --parallel` всего репозитория не заявляется. Журналы и receipts находятся в `Evidence/Meshlets/LODAndShadows-2026-11-03`.

## Методика native A/B

GPU LOD Off / 2 / 8 сравниваются на gallery rotation и неподвижном outside: три чередующихся раунда, warmup 1 секунду и измерение 4 секунды на случай, после общего прогрева outside 3 секунды и gallery 6 секунд. Выключены DLSS, local/flying lights, Hi-Z и карта; sun shadows одинаковы и используют 2048 pixels/cascade, coverage 80 m. Настройки LOD/shadows записаны в каждом случае.

Бенчмарк ограничивает SceneView до 1120×400 logical points независимо от размера native-окна. Фактическое pixel resolution записывается и должно совпадать на всех кадрах/случаях; иначе профиль останавливается. Первый прогон был отвергнут из-за изменения native-окна с 1890×784 до 3810×1638; он сохранён как `rejected-window-resize-benchmark.json.gz` и не считается сравнением производительности.

Измеряются интервалы публикации SceneView и CPU render-graph encode; это не GPU timestamps/native Present. GPU arguments читаются после измерения в `withExclusiveWorldAccess`, вместе со snapshot одного законченного кадра: последующие frames не могут заменить output/ring buffer во время readback. Прочтённое число — отдельный sample, а не среднее по движущемуся кадру. Снижение triangle count и само наличие LOD не означают ускорение portable compaction path.

### Окончательные результаты

Все 18 случаев: **1680×600 output pixels**, 2048/1024 shadows, sun distance 80 m. FPS каждого повтора — `1000 / mean(published interval)`; таблица показывает медиану трёх повторов, p95 — медиану трёх p95. CPU encode — медиана последних 32 graph records каждого случая, затем медиана повторов.

| Вид / GPU LOD | FPS | Mean interval, ms | p95, ms | Main CPU encode, ms |
| --- | ---: | ---: | ---: | ---: |
| Галерея / Off | 101,77 | 9,826 | 12,195 | 4,384 |
| Галерея / 2 px | 103,06 | 9,703 | 12,433 | 4,554 |
| Галерея / 8 px | 101,79 | 9,824 | 12,205 | 4,573 |
| Снаружи / Off | 84,87 | 11,783 | 13,523 | 5,745 |
| Снаружи / 2 px | 74,23 | 13,471 | 15,488 | 7,493 |
| Снаружи / 8 px | 72,96 | 13,706 | 15,660 | 7,572 |

Gallery FPS по повторам: Off 101,55 / 102,51 / 101,77; 2 px 100,76 / 103,07 / 103,06; 8 px 101,79 / 102,18 / 101,63. Разница укладывается в небольшой шум; ускорение не подтверждено. Последние GPU+fast-path+fallback samples дают около 1,08–1,10 млн triangles Off, 0,806–0,813 млн при 2 px и 0,737–0,755 млн при 8 px. Это отдельные конечные camera poses, не средняя нагрузка всей траектории.

Outside неподвижен: **8 812 576 → 6 705 172 triangles при 2 px (−23,9%)**, до 6 637 032 при 8 px. Все три readback samples совпадают. Для 2 px GPU compacted indices 18 463 677 / 3, плюс 542 473 fast-path triangles и 8140 alpha fallback. Активны 129 настоящих LOD GPU draws; 274 parts без сокращения используют обычный путь. В Off все 403 eligible parts проходят fully-visible bypass и GPU output отсутствует законно.

Несмотря на меньшую геометрию, outside FPS при 2 px ниже примерно на 12,5%, CPU encoding дороже примерно на 1,75 ms. Первоначальный scatter достигал только 32–34 FPS outside; после coalesced rewrite окончательные значения существенно лучше, но прежний прогон использовал 30 m shadow coverage и не является контролем с полностью идентичными настройками. Оба ранних набора сохранены отдельно.

**Performance rollout gate остаётся открыт.** Иерархический LOD и визуальная карта работают; переносимый compaction path пока не даёт универсального выигрыша. Engine defaults остаются disabled / pixelError 0; демка явно включает 2 px для исследования. Следующее направление — уменьшить CPU/per-draw compute submission, затем отдельно измерять global batching или native mesh shaders. Это не включено скрыто в текущую версию.

## Живая демка

Проверены gallery и outside, карта и обычное изображение. Включены 12 локальных lights, high shadows 80 m и LOD 2 px; DLSS Quality действительно кодирует 1260×523 → 1890×784, fallback 0. Это отдельная функциональная проверка, не FPS benchmark. Карта автоматически отключает temporal scaling и показывает настоящую геометрию выбранных узлов. Пол, стены, колонны и Ivy сохраняются; обычный и диагностический снимки находятся рядом с evidence.
