# Atmosphere

Give a 3D camera a physically based sky. The atmosphere scatters the sun's light
the way air does, so the sky turns from blue at noon to orange near the horizon
and dark at night, the sun appears as a disc that the air reddens, and distant
geometry fades into haze.

The atmosphere is part of a camera's `Environment3D` and is off by default. A
camera that leaves it off draws and stores nothing for it, and its image is
unchanged. The engine still compiles the four small table shaders once at startup
and keeps a few small constant buffers, whether or not any camera uses them.

## Turn It On

The sky is driven by the scene's primary directional light, so a scene needs a
`DirectionalLightComponent` as well as the camera setting. A directional light
shines along its local +Z axis. Rotating the light about X therefore moves the
sun through the sky: with the rotation below the sun sits 10 degrees above the
horizon.

```swift
let camera = Camera(renderTarget: target)   // the texture or window the camera draws to

var environment = Environment3D()
environment.atmosphere = Atmosphere3D(isEnabled: true)

app.main.spawn(
    "Camera",
    bundle: Camera3D(camera: camera, transform: Transform(position: [0, 2, 0]), environment: environment)
)

app.main.spawn("Sun") {
    DirectionalLightComponent(radiance: [1, 0.95, 0.85], intensity: 3, castShadows: true)
    Transform(rotation: Quat(axis: Vector3(1, 0, 0), angle: .pi - 0.17))
}
```

`Core3DPlugin` must be installed, as it is for any 3D rendering. Change the light's
rotation at run time to move the sun; the sky follows on the next frame. With no
directional light the atmosphere uses `fallbackSunDirection` with a white sun of
strength 1.

You can also switch it from scripts and tools through the flat accessors
`Environment3D.atmosphereEnabled` and `Environment3D.atmosphereIntensity`.

## What You See

- **Sky.** An enabled atmosphere replaces the gradient and the equirectangular
  sky texture as the visible sky, whatever the `skybox` settings say.
- **Sun disc.** Drawn analytically at the sun's direction, reddened by the air in
  front of it and slightly darker toward its edge. `sunDiscScale` sets its size
  (`0` hides it) and `sunDiscIntensity` its brightness. The disc is 100 times as
  bright as the sun's illuminance before `sunDiscIntensity` scales it, so lower the
  value if bloom is too strong.
- **Stars.** If the skybox starfield is enabled, stars begin to fade in when the sun
  is about 6 degrees above the horizon, are fully visible once it is about 9 degrees
  below it, and are dimmed by the air in front of them.
- **Aerial perspective.** Geometry gains the light scattered along the view ray, so
  far objects turn hazy and bluish, and the light of the surface itself is dimmed
  and reddened per color channel. `aerialPerspectiveScale` sets how strong the
  haze is (`0` removes it) and `aerialPerspectiveMaxDistance` how far, in meters,
  the effect is computed. Haze is applied before height fog.
- **Reflections.** Surfaces without image-based lighting reflect the sky. The
  reflection is blurred by roughness, so a rough metal sphere shows a soft sky and
  a smooth one shows the horizon. The sun disc is left out of reflections;
  the light's own specular highlight covers it.

## Settings

| Setting | Meaning | Default |
| --- | --- | --- |
| `isEnabled` | Turns the atmosphere on. | `false` |
| `intensity` | Multiplies the sun's light in the atmosphere. | `1` |
| `rayleighScale`, `mieScale`, `ozoneScale` | Thickness of molecules, haze and the ozone layer. Larger `mieScale` gives a hazier sky. | `1` |
| `mieAnisotropy` | How strongly haze scatters toward the sun (`-0.99` to `0.99`). | `0.8` |
| `groundAlbedo` | Reflectivity of the planet below the horizon. | `0.3` |
| `groundRadiusMeters`, `atmosphereHeightMeters` | Planet radius and atmosphere thickness. | Earth: 6,360,000 and 100,000 |
| `sunDiscScale`, `sunDiscIntensity` | Size and brightness of the sun disc. | `1` |
| `aerialPerspectiveScale`, `aerialPerspectiveMaxDistance` | Haze strength and range. | `1`, 32,000 m |
| `tintsSunLight` | Also dims and reddens the directional light itself. See below. | `false` |
| `fallbackSunDirection` | Direction toward the sun when no directional light exists. | up, slightly forward |
| `quality` | Cost tier. See below. | Platform default |

Values outside their valid range are clamped, and non-finite values fall back to
the defaults, so a bad setting never produces a broken image. Scenes saved before
the atmosphere existed load with it off.

The world is Y-up and the ground is at height 0, so a camera's height above the
ground is its Y position. Heights below zero count as zero.

## Tint the Sun's Light

By default the atmosphere changes only what you see; the directional light keeps the
color and strength you gave it, so existing lighting and exposure setups do not
change. Set `tintsSunLight` to `true` to apply the sun's transmittance to the light
as well. A low sun then lights the scene dimmer and redder, and the light goes out
once the planet blocks the sun. This needs a directional light; the fallback sun is
never tinted. The tint is computed per camera from the camera's height and the sun's
direction, and it applies to the main lighting pass. Volumetric fog light shafts and
the fog's sun glow keep using the untinted light.

## Quality

`quality` chooses the table sizes and how many steps each table uses.

| Tier | Use | Sky table | Haze slices | GPU memory per camera |
| --- | --- | --- | --- | --- |
| `low` | Default in the browser. Fewest steps and smallest tables. | 96 by 54 | 8 of 16 by 16 | 112.5 KiB |
| `medium` | Default on desktop. | 192 by 108 | 16 of 32 by 32 | 554.0 KiB |
| `high` | Smoothest gradients near the horizon and in the sunset sky. | 256 by 144 | 24 of 32 by 32 | 808.0 KiB |

Changing a camera's tier replaces its tables on the next frame.

**Cost.** On one desktop Vulkan machine, a 1920 by 1080 scene of 400 spheres with
sun shadows and eight local lights took about 5.5 ms per frame without the
atmosphere. Turning it on added roughly 0.6 to 1.0 ms with a still camera, and the
three tiers differed by less than the run-to-run noise (about 0.3 ms), so most of
the cost is the composite and the reflection blur, not the tables. These figures are
wall-clock frame times with serialized passes, not GPU timestamps, which SAGA does
not provide. They are a guide, not a guarantee: the design's targets of under
0.5 ms for `medium` and under 0.3 ms for `low` have not been met. Run the repository's benchmark
(`ADAENGINE_PERF=1 swift test -c release --filter Render3DGPUTests/Benchmarks`) on
your own hardware for numbers you can trust. A camera that does not move under a
still sun redraws no tables at all, and a camera that only turns skips the sky table.

The tables for the sky's color and the light that reaches the ground are rebuilt
only when you change the medium (the scales, the albedo, the planet size or the
tier). Moving the sun or the camera updates only the per-frame sky and haze tables.
A camera holds that memory only while the atmosphere is on, and nothing when it is
off or a full-screen debug view is showing. The profiling report,
`Render3DPerformanceMetrics.report()`, lists the total.

## Clouds

The atmosphere can carry one layer of procedural clouds. The clouds are lit by the sun and the sky of the same
atmosphere, so they turn pink at sunset and grey under an overcast sky, and distant ones fade into the haze. Clouds are
part of the atmosphere, so they are ignored while the atmosphere is off.

```swift
var environment = Environment3D()
environment.atmosphere = Atmosphere3D(isEnabled: true)
environment.atmosphere.clouds = VolumetricClouds3D(isEnabled: true, coverage: 0.6, windSpeed: 12)
```

Flat accessors `Environment3D.cloudsEnabled` and `Environment3D.cloudCoverage` reach the same settings from scripts and
tools.

| Setting | Meaning | Default |
| --- | --- | --- |
| `isEnabled` | Turns the cloud layer on. | `false` |
| `coverage` | Fraction of the sky the layer covers, from `0` (clear) to `1` (overcast). | `0.5` |
| `density` | How opaque the cloud material is. | `1` |
| `cloudType` | Shape, from `0` (flat stratus) to `1` (tall cumulus). | `0.5` |
| `baseAltitudeMeters`, `thicknessMeters` | Where the layer sits above the ground and how thick it is. | 1,500 m and 2,500 m |
| `windDirection`, `windSpeed` | Direction (X and Z) and speed in meters per second the layer drifts. | east, 10 m/s |
| `detailScale` | Scale of the fine erosion on the edges. | `1` |
| `lightingScale`, `ambientScale` | Multipliers of the sun's light and the sky's light on the clouds. | `1` |
| `time` | Seconds that position the layer. `nil` follows the engine clock. | `nil` |
| `seed` | Seeds the noise, so the same seed always gives the same clouds. | `1` |
| `quality` | Cost tier. See below. | Platform default |

Out-of-range and non-finite values are clamped, and scenes saved before clouds existed load with them off. Clouds appear
only where they change the image: a coverage or density of `0` draws and stores nothing.

**Deterministic frames.** The layer drifts with `windDirection * windSpeed * time`. Pin `time` to a value to freeze the
clouds, for example in screenshots and golden-frame tests; leave it `nil` to animate them with the engine clock.

**Quality tiers.**

| Tier | What it does | Default on |
| --- | --- | --- |
| `low` | No raymarch: one shaded 2D layer with the same noise, coverage and wind, at 40% of the width and height. | Browser |
| `medium` | Raymarched volume with 32 view and 4 light steps at a quarter of the pixels. | Desktop |
| `high` | Raymarched volume with 64 view and 6 light steps at half of the pixels. | Opt-in |

**Cost.** The same benchmark (a 1920 by 1080 scene of 400 spheres, sun shadows and eight local lights, on one desktop
Vulkan machine, best of six rounds, wall-clock with serialized passes) measured the clouds on top of the `medium`
atmosphere. During that run the frame without any atmosphere took 9.2 ms, and the `medium` atmosphere added 1.0 ms, so
this run was slower overall than the one quoted above. The clouds added about 1.6 ms (`low`), 2.6 ms (`medium`) and
4.3 ms (`high`) on top of that. These are clearly above the design's targets of under 0.3 ms for `low` and under 1.0 ms
for `medium`, so the clouds are expensive today: use `low` where frame time is tight, and keep clouds off for cameras
that do not need them. The numbers carry about 0.3 ms of noise, and the run-to-run drift of the baseline shows that other
load on the machine matters, so measure on your own hardware.

A camera with clouds holds the cloud targets (four textures) and a small noise cache for as long as clouds draw. When they
are off, the targets are released a few frames later, once no frame in flight can still read them. The noise is generated on
the GPU the first time a seed is used and shared by every camera (about 1.4 MiB per seed); up to four seeds are kept. `Render3DPerformanceMetrics.report()` lists the cloud memory.

**How the clouds are drawn.** Each frame the raymarch writes the clouds at reduced resolution with a different sample
offset, and a resolve pass blends the result with the previous frame (reprojected with the camera's motion and clamped to
the neighbouring colors) so the clouds are smooth without trails. A camera that jumps far (more than 3 km) or turns
sharply (more than about 70 degrees in a frame), and a change of tier or size, restart the blend, and that first frame can
look grainy. Changing the look (coverage, density, type, seed, wind) does not restart it: the clouds blend toward the new
look over a few frames.

**Limits.** Clouds are drawn over sky pixels only: they never cover geometry, and geometry that is farther away than a
cloud is not hidden by it either. They do not appear in reflections, do not cast shadows on the ground, and are not verified
with path-traced cameras. The cloud layer is one slab and the camera can be below, inside or above it. A ray that points at
the ground shows only the clouds in front of the ground, so from below the layer you see clouds only above the horizon,
while from inside or above it you also see the layer's top and sides below the horizon. Looking at the layer from above or
from far away, the farthest clouds fade into the haze. There are no multiple layers.

## Combine With Other Effects

- **Fog.** Height and distance fog still apply on top of the haze.
- **Image-based lighting.** If a camera has an image-based lighting asset, the
  material lighting pass still uses it for ambient light and its reflections. The
  composite pass, which draws the visible sky and the sky reflected by surfaces that
  have no such asset, uses the atmosphere. Lighting surfaces from the sky itself
  is not available yet.
- **Exposure and brightness.** The sky is high-dynamic-range light that scales with
  the directional light's `intensity` and with the atmosphere's `intensity`. It is
  usually brighter than the old gradient, so with auto exposure on the whole frame
  darkens to compensate. If the sky looks washed out, lower the light's intensity or
  the exposure rather than the atmosphere's scales.
- **Path tracing.** The atmosphere has not been verified with path-traced cameras,
  and the tables are still built for them whether or not the path tracer uses the
  sky. Leave the atmosphere off on those cameras.
- **`AtmosphereMaterial`.** That material is a separate planet-shell effect for
  space scenes. It does not use these settings.

## Limits

- The camera stays inside the atmosphere; planetary views from space are not a goal.
- The ground below the horizon is a lit planet surface, so over an empty world the
  horizon is a clear edge. Cover the ground with geometry or fog to soften it.
- Terrain and objects do not shadow the haze, and clouds do not shadow anything.
- Haze is computed from the camera's point of view for 8, 16 or 24 distance
  slices, depending on the tier. Very large `aerialPerspectiveMaxDistance` values
  spread those slices thinly.
- The shaders are shared by every SAGA backend, but this feature was checked only on
  the Vulkan backend. Metal and browser results have not been verified, and their
  golden-frame references are not recorded yet.
