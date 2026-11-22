# Particle Effects in Pixel Art

Guide for creating pixel art particle VFX: explosions, smoke, fire, sparkles, and magic effects.
Adapted from the `pixel-art` agent skill by ervareza (MIT, see NOTICE.md).

## Core Principle

Particle effects in pixel art are NOT random noise. Each particle is a deliberate sprite with intentional placement. Think of it as choreographed animation, not simulation.

## Common Particle Types

### Explosion
- **Frames:** 5–8
- **Sequence:** Flash (white/yellow) → Fireball (orange/red) → Smoke (gray) → Dissipate
- **Shape progression:** Small circle → Large circle → Irregular blobs → Scattered pixels → Nothing
- **Key rule:** The flash frame is 1–2 frames MAX. If the flash lingers, it loses impact.

```
Frame 1:   ··      Frame 3:  ·##·    Frame 5:   ·#·
           ·#·                ####               ·##
           ··                 ####                ·#
                              ·##·
```

### Smoke / Dust
- **Frames:** 4–6
- **Sequence:** Small cluster → Expand upward → Spread and fade → Vanish
- **Color:** 2–3 grays from your palette (dark → medium → light)
- **Movement:** Always drift upward. Add slight horizontal wobble.
- **Key rule:** Never move in straight lines. Offset by ±1px per frame.

### Fire / Flame
- **Frames:** 3–4 (looping)
- **Sequence:** Cycle through flame shapes. Never repeat the exact same frame.
- **Color ramp:** White core → Yellow → Orange → Red → Dark red → Transparent
- **Shape:** Narrow at base, wider in middle, pointed and flickering at top
- **Key rule:** Fire is NEVER symmetrical. Make each frame asymmetric.

### Sparkle / Glint
- **Frames:** 3–5
- **Sequence:** Nothing → Small cross → Full star → Small cross → Nothing
- **Shape:** 4-way or 8-way star/cross pattern
- **Color:** White or lightest palette color
- **Key rule:** Sparkles should be tiny (3×3 to 5×5 max). Oversized sparkles look wrong.

```
Frame 1:  ···    Frame 2:  ·#·    Frame 3:  ·#·
          ·#·              ###               #·#
          ···              ·#·               ·#·
```

### Magic / Energy
- **Frames:** 4–8
- **Sequence:** Coalesce from scattered pixels → Form shape → Release → Scatter
- **Color:** Use accent colors from palette (purples, cyans, bright blues)
- **Shape:** Circular orbits, spiraling inward or outward
- **Key rule:** Shift highlight pixels by 1px per frame to create smooth glow motion.

## Particle Spawn Patterns

| Pattern | Use Case | Description |
|---|---|---|
| Radial burst | Explosions | All particles move outward from center |
| Fountain | Sparks, blood | Particles arc upward then fall with gravity |
| Trail | Projectiles | Particles spawn behind moving object |
| Ambient | Rain, snow | Particles spawn at top, fall downward |
| Orbital | Magic | Particles orbit around a center point |

## Frame Timing

Set with `sprite.frameDuration`:
- **Explosion:** 50–80ms per frame (fast, punchy)
- **Smoke:** 100–150ms per frame (lazy, drifting)
- **Fire:** 80–120ms per frame (medium, flickering)
- **Sparkle:** 60–100ms per frame (quick pop)
- **Rain/Snow:** 100ms per frame (steady)

## Alpha Rules for Particles

Even in pixel art, particles should follow the zero-AA rule. To create the illusion of fading:
1. Reduce the number of opaque pixels each frame (don't use semi-transparency)
2. Shift colors toward background color in later frames
3. Use dithering between particle color and transparent for "soft" edges
