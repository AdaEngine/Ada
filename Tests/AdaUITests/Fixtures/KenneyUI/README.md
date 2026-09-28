# Текстурное меню AdaUI

`Menu.ui` — UI document fixture для проверки AdaUI resource loading.
Текстуры взяты из Kenney UI Pack 2.0; исходная лицензия CC0 находится в `License.txt`.

## Запуск на macOS

Интерактивный Swift пример находится в AdaExamples.

## UI Designer

Откройте `Menu.ui` из проекта, содержащего эту папку и PNG рядом с файлом.
У Image доступны `capTop`, `capLeading`, `capBottom`, `capTrailing`.
Добавьте к Button модификатор `textureButtonStyle`; задайте относительные пути
`normal`, `highlighted`, `pressed`, `disabled` и четыре поля `cap*`.
Пока пути редактируются как текстовые поля; специального графического инструмента нарезки нет.
После изменения библиотек требуется пересобрать AdaEditor.

## Swift

```swift
let skin = TextureButtonStyle(
    normal: normalImage,
    highlighted: hoverImage,
    pressed: pressedImage,
    disabled: disabledImage,
    capInsets: .init(8)
)
Button(action: startGame) {
    Text("New Game").frame(width: 240, height: 48)
}
.buttonStyle(skin)
```

Для панелей: `panelImage.resizable(capInsets: .init(8))`.
Значения границ задаются в исходных пикселях, соответствующих единицам layout.
Для ассетов Double увеличьте размеры границ с учётом требуемого масштаба.
Слишком большие границы ограничиваются размерами исходника с сохранением центрального пикселя;
отрицательные значения Swift API ограничиваются нулём. В `.ui` неверные значения дают диагностику.
Если целевая область меньше суммы границ, края пропорционально уменьшаются.
Неуказанная текстура состояния заменяется normal; focused использует highlighted.
