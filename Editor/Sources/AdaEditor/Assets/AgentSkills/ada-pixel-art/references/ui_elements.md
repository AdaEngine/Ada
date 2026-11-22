# UI Elements in Pixel Art

Guide for creating pixel art user interface components: health bars, buttons, dialog boxes, inventory, and 9-slice panels.
Adapted from the `pixel-art` agent skill by ervareza (MIT, see NOTICE.md).

## 9-Slice / 9-Patch Panels

The 9-slice technique lets you scale a panel to any size without distorting corners.

```
┌───┬─────────┬───┐
│ 1 │    2    │ 3 │  Corners (1,3,7,9): never stretch
├───┼─────────┼───┤  Edges (2,8): tile horizontally
│   │         │   │  Edges (4,6): tile vertically
│ 4 │    5    │ 6 │  Center (5): tile both directions
│   │         │   │
├───┼─────────┼───┤
│ 7 │    8    │ 9 │
└───┴─────────┴───┘
```

**Corner size:** Typically 3–4px for 16px-scale UI, 6–8px for 32px-scale.

**Common styles:**
- **RPG dialog:** Dark background, light 1px border, slight inner shadow (1px darker row at top)
- **Fantasy panel:** Ornate corners with decorative pixels, gold border
- **Sci-fi HUD:** Thin bright-colored borders on dark, no rounded corners
- **Minimalist:** 1px border, flat fill, no decoration

## Health / Status Bars

```
┌──────────────────┐
│██████████░░░░░░░░│  Simple bar: filled portion + empty portion
└──────────────────┘

┌──────────────────┐
│▓▓▓▓▓▓▓▓▓▓░░░░░░░│  Detailed bar: highlight row on top, shadow on bottom
│██████████░░░░░░░░│
│▒▒▒▒▒▒▒▒▒▒░░░░░░░│
└──────────────────┘
```

**Sizes:**
- Minimal: 1px tall, no border (above character head)
- Standard: 3–5px tall with 1px border
- Detailed: 6–8px tall with highlight/shadow rows

**Colors by type:**
| Bar Type | Filled | Empty | Border |
|---|---|---|---|
| Health | Green → Yellow → Red (dynamic) | Dark gray | Black |
| Mana | Blue / Purple | Dark gray | Black |
| Stamina | Yellow / Orange | Dark gray | Black |
| XP | Cyan / White | Dark navy | Black |

**Dynamic color:** Change health bar color based on percentage: >60% green, 30–60% yellow, <30% red.

## Buttons

**States:** Normal → Hover → Pressed → Disabled

```
Normal:    ┌──────┐    Pressed:   ┌──────┐
           │ TEXT │               │ TEXT │  (shift content 1px down+right)
           └──────┘               ──────┘  (remove top-left highlight)
```

**Key rules:**
- Button text shifts 1px down and 1px right when pressed
- Hover: brighten border or add highlight pixel on top-left corner
- Disabled: desaturate colors, remove highlight, gray out text

## Inventory Slots

```
Standard grid:     With item:        Selected:
┌────┐             ┌────┐            ┌────┐
│    │             │ ⚔  │            │ ⚔  │ ← bright border
│    │             │    │            │    │
└────┘             └────┘            └────┘
```

**Slot sizes:** 16×16 (with 1px border = 14×14 usable), 24×24, 32×32
**Stack count:** Small number (2–3 digit) in bottom-right corner, outlined for readability

## Dialog Boxes

```
┌─── Speaker Name ───────────────────┐
│                                     │
│  Dialog text goes here. Keep line   │
│  width under 30 characters for      │
│  readability at low resolution.     │
│                                     │
│                          ▼ [Next]   │
└─────────────────────────────────────┘
```

**Typography:** Use a pixel font at 1× scale. Never anti-alias text in pixel art UI.
**Text speed:** Reveal 1 character per 30–50ms for typewriter effect.
**Indicator:** Small animated arrow (▼) bouncing 1px up/down to indicate "press to continue".

## Cursor / Pointer

```
#·      ←  2-color cursor: outline + fill
##·        Size: 5×7 to 8×12 pixels
#·#·       Must have 1px dark outline for visibility
·##·       on any background color
 ·#·
  ··
```

**Animation:** Idle cursor should have subtle 2-frame animation (slight bounce or sparkle) to feel alive.
