# Animation Principles for Pixel Art

The 12 principles of animation applied to pixel art constraints.
Adapted from the `pixel-art` agent skill by ervareza (MIT, see NOTICE.md).

## 1. Squash & Stretch

The most important principle. Shows weight and flexibility.

```
Idle:     Jump prep:    Airborne:    Landing:
 ·##·      ·##·          ·#·          ·####·
 ·##·      ####          ·##·         ·####·
 ·##·      ####          ·##·         ··##··
 ·##·      ····          ·#·
```

**Pixel art rule:** Preserve total pixel area. If you compress 1px vertically, expand 1px horizontally.

At small scales (16×16), squash/stretch is just ±1px. That's enough.

## 2. Anticipation

A small preparatory motion before the main action.

- **Jump:** Crouch 1–2 frames before launching
- **Attack:** Wind-up frame (arm pulled back) before the strike
- **Run:** Lean forward slightly before accelerating

```
Anticipation frame count:
  16×16 sprites: 1 frame of anticipation
  32×32 sprites: 1–2 frames
  64×64 sprites: 2–3 frames
```

## 3. Staging

Direct the viewer's eye to the important action.

- Use **color contrast** — action elements should be the brightest colors
- Use **motion isolation** — only the acting part moves, background stays still
- Use **clear silhouettes** — every pose should read clearly as a filled silhouette

## 4. Straight Ahead vs. Pose to Pose

**For pixel art, ALWAYS use Pose to Pose:**
1. Draw the key poses first (idle, apex of jump, contact frame of walk)
2. Fill in-between frames after
3. At 4–6 frames per animation, every frame IS a key pose

## 5. Follow-Through & Overlapping Action

Different body parts move at different speeds.

```
Walk cycle follow-through:
  Frame 1: Body steps forward, hair trails behind
  Frame 2: Body plants foot, hair catches up
  Frame 3: Body shifts weight, hair overshoots
```

At 16×16, "follow-through" is just shifting the hair/cape/tail pixels 1 frame late. Layers help: keep the trailing part on its own layer and shift it per frame.

## 6. Slow In, Slow Out (Easing)

More frames at the start and end of a motion, fewer in the middle.

For a 6-frame jump:
```
Frame 1: Ground (slow out — ease out)
Frame 2: Leaving ground (getting faster)
Frame 3: Mid-air (fastest — fewest changes between frames)
Frame 4: Apex (slow in — ease in)
Frame 5: Falling (getting faster)
Frame 6: Landing (slow out — ease out)
```

In pixel art, "easing" means: key positions change by 1px at start/end, 2–3px in the middle. Vary `frameDuration` per frame for the same effect without extra frames.

## 7. Arcs

All natural motion follows arcs, never straight lines.

- Arms swing in arcs, not straight up/down
- Jumps follow parabolic arcs
- Thrown objects arc through the air
- Head bobs in a subtle figure-8 during walk cycles

## 8. Secondary Action

Supporting actions that enhance the main action without dominating.

- **Walking:** Main action = legs, Secondary = arms swinging, head bobbing
- **Attacking:** Main action = weapon swing, Secondary = body recoil, hair whip
- **Idle:** Main action = breathing (body 1px up/down), Secondary = blinking (every 3–4 seconds)

## 9. Timing

Frame count determines weight and mood.

| Action | Light/Fast | Normal | Heavy/Slow |
|---|---|---|---|
| Walk cycle | 4 frames | 6 frames | 8 frames |
| Attack | 3 frames | 4 frames | 6 frames |
| Jump | 3 frames | 5 frames | 7 frames |
| Death | 4 frames | 6 frames | 8 frames |

**Pixel art FPS:** Most pixel art games run animations at 8–12 FPS, not 24 or 60.

## 10. Exaggeration

Push poses further than realistic. This is critical at low resolution.

- A punch should extend the arm 2–3px past natural length
- A surprised face should have eyes 1px larger than normal
- A heavy landing should squash the character 2–3px

**At 16×16, subtlety is invisible.** Exaggerate or it won't read.

## 11. Solid Drawing (Solid Form)

Every frame should feel like a 3D object, not a flat cutout.

- Maintain consistent volume across all frames
- Light source stays consistent (typically top-right in pixel art)
- Shadows and highlights follow the form, not the outline

## 12. Appeal

Characters should be interesting to look at, even as tiny pixel sprites.

- **Readable silhouette:** Test every pose as a solid black fill. Can you tell what's happening?
- **Distinctive shape:** Hero = broad shoulders, Mage = tall hat, Slime = round blob
- **Color identity:** Each character should have a unique color accent
- **Personality in idle:** The 2–4 frame idle animation tells the player WHO this character is
