# Last Autumn — проверка основы

Проверено 24 октября 2026 по локальному checkout `7ff6a672e` (`main`, на один
коммит впереди `origin/main`). Сеть/свежесть remote не проверялись. Просмотрены
текущие исходники через CodeGraph, существующие тесты и доступный Ada Studio MCP.
Сборки, GPU-тесты и игровой Play в рамках этой подготовки не запускались.

## Среда

- Swift 6.3.3; правила проекта ориентированы на Swift 6.2 и строгую concurrency.
- Blender 5.1.1 установлен в `/Applications/Blender.app`. Проверена версия;
  экспорт моделей и создание игровых ассетов ещё не выполнялись.
- В Ada Studio открыт `Shader Graph Smoke`, документ `Surface.shadergraph`,
  статус editing/Ready. Открытых сцен MCP не вернул. Этот проект не изменялся.
- MCP поддерживает осмотр/валидацию/импорт GLB, сцены, Build/Test/Play и captures.
  Сам MCP Blender не запускает; Blender доступен отдельным локальным процессом.
- Два существовавших untracked-файла принадлежат другой работе:
  `Documentation/Plans/2026-10-24-studio-cli-game-verification.md` и
  `Tests/AdaEngineTests/StoreAnimationAcceptanceTests.swift`. Они не изменялись.

## Уже реализованная основа

| Потребность | Что найдено | Ограничение и следующий шаг |
|---|---|---|
| God rays | `VolumetricFog3D`, `Fog3D`, `VolumetricFog3DRenderNode` | Half-resolution raymarch первичного directional light через каскадную shadow map; это не локальные froxel volumes. Проверить лучи через окна/листву в игровой сцене. |
| Bloom и цвет | `PostProcess3D`, `Bloom3D`, `AutoExposure3D`, `ColorGrading3D`, vignette, LUT | Настроить существующую цепочку. Bloom не доказывает наличие lens flare. |
| Тени/окклюзия | `ShadowSettings3D`, `ScreenSpaceAO3D`, `LocalShadowSettings3D` | До трёх каскадов; локальные теневые источники имеют ограниченный бюджет. Измерить устойчивость в большой карте. |
| Отражения | `Environment3D.screenSpaceReflection`, IBL | SSR теряет данные за экраном. Не обещать dynamic GI, RT или полноценные отражения луж только на основании SSR. |
| Небо | `Skybox3D`, `Starfield3D`, параметры окружения | Время суток — игровая интерполяция света/неба/экспозиции/IBL; готовая система погоды этим не подтверждена. |
| Персонаж | `CharacterController3DComponent`, `CharacterController3DSystem` | Капсула, acceleration/braking, jump, ground snap. Высота/radius неизменяемые; нет готового crouch/mantle/roll в проверенном компоненте. Другие контроллеры с ним физически не сталкиваются. |
| AI-навигация | `Navigation3DPlugin`, `NavigationAgent3DComponent`, `NavigationMeshAsset` | Path-following через существующий контроллер. Поведение монстров, слух, боевые состояния и городская секторизация — игровые задачи. |
| Модели/клипы | `ModelAsset3D`, `ModelAnimationPlayback3DComponent`, skeletal pipeline | GLB/GLTF, до 128 joints, четыре влияния; импорт, named clips и фактическое проигрывание проверять отдельно. |
| Большой мир | `MeshVisibilitySettings3D`, mesh/animation LOD, culling | Это основа видимости, а не доказательство готового стриминга города с коллизиями и navmesh. Нужен игровой секторный lifecycle. |
| Кооператив | `MultiplayerSession`, `ReplicationRegistry`, LocalTCP/AppleLocal/CloudWebSocket, AdaScript network bridge | Транспорт уже есть. Правила рейда, позиции, урон, инвентарь и обращение напарника ещё нужно реализовать и проверить в двух процессах. |
| AdaScript-проект | `EditorAdaScript3DProjectTests` | Реальный project builder грузит сцены, модели, контроллеры и скрипты. Этот тест headless; он не доказывает графику новой игры. |

## Источники в репозитории

- [Окружение](../../../Sources/AdaCorePipelines/CorePipelines/Environment3D.swift).
- [Post-process](../../../Sources/AdaCorePipelines/CorePipelines/PostProcess3D.swift).
- [Fog и sun shafts](../../../Sources/AdaCorePipelines/CorePipelines/Fog3D.swift).
- [Реальный проход volumetric fog](../../../Sources/AdaCorePipelines/CorePipelines/RenderNodes3D/VolumetricFog3DRenderNode.swift).
- [Качество теней и SSAO](../../../Sources/AdaCorePipelines/CorePipelines/RenderQuality3D.swift).
- [Локальное освещение](../../../Sources/AdaCorePipelines/CorePipelines/LocalLighting3D.swift).
- [Капсула персонажа](../../../Sources/AdaPhysics/Physics3D/Components/CharacterController3DComponent.swift).
- [Навигационная интеграция](../../../Sources/AdaScene/3D/Navigation3DPlugin.swift).
- [Multiplayer session](../../../Sources/AdaMultiplayer/MultiplayerSession.swift).
- [AdaScript network runtime](../../../Sources/AdaMultiplayer/AdaScriptNetworkRuntime.swift).
- [AdaScript project integration](../../../Editor/Tests/AdaEditorTests/EditorAdaScript3DProjectTests.swift).
- [Render post-process tests](../../../Tests/AdaEngineTests/Render3DPostProcessTests.swift).
- [Fog tests](../../../Tests/AdaEngineTests/Render3DFogTests.swift).
- [Renderer roadmap](../../ArchitectureDecisions/0027-3d-rendering-pipeline-gap-roadmap.md).

Старые вводные абзацы ADR-0019/0027 перечисляют уже закрытые пробелы. Для
планирования использованы текущие исходники и последующие отметки реализации,
а не только начальный список отсутствовавших возможностей.

## Что требует реализации или отдельного доказательства

1. Удобное FPS-управление с capture/release курсора и независимой инерцией оружия.
2. Безопасное изменение высоты капсулы, проверка пространства и parkour sweep.
3. Опциональная деформация линзы/солнечный flare с корректной окклюзией.
   Motion blur не является обязательным для камеры; ADR-0027 пока отмечает его
   незавершённым. Не связывать читаемость игры с этой возможностью.
4. Согласованный lifecycle городских секторов: render/physics/nav/AI/loot state.
5. Собственные low-poly модели, риги, клипы, листва и звуковая постановка.
6. Игровые правила шума, контрактов, времени, добычи, смерти и сохранений.
7. Host-authoritative кооператив и защита инвентаря от повторных событий.

Это рабочие границы исследования: наличие названного API не означает, что оно
уже проверено в нужном масштабе. Новые ограничения уточняются первым Play и
измерениями. Никаких изменений общего движка для этой игры ещё не сделано.
