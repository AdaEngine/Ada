# CORTAO Bent Normals: Directional Ambient Lighting and Specular Occlusion

Status: Approved by the human on 2026-11-23 (decisions of §10: default on, cone-cone specular occlusion, one change).
Implemented; §12 records where the implementation differs from the text above.

Date: 2026-11-22

Classification: improvement of the existing screen-space ambient occlusion
([RenderingFoundation.md](../RenderingFoundation.md), CORTAO technique). It extends an existing subsystem and adds
no new rendering stage, so it follows the improvement path of the
[contributor workflow](contributor-workflow.md): update the existing design material and ship the user-facing article.

## 1. Problem

CORTAO already traces 16 rays per pixel and knows which of them reach open space. Today that result is collapsed into
one scalar, the occlusion fraction. The direction of the open space is thrown away. The reference implementation
([theagentd/CORTAO](https://github.com/theagentd/CORTAO), MIT) can also output a **bent normal**: the average direction
of the unoccluded rays. The first CORTAO port in AdaEngine does not, because nothing consumed it.

A scalar AO can only darken. It cannot say *where* the remaining light comes from, which causes two visible errors:

| # | Error (verified in code) |
| --- | --- |
| P1 | **Diffuse ambient ignores the open direction.** `screen_space_reflection.wesl` computes `foreground - indirect * (1 - ao)`. The `indirect` buffer was lit with the surface normal in `flat3d.wesl` (`u_Irradiance` sampled along `worldNormal`). A wall pressing against one side of a sphere dims the sphere but keeps the colour of the sky it can no longer see. |
| P2 | **Specular occlusion is the diffuse AO.** The same pass multiplies the traced and probe reflection by `ao` (`response = reflectionResponse * ao`, `reflectivity * ao`). A tight, glossy reflection that points toward open sky is dimmed as much as a rough one that points into a crevice. |

Both are standard weaknesses of scalar AO. Bent normals are the standard remedy, and CORTAO produces the data at almost
no extra cost.

## 2. Decision

1. **Produce a bent normal in the CORTAO main pass** and carry it with the AO value through temporal accumulation and
   the bilateral filter (§4.1 to §4.3).
2. **Consume it in the composite pass** (`screen_space_reflection.wesl`) in two places, both behind one setting:
   diffuse image-based lighting evaluated along the bent normal (§4.4), and specular occlusion from the visibility cone
   and the reflection lobe (§4.5).
3. **Keep everything else unchanged.** SSAO and CORTAO without the setting render exactly as before. Devices that lack
   the resources fall back to the scalar AO.

## 3. Goals and non-goals

| ID | Goal |
| --- | --- |
| G1 | Diffuse ambient colour near an occluder shifts toward the open side, as in a reference render with a bent-normal irradiance lookup. |
| G2 | Glossy reflections toward open space are no longer darkened by occluders behind or beside the surface. |
| G3 | No new render target for the producer, and no extra pass. Cost stays in the composite pass. |
| G4 | The bent normal is stable under camera motion: no flicker and no ghosting beyond what the scalar AO already has. |
| G5 | Disabled, the frame is bit-identical to today's. |

Non-goals:

- Bent normals for SSAO (§8 lists it as a follow-up).
- Occlusion of direct lights, baked lightmaps and irradiance grids. Their visibility is already baked or sampled.
- Directional occlusion of the constant ambient colour. A constant has no direction to bend.
- Replacing the GTAO-style cone assumption with a full spherical-harmonic occlusion model.

## 4. Design

### 4.1 Producer (`cortao_3d.wesl`)

The main pass already has the tangent frame `(T, B, N)` and the 16-bit ray mask `rayBits`. Add:

```
bent = normalize(sum over rays j with bit j clear of rayDirection(j))   // tangent space
bentView = T * bent.x + B * bent.y + N * bent.z                         // view space
```

- The ray directions are the same golden-angle table the occluder table generator uses. Put them in a WGSL `const`
  array. A 16-iteration loop is cheaper than the reference's 65,536-entry look-up table here, because that table would
  need an RG8 texture format the engine lacks and an extra fetch.
- If every ray is blocked the sum is zero. The pass writes `N` (the AO is already at its floor).
- The bent normal is clamped to the upper hemisphere: `dot(bent, N) >= 0.05`. Averaging can otherwise push it below the
  surface at silhouettes.

### 4.2 Storage

The raw target is BGRA8 and holds AO in `r`. Use the free channels:

| Channel | Content |
| --- | --- |
| `r` | AO visibility (unchanged) |
| `g`, `b` | bent normal in view space, octahedral encoded, 8 bits per axis (about 0.7 degrees) |
| `a` | unused (`1`) |

The filtered target `ambientOcclusion3DTexture` uses the same layout. Whether the channels hold a bent normal is not
stored in the texture but decided per frame by the passes that produce and consume it (§12), so SSAO and
bent-normal-free CORTAO keep their grey `rgb` and the existing consumers, which read only `.r`, are unaffected.

The CORTAO history target is RGBA16F and currently stores `(ao, depth)`. It becomes `(ao, depth, octahedral.x,
octahedral.y)`. This is the same format and size.

### 4.3 Temporal accumulation and filtering

- **Reprojection.** A view-space vector rotates with the camera. The temporal pass receives the rotation from the
  previous view space to the current one (the upper-left 3 x 3 of `view_current * inverse(view_previous)`) next to the
  existing reprojection matrix. It decodes the history bent normal, rotates it, blends it with the current one, and
  re-normalises. A zero-length result falls back to the current value.
- **Rejection and clamp.** The existing depth rejection applies to the whole texel. The bent normal is not neighbourhood
  clamped: clamping a direction is not meaningful, and the blend weight (0.1) already limits ghosting.
- **Bilateral filter.** Decode the neighbours, average the vectors with the existing depth and normal weights, then
  re-normalise and re-encode. Averaging the encoded values would be wrong.

### 4.4 Consumer 1: diffuse ambient along the bent normal

In `screen_space_reflection.wesl` the diffuse image-based part of the ambient light is

```
diffuseIBL(n) = diffuseSurface * irradiance(n) / PI * iblIntensity
```

with `diffuseSurface = diffuseWeight * baseColor`. The composite pass already receives `diffuseSurface3DTexture` when
screen-space GI or path tracing is on (`PrepareEnvironment3DTexturesSystem`); the pass reads it as `diffuseImage`. The
change, per pixel with a bent normal:

```
foreground' = foreground - diffuseIBL(n) + diffuseIBL(bent) * ao
```

This replaces the diffuse portion of the `indirect` term. The specular portion keeps the existing `indirect * (1 - ao)`
subtraction until §4.5 replaces it. Details:

- The composite pass needs the IBL irradiance texture (`u_Irradiance` in `flat3d.wesl`) and the world-from-view rotation.
  Both exist in the environment uniform for the reflection code. The new binding is one texture.
- Everything is evaluated in linear HDR, before exposure and tone mapping, like the current AO subtraction.
- With IBL off the ambient is a constant colour. Bent normals have no effect and the current formula runs.
- With baked lightmaps or irradiance grids the diffuse part is already visibility-aware. Skip them. The
  existing `diffuseGI.z` flag marks a baked-lighting view, so the feature is skipped for the whole view in that case.
- `diffuseSurface3DTexture` must exist whenever bent normals are on and IBL is on. Its allocation condition grows by
  that case. It needs the six-attachment device capability (`supportsLightingSurfaceBuffer`). Where that is missing the
  feature is off and the scalar AO is used.

**Assumption to verify in the plan stage:** that `diffuseSurface3DTexture` holds exactly `diffuseWeight * baseColor` for
every material (clearcoat, sheen and transmission scale the ambient later in the main shader). If it does not, the
fallback is to apply the correction as a ratio, `irradiance(bent) / irradiance(n)`, to the diffuse estimate only.

### 4.5 Consumer 2: specular occlusion

Replace the scalar `ao` in the reflection terms (`response`, `reflectivity * ao`, the probe blend) with

```
specularOcclusion = coneConeIntersection(visibilityCone, reflectionLobe)
visibilityCone    = axis bent, half-angle acos(sqrt(1 - (1 - ao)))        // GTAO cone from the AO fraction
reflectionLobe    = axis reflect(view, normal), half-angle from roughness  // narrow when glossy
```

The intersection fraction is the cone-cone overlap of Jimenez et al. 2016 (the paper the CORTAO reference also cites for
its AO normalisation). For a perfectly rough surface the lobe covers the hemisphere and the result approaches the
scalar AO, so rough materials render almost as before. Glossy materials gain the effect. The cone angle for a given
roughness reuses the mapping already in `probeReflection` (the prefilter level chosen by `roughness`). The result is
clamped to `[ao, 1]` so the new term never darkens beyond the old one.

### 4.6 Settings and device support

- `ScreenSpaceAO3D.bentNormals: Bool`, default `true`, decoded with `decodeIfPresent`. It is ignored unless the
  technique is `.cortao`, so SSAO cameras and every existing saved scene render as before. CORTAO is new and opt-in,
  so no existing image changes. A camera that selects CORTAO gets the full effect and can turn it off.
- It takes effect only if the device supports compute passes (already required by CORTAO) and
  `supportsLightingSurfaceBuffer`. Otherwise the camera behaves as before. No error is raised.
- A new debug view `bentNormals` shows the view-space bent normal as colour, next to the existing
  `ambientOcclusion` view (`DebugView3D`, `DebugView3DRenderNode`).

## 5. Alternatives considered

| Option | Why not |
| --- | --- |
| Apply the bent normal in the forward pass (`flat3d.wesl`) | AO is computed after the forward pass from its G-buffer. A forward use would need last frame's AO (lag, disocclusion errors) or an AO prepass over the depth prepass. |
| Store the bent normal in a new RGBA8 target | The raw target has spare channels and a new target would be a third full-screen allocation per view. |
| Use the reference's bent-normal look-up table | It needs an RG8 SNORM texture the engine does not offer, and a 16-iteration loop costs less than the fetch. |
| Spherical-harmonic or ambient-dice visibility | More accurate, but needs per-pixel multi-coefficient storage and an SH irradiance source. Disproportionate for this step. |
| Specular occlusion from the scalar `ao` only (Lagarde) | Keeps G2 unmet: the lobe direction and the open direction are the point of the feature. |

## 6. Acceptance

1. **Rendered comparison.** A sphere beside a wall under a two-colour environment (warm on the open side, cool on the
   wall side): with bent normals on, the sphere's ambient colour near the wall shifts toward the open side by a
   measurable amount relative to the scalar AO render. The AO scalar itself is unchanged.
2. **Specular.** A glossy sphere reflecting open sky near an occluder behind it is brighter than with the scalar AO.
   A fully rough one differs from the scalar AO render by less than a stated tolerance.
3. **Bit-identity when off.** With `bentNormals = false` the golden frames of the existing debug views and of CORTAO match
   the committed references exactly (G5).
4. **Temporal stability.** In a camera-rotation sequence the `bentNormals` debug view shows no flicker (frame-to-frame
   difference below a bound after convergence) and no trail behind a moving occluder beyond the AO's own.
5. **Fallbacks.** A device without `supportsLightingSurfaceBuffer` and an IBL-off scene render the scalar AO result.
6. **Unit tests.** Octahedral encode/decode round trip within tolerance. Settings decode default and round trip.
7. **GPU tests** on Vulkan through the existing 3D GPU suite (`Render3DGPUTests`), run alone as that suite documents,
   plus Metal where available. Unavailable devices are reported as blocked, not passed.

## 7. Cost and risk

- **Cost.** Producer: one 16-step loop and an encode, no new fetches. Temporal: one decode, one rotation, one encode.
  Composite: two irradiance fetches, one diffuse-surface fetch (already bound), and the cone maths, per pixel and only
  where the setting is on. Measure the CORTAO and composite passes with the existing `ssao` and composite metrics before
  and after, on a quiet machine.
- **8-bit precision.** An 8-bit octahedral pair is about 0.7 degrees. That is fine for irradiance, which is smooth, and
  visible only in the debug view. The filtered target could move to RGBA16F if the plan stage finds banding.
- **Diffuse-surface assumption** (§4.4) is the largest technical risk. It is verified first.
- **Visible-surface limits.** Like all screen-space AO, occluders that are hidden or off-screen are missed, so the open
  direction can point toward something that is actually blocked.
- **Moving objects** inherit the scalar AO's depth-reject trails. The bent normal makes them slightly more visible in
  colour, not in brightness.

## 8. Follow-ups, outside this design

- Bent normals for SSAO (the unoccluded sample directions give an estimate).
- Using the bent normal for screen-space GI gather directions.
- Spherical-harmonic visibility if scenes with strong coloured environments show cone-model limits.

## 9. User documentation

Extend the existing "Ambient occlusion: SSAO and CORTAO" section of
[RenderingFoundation.md](../RenderingFoundation.md) with the setting, what it changes, its requirements and fallbacks,
and the new debug view. Add a worked example (camera environment settings) to the relevant Studio camera or rendering guide; the plan stage names the exact guide.

## 10. Decisions

1. **Default: on** when CORTAO is selected. Reasoning: the technique is new and opt-in, so no existing scene changes; the
   data is a by-product of the AO trace; and the references below present bent normals and specular occlusion as
   part of the AO result, not an option. The setting stays so a project can compare or reclaim the cost.
2. **Specular model: cone-cone intersection** (§4.5), chosen by the human. Lagarde's formula stays as the documented
   fallback if the composite pass shows a cost problem.
3. **Scope: one change.** The producer, the temporal and filter support, both consumers, the debug view and the
   documentation ship together.

## 11. References

- J. Jimenez, X. Wu, A. Pesce, A. Jarabo, "Practical Real-Time Strategies for Accurate Indirect Occlusion", SIGGRAPH
  2016 course notes (GTAO). Defines the visibility cone from the AO fraction, bent normals, and the cone-cone
  specular occlusion used in §4.5.
- S. Lagarde, C. de Rousiers, "Moving Frostbite to Physically Based Rendering 3.0", SIGGRAPH 2014. Source of the cheaper
  `saturate(pow(NdotV + ao, exp2(-16 * roughness - 1)) - 1 + ao)` specular occlusion kept as the fallback.
- D. Isheden, CORTAO, <https://github.com/theagentd/CORTAO> (MIT). The bent-normal output and the ray layout this
  design reuses.

## 12. Implementation notes

Where the implementation differs from the design text, and what was verified.

- **Validity flag.** The design proposed `a = 0` for "no bent normal". SSAO and the debug view write `a = 1`, and the AO
  debug view reads `rgb`, so alpha cannot carry it without changing existing images. The AO node records, per view and
  per frame, whether it produced a bent normal (`ScreenQuality3DScratch.bentNormalViews`). The composite pass and the
  debug view read that flag (`diffuseGI.w` and the debug uniform). The bilateral filter writes `(ao, octahedral)` only
  when the flag is set and the former `(ao, ao, ao)` otherwise.
- **Temporal history layout.** The history target holds `(ao, octahedral.x, octahedral.y, depth)`, so it shares the raw
  layout in its first three channels and the bilateral filter reads either. The depth moved to the alpha channel.
- **Diffuse surface binding.** The design assumed the composite pass already received `diffuseSurface3DTexture`. It
  received only the GI result. The composite now binds the IBL irradiance texture (binding 26) and the diffuse surface
  texture (binding 27), and the target is allocated when bent-normal lighting is possible (CORTAO, bent normals on,
  image-based light, compute passes, lighting surface attachment). The assumption that the texture holds
  `baseColor * diffuseWeight` holds for the opaque path (`flat3d.wesl`). Clearcoat and sheen scale the ambient term
  after that value is written, so for those materials the subtracted diffuse part is slightly large and the result is
  clamped at zero.
- **Producer.** The ray directions are a constant table in the shader instead of a loop with trigonometry.
- **Debug view.** `DebugView3D.bentNormals` (shader mode 8). It is excluded from the legacy golden-frame loop, like
  `meshlets`, and has its own test, because the Metal references cannot be recorded on this machine.
- **Verified on SAGA Vulkan** by the GPU tests in `Render3DDebugViewTests.swift`. Metal is not verified.
- **Independent review (2026-11-23) and its outcome.** Fixed: a compute pipeline that is not ready (asynchronous
  creation or failure) now makes the AO node fall back to SSAO instead of failing the command buffer
  (`ComputePipelineState.isReady`); bent-normal lighting is skipped for lightmapped and irradiance-grid surfaces, which
  the composite would otherwise double count; CORTAO targets and the bent-normal flag are released when a view stops
  using them; the usage example and the Vulkan-only validation are stated in `RenderingFoundation.md`. Accepted and
  documented: RGBA16F pyramid depth precision, and the history lookup ignoring upscaler jitter. The native Studio exporter regenerated
  `Editor/WebUI/assets/agent-contract.json` when integrating the change. Open test gaps include odd sizes, targets
  below 8 px, resize and per-view cleanup, and bent-normal fallback without IBL.
