# Sprite Conventions

Standard conventions for pixel art sprite sheets.
Adapted from the `pixel-art` agent skill by ervareza (MIT, see NOTICE.md).

## Frame Sizes

| Category | Size | Use Case |
|---|---|---|
| Micro icon | 8×8 | Inventory items, status icons, small pickups |
| Small sprite | 16×16 | Characters, enemies, NPCs in top-down games |
| Standard sprite | 32×32 | Characters with more detail, medium enemies |
| Large sprite | 48×48 | Bosses, detailed characters, isometric units |
| Boss / HD | 64×64 | Boss sprites, splash portraits |
| Portrait | 128×128 | Character portraits, dialog faces |

## Animation Frame Counts

| Animation | Frames | Notes |
|---|---|---|
| Idle | 2–4 | Subtle breathing or blinking |
| Walk | 4–6 | Contact–passing–contact–passing for 4-frame |
| Run | 6–8 | Wider strides, more contact frames |
| Attack | 3–6 | Wind-up, strike, follow-through |
| Jump | 3–5 | Crouch (squash), airborne (stretch), land (squash) |
| Hit/Flinch | 2–3 | Flash, knockback pose |
| Death | 4–6 | Collapse sequence |

Name each range with `sprite.tag(name, from, to)` so importers can play `walk`, `attack` and so on by name.

## Directional Layouts

### 4-Way (Top-down RPG)
Row layout in the sprite sheet:
- Row 0: Down
- Row 1: Left
- Row 2: Right
- Row 3: Up

### 8-Way (Isometric / Action)
- Row 0: South
- Row 1: South-West
- Row 2: West
- Row 3: North-West
- Row 4: North
- Row 5: North-East (mirror South-West)
- Row 6: East (mirror West)
- Row 7: South-East (mirror North-West)

**Optimization:** Draw only 5 directions (S, SW, W, NW, N) and mirror SW→NE, W→E, NW→SE to save texture memory. A strip holds one direction's frames; generate one strip per direction under the same recipe.

## Squash & Stretch

For jump animations, apply squash/stretch to the bounding box:
- **Crouch (squash):** Scale X to 1.1, Scale Y to 0.85
- **Airborne (stretch):** Scale X to 0.9, Scale Y to 1.15
- **Land (squash):** Scale X to 1.15, Scale Y to 0.8

Preserve total pixel area (mass) during deformation.

## Timing

Common frame durations (set with `sprite.frameDuration`):
- Idle: 200–300ms per frame
- Walk: 100–150ms per frame
- Run: 80–100ms per frame
- Attack: 60–100ms per frame
- Hit: 80ms per frame
