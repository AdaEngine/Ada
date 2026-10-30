# 3D particles: smoke, rain and snow

Add `ParticleEmitter3D` and `Transform` to an entity in a scene using `Model3DPlugin`
and `Core3DPlugin` (included in the `game3d` preset). Studio exposes the component
through its normal reflected inspector. No image asset is required.

The emitter simulates in world space at 120 Hz, with a maximum of 4096 particles
per emitter and 65,536 submitted samples per scene. The renderer sorts particles
back to front for each camera and draws instanced billboards in HDR before fog and
tone mapping. It samples opaque scene depth for occlusion and soft intersections;
particles do not write depth. Each camera owns a separate ring of GPU buffers.

```json
"AdaScene.ParticleEmitter3D": {
  "emissionRate": 20,
  "maxParticles": 160,
  "lifetime": 5,
  "initialVelocity": [0, 0.65, 0],
  "wind": [0.45, 0, 0.1],
  "initialSize": 0.3,
  "expansionRate": 0.45,
  "opacity": 0.45
}
```

Velocities and sizes use metres and seconds. `initialVelocity` is rotated by the
emitter transform. `acceleration` and `wind` use world axes. `drag` controls the
exponential approach to the wind; `turbulence` adds smooth individual eddies.
Particles expand and fade over their lifetime. Moving the source does not drag
already emitted smoke along with it.

Set `isEmitting = false` to stop continuous spawning and let existing smoke expire.
`isPaused` freezes simulation. Increment `restartCount` to clear and replay an
effect; increment `burstRequest` to add `burstCount` particles while retaining
previous puffs. This works with continuous emission disabled and is suitable for
gunfire. Emission, bursts and integration remain bounded after frame stalls.

This is a particle effect, not a fluid solver. Smoke does not collide with or flow
around obstacles, cast volumetric shadows, or occlude transparent surfaces. The
initial renderer uses procedural soft billboards rather than user textures.

For precipitation, set `particleStyle` to `1` (rain) or `2` (snow). Style `0`
retains the existing smoke appearance. A nonzero `spawnBoxHalfExtents` selects
a uniformly filled box; it creates particles close to the viewer as well as in
the distance. The source can follow the camera while emitted particles remain
in world space. Use a negative Y velocity for falling weather.

Rain streaks align with projected particle velocity. `initialSize` is streak
length and `aspectRatio` is width/length; looking along the fall direction
foreshortens length while retaining width. Snow uses soft round flakes. Weather
styles retain density through their lifetime rather than using smoke's long fade.

For gunfire and dense clouds, `particleStyle = 3` selects layered, locally lit
smoke. Three procedural density layers integrate an approximate transmittance;
per-puff size variation breaks repeated silhouettes. This reuses the same bounded
instanced draw and particle storage as style 0. It changes shader work, not the
number of simulated particles. Style 0 and precipitation retain their appearance.

Lit smoke receives the primary directional light and the eight strongest visible
local lights selected by the existing light pass. Point and spot lights use range,
inverse-square and cone falloff; local shadow visibility comes from the same-frame
bounded opaque shadow atlas. A wall can therefore block a flashlight or muzzle
light before it reaches a cloud. Expired lights are excluded immediately. This
does not provide light multiple-scattering, sun shadowing inside smoke, fluid
advection or volumetric self-shadowing. Billboards remain an approximation when
viewed from different angles. Weather and legacy smoke stay unlit.

Particles attenuate the opaque indirect-light and reflection-response targets
with their alpha coverage, keeping later SSR/IBL compositing behind the cloud.
The HDR scene starts with transparent black; empty opaque-GBuffer pixels retain
the particle's premultiplied foreground over the sky in the environment composite.
Smoke therefore also remains visible outdoors with no opaque surface behind it.
Per-view frame-buffered light packets contain at most eight lights and share
shadow projections; no CPU light evaluation runs per particle. The simulation
also computes the exponential drag coefficient once per fixed step per emitter.

`collisionPlaneEnabled` and `collisionPlaneHeight` remove particles below an
authored horizontal ground plane. This is not arbitrary mesh collision. The
depth buffer still occludes precipitation behind scene geometry. Surface water,
snow accumulation and impact ripples are separate game/material responsibilities.

`Environment3D.rainLensAmount` (`0...1`) enables refracting water beads after
depth of field and before overlays/UI, independently of the optical profile.
Drive `rainLensTime` with a gameplay clock to freeze beads on pause. Both default
to zero, preserving the image of old scenes.

`Particle3DTests` covers determinism, capacity, world-space drift, lifetime and
pause behavior. `Render3DGPUTests/Particles` checks actual GPU visibility in front
of geometry, occlusion behind it, hiding the emitter, local-light response and
blocking that light with an opaque shadow caster. `ParticleLighting3DTests` checks
the bounded packed GPU layout and disabling stale/missing shadow state. Run the WebGPU checks
through `script/validate_webgpu.sh`.
