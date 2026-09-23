# Web Player: экспорт AdaScript-проекта с iPad

Статус: профили `views` (runtime API 1–2) и `scene` (runtime API 3).
Описание первоначального прототипа API 1 сохранено ниже; расширение ресурсов
описано в `Demos/WebPlayer/ShaderGallery/README.md`.

## Профиль scene и запуск из AdaEditor

AdaScript-проект с `runtime.entry.scene` упаковывается вместе с `.ada`-исходниками,
`.ascn`, ресурсами и настройками ввода. Web Player запускает ECS-системы и
поддерживает компоненты сцены `Transform`, `Visibility` и `TileMapComponent`.
Другие компоненты сцены редактор отклоняет до экспорта.

Мультиплеер включается только при плагине `multiplayer`. В этом случае браузер
предлагает создать комнату, войти по коду или играть одному. Для сетевой комнаты
используется одноразовый билет AdaEngine Cloud и `CloudWebSocketTransport`;
одиночной игре Cloud-аккаунт, билет и relay не требуются. Билеты передаются
локальному серверу редактора в памяти процесса и не входят в экспорт.

Стандартные WGSL и BridgeJS могут переиспользоваться из проверенного кэша при
совпадении хешей исходных GLSL, BridgeJS skeleton и JavaScriptKit runtime.
При изменении этих входов экспортер запускает обычную генерацию с Tint.

Проверка 2026-09-23: полный `export-web` и запуск сцены в браузере прошли;
Counter запустился без Cloud и обработал нажатие. Два браузерных клиента
подключились через локальный mock relay, Peer увидел обоих игроков. Живой
AdaEngine Cloud и выпуск готового шаблона в составе приложения редактора
отдельно не проверены.

## Решение

Swift-код движка и AdaScript VM собираются в `AdaWebPlayer.wasm` при выпуске
шаблона. Проект пользователя не входит в эту сборку. Player читает
`/game/project.json` и перечисленные там `.ada`-файлы из виртуальной файловой
системы WASI. JavaScript-загрузчик заполняет её по `ada-resource-manifest.json`.

`AdaWebPlayerBundle.assemble(template:project:output:)` использует Foundation
и не запускает SwiftPM, shell, компиляторы или сетевые запросы. Этот код можно
вызвать из редактора на iPad. `AdaWebPlayerPackager` — настольная CLI-обёртка
для проверки того же пути до интеграции экспорта в UI.

В ZIP должны входить `index.html` в корне и все файлы результата. Node.js и
Vite для запуска опубликованной игры не нужны. Исходники AdaScript доступны
получателю архива; переносимость байткода между архитектурами не предполагается.

## Воспроизведение

Из корня AdaEngine, со Swift 6.3.2 и соответствующим WASM SDK:

Нужен Tint **со включённым SPIR-V reader**, путь можно передать через
`TINT_EXECUTABLE`. Проверенный бинарник — `libexec/arm64-macos/tint` из
официального `bob.jar` Defold 1.13.1. Tint из macOS-релиза Dawn
`v20260911.162847` собран без SPIR-V reader и для этого пути не подходит.

```sh
ADAENGINE_WEB_EXPORT=1 swift package --disable-sandbox \
  --scratch-path /tmp/ada-web-player-host \
  --allow-writing-to-package-directory --allow-network-connections all \
  export-web --product AdaWebPlayer \
  --output dist/web-player-template \
  --scratch-path /tmp/ada-web-player-wasm \
  --swift-sdk swift-6.3.2-RELEASE_wasm

swift run --scratch-path /tmp/ada-web-player-packager AdaWebPlayerPackager \
  dist/web-player-template Demos/WebPlayer/Counter dist/pocket-counter

cd dist/pocket-counter
zip -r ../pocket-counter-itch.zip .
python3 -m http.server 8765 --bind 127.0.0.1
```

Внешнему SwiftPM и вложенной WASM-сборке необходимы **разные** scratch-каталоги:
иначе дочерний процесс ждёт блокировку, удерживаемую родителем.
Упаковщик требует новый каталог назначения и не заменяет предыдущий экспорт.

## Контракт первой версии

```json
{
  "schemaVersion": 1,
  "runtimeAPI": 1,
  "title": "My Game",
  "entryView": "MyView",
  "sources": ["Sources/Main.ada"]
}
```

Шаблон содержит `ada-web-player.json` с `runtimeAPI: 1` и `profile: "views"`.
В первой версии работают source-backed `@view`, состояние и действия AdaUI.
Упаковка проверяет существование entry view, пути, коллизии имён и версию API.
Полная компиляция/проверка AdaScript выполняется VM при запуске игры.

ECS-системы и схемы нативных компонентов/ресурсов отклоняются явно. Это ещё не
экспорт произвольного проекта AdaEditor: сцены редактора, input actions,
ScriptableObject, игровые ассеты и пользовательские шейдеры нужно перенести
в общий runtime следующего профиля. Кнопка экспорта, архивирование и сохранение
в «Файлы» внутри iPad-приложения пока не подключены.

## WASI-совместимость

- `Compatibility/AdaScriptWASI.h` подключает `sys/time.h` для таймера VM и
  предоставляет пустую реализацию `umask`: у WASI нет process file-creation
  mask, права определяет host. Header действует только при `__wasi__`.
- HarfBuzz собирается с `HB_NO_MT` только для WASI: этот профиль использует
  однопоточный event loop, и его libc++ не предоставляет `std::mutex`.
- В изолированном checkout web-сборки применяются два временных исправления
  зависимостей: переносимый расчёт decimal precision в Yams и UInt8-буферы
  Foundation в AdaScript VM. Общие `.build/checkouts` не редактируются.
  Эти исправления следует перенести в upstream и затем удалить из экспортера.
- WASM использует reactor ABI, а браузерный рендерер требует WebGPU.

## Критерий проверки

Открыть результат по HTTP, увидеть AdaScript-интерфейс и изменить счётчик
кнопкой. Затем изменить внешний `.ada`, повторить только упаковку и убедиться,
что новый интерфейс запускается с тем же SHA-256 `AdaWebPlayer.wasm`.
Отдельные этапы: запуск в iframe; проверка настоящего Safari на iPad;
загрузка и запуск на itch.io. Ни сборка, ни локальный HTTP не заменяют
эти проверки.

Фокусные тесты: `AdaScriptCompilerCoreTests/AdaWebPlayerTests.swift`.
Они проверяют реальные каталоги и выходные файлы; фиктивные bytes шаблона
используются только для проверки упаковки, не как доказательство запуска WASM.

## Проверка прототипа 2026-09-12

- SwiftPM release-сборка `AdaWebPlayer` в WASM прошла; reactor ABI проверен.
- 5 Swift Testing тестов упаковки прошли (параметризованный тест путей — 4 случая).
  Запускались реальные исходники CompilerCore и тесты через минимальный отдельный
  SwiftPM harness; полный набор тестов движка/редактора не запускался.
- В браузере Codex на macOS отрисовался внешний `PocketCounter`; кнопка меняет
  `@state` и выводит новое значение. То же проверено внутри локального same-origin
  iframe. Это не проверка хостинга itch.io или Safari на физическом iPad.
- Изменены подпись и фон только в `.ada`, выполнена только перепаковка.
  Новый интерфейс появился, SHA-256 WASM остался прежним:
  `24979988a775e711b386a3b2eb02695f1d3a3d492462614f8a4a19022aeb27ed`.
- Выявлены и исправлены несовпадение `/tmp` и `/private/tmp` в WASI-монтах,
  потеря подкаталога в URL сгенерированных WGSL и принятие 404-ответа за ресурс.
  Упаковщик проверяет наличие файлов манифеста; Web Player export прекращается
  при ошибке конвертации шейдеров.
- У стандартного AudioPlugin в браузере остаётся `engineInitializationFailed`;
  звук в этом прототипе не поддерживается.

Артефакты находятся в `dist/web-player-prototype-20260912`: шаблон, комплект
игры, ZIP, точные размеры и SHA-256 в `validation.json`, lock-файл зависимостей
сборки. Root `Package.resolved` после проверки восстановлен.
