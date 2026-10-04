# Surface shading and CPU light transport

`BSDF`, `Lighting`, and `Integrator` are original Luau implementations. They operate on authoring meshes and linear floating-point `Texture` images without creating Roblox instances, accessing services, downloading files, or changing the place. They supplement the existing `PathTrace` API. They are a CPU reference renderer, not Cycles parity and not a replacement for Roblox's real-time renderer.

## Conventions

- Colors are **linear RGB**, expressed as `Color3` or `Vector3`. Material reflectances must lie in `[0,1]`; emitted radiance may exceed one. Texture color-space conversion is explicit through `Texture.fromRGBA8(..., true)` and `toRGBA8(true)`.
- All BSDF directions are unit vectors pointing **away** from the surface. The normal faces the outgoing direction. `evaluate` returns an RGB `Vector3` BRDF; `pdf` returns a density with respect to solid angle.
- Resolve texture/function parameters once per intersection with `BSDF.resolve(material, context)`. Subsequent evaluation and sampling use the returned closure. The context supplies `uv`, `position`, geometric/shading normals, face, triangle, and barycentrics. Scalar textures use their red channel; color textures use RGB. Texture sampling wraps unless `context.wrap=false`. Missing UVs produce an error rather than silently substituting coordinates.
- `sample` returns `{direction, pdf, weight, delta, transmission}` or `nil`. For non-delta samples, `weight = evaluate * abs(n·wi) / pdf`. For ideal dielectrics, `pdf` is a discrete event probability and `weight` is already the corresponding transport weight. A `nil` GGX sample is a zero-contribution event; **do not retry it**, because that would condition the distribution and bias the result.

## BSDF API

| Function | Behavior |
|---|---|
| `diffuse(color?)` | Lambertian reflectance; defaults to linear 0.8 gray. |
| `ggx(options?)` | Isotropic rough reflection with correlated Smith masking/shadowing and visible-normal importance sampling. `roughness` defaults to 0.5. Optional RGB `f0` uses Schlick; otherwise exact dielectric Fresnel uses `ior` and `exteriorIor`. |
| `metallicRoughness(options?)` | GGX reflection plus a reciprocal, Fresnel-attenuated diffuse substrate. Accepts `baseColor`, `roughness`, `metallic`, `ior`, `exteriorIor`, and optional `f0` override. Metal color uses Schlick RGB reflectance; this is not complex-IOR spectral conductor transport. |
| `dielectric(ior?, tint?)` | Ideal reflection/refraction with exact Fresnel, total internal reflection, and radiance-mode eta-squared transmission. Defaults to IOR 1.5 and white tint. No rough refraction. |
| `mix(a, b, weight?)` | Convex mixture of two material closures. Weight can be a number, texture, or context function. A mixture is **not** a physical coating/layer solver. |
| `resolve(material, context?)` | Resolves and validates material values. Constructors are lightweight descriptions; resolution performs parameter validation. |
| `evaluate(material, normal, outgoing, incoming)` | RGB reflection BRDF. Delta dielectric events evaluate to zero in the continuous domain. |
| `pdf(material, normal, outgoing, incoming)` | Continuous solid-angle sampling density, including mixture probabilities. Delta-only materials return zero. |
| `sample(material, normal, outgoing, random?, entering?)` | Samples the material. `random` is a `Random` object or a function returning values in `[0,1)`. `entering=false` swaps interior/exterior indices for dielectric transmission. |
| `emission(material, context?, frontFacing?)` | RGB emitted radiance; honors `twoSidedEmission`. Mixture emission combines child emissions and any emission on the mixture itself. |
| `fresnelDielectric(cosine, etaI, etaT)` | Exact unpolarized dielectric Fresnel; handles total internal reflection and equal indices. |
| `fresnelSchlick(cosine, f0)` | RGB Schlick approximation. |
| `distributionGGX(cosine, alpha)` | Isotropic GGX normal distribution, per projected surface area. |
| `maskingGGX(cosine, alpha)` | Smith single-direction masking function. |
| `sampleGGX(normal, outgoing, alpha, u, v)` | Samples a visible microfacet normal, not an outgoing light direction. Requires `u,v` in `[0,1)`. |

Non-mixed materials accept an `emission` constant, texture, or context function. All materials support `twoSidedEmission`. Reflectance inputs accept constants, textures, or functions; defaults apply when omitted. `baseColor` also accepts `albedo` as an alias. GGX uses **alpha = max(0.001, roughness²)**. Zero roughness is therefore a very narrow finite lobe, not a perfect mirror delta distribution. GGX includes single scattering only, so rough metal may lose energy through unmodeled microfacet interreflection. The diffuse substrate in `metallicRoughness` is a documented approximation, not an exact multilayer BSDF.

## Lighting API

| Function | Behavior |
|---|---|
| `surface(mesh, hit)` | Interpolates corner UVs and normals into a context using a `Spatial` hit. |
| `point(position, intensity)` | Point-source RGB intensity with inverse-square attenuation. |
| `directional(direction, radiance)` | Distant delta light; direction points from the surface **towards** the light. |
| `environment(source)` | Constant color, direction callback, or latitude/longitude `Texture`. Texture row 0 is the +Y pole; U maps azimuth about +Y. |
| `environmentRadiance(environment, direction)` | Evaluates linear environment radiance. |
| `environmentPDF(environment, direction)` | Directional density for environment sampling. |
| `sampleEnvironment(environment, random)` | Returns `{direction,radiance,pdf,distance,delta}`. Texture bins are weighted by luminance times exact spherical solid angle. Sampling within each bin is uniform in solid angle. |
| `new(mesh, materials, options?)` | Compiles a light set. It discovers emissive mesh triangles, plus `options.lights` point/directional sources and one optional `options.environment`. |
| `lightSet:sample(point, random)` | One next-event sample. PDF includes source-selection probability. |
| `lightSet:pdf(point, direction, hit?)` | Matching density for a BSDF-generated ray; omit `hit` for environment rays. |
| `lightSet:environmentRadiance(direction)` | Environment evaluation, or black if none. |

The light-set input mesh/materials must remain unchanged while rendering. Rebuild after edits. Environment importance distributions likewise snapshot texture luminance at construction: rebuild after texture edits. The renderer's `prepare` snapshots the geometry through `Spatial`, but material callbacks and texture objects remain caller-owned.

Area lights are actual emissive mesh triangles. Their sampling weights use area and centroid emission, with a nonzero weight for potentially emissive procedural/textured sources. This keeps sampling support but is only an approximate power distribution. Point/directional sources have no visible shape. Environment lookup uses bilinear texel-center sampling, repeats continuously across the longitude seam, and clamps latitude at the poles. Constant/callback environments use uniform-sphere sampling. A black texture falls back to uniform sampling.

## Integrator API

```lua
local E = require(game.ReplicatedStorage.Editable3D)
local camera = E.Camera.new(CFrame.lookAt(Vector3.new(0, 1, 5), Vector3.zero), 40, 64, 64)
local material = E.BSDF.metallicRoughness({
    baseColor = Color3.new(0.55, 0.28, 0.1),
    roughness = 0.35,
    metallic = 0.9,
})
local hdr, report = E.Integrator.render(E.Primitives.sphere(1, 32, 16), camera, { material }, {
    samples = 32, bounces = 6, seed = 12,
    environment = Color3.new(0.15, 0.2, 0.3),
    lights = { E.Lighting.point(Vector3.new(-3, 4, 3), Color3.new(70, 60, 50)) },
    yieldEvery = 4,
})
local display = E.Integrator.toneMap(hdr, 0, "reinhard")
local rgba = display:toRGBA8(true)
-- Optional native conversion is explicit: E.Roblox.toEditableImage(display, true).
```

- `prepare(mesh, materials?, options?)` builds a geometry snapshot and a light distribution.
- `trace(scene, origin, direction, options?, random?)` returns HDR `Vector3` radiance and counters. `bounces` limits scattering events; `bounces=0` still sees directly visible emission/environment. Direct samples and BSDF-generated hits use the power heuristic, including their actual sampling densities.
- `render(mesh, camera, materials?, options?)` returns a linear HDR `Texture` and report. It uses geometric triangle normals consistently for transport; interpolated corner normals are exposed in contexts but do not change the scattering frame. This avoids silently introducing an uncorrected smooth-normal transport model.
- `powerHeuristic(pdfA, pdfB)` returns the first technique's squared-density weight.
- `toneMap(image, exposureEV?, method?)` creates a display-linear image using `reinhard` (default) or `clamp`; it does not gamma-encode or change the HDR source.

Render options: `samples` (default 16), `bounces` (8), `seed` (0), `bias` (0.0001 model units), `rouletteDepth` (3), `directLighting` (true), `lights`, `environment`, `cancelled()` callback, `progress(fraction)` callback, and positive integer `yieldEvery` rows. Cancellation returns `nil, report` with completed-row count. Russian roulette divides surviving throughput by survival probability. Point/directional direct samples are treated as delta sources; mesh/environment rays receive MIS weights to avoid counting their contribution twice.

## Verification and limits

`tests/ShadingTests.luau` checks Fresnel/TIR, diffuse throughput, projected GGX normalization, sampled acceptance/moments against independent hemisphere quadrature, reciprocity and white-furnace energy, texture resolution, mixture PDFs, ideal refraction weighting, environment bin frequencies including poles, matching area-light PDFs, analytic point-light illumination and occlusion, MIS energy consistency, deterministic HDR rendering, cancellation, tone mapping, and invalid inputs. Numerical tests are evidence for these cases, not a proof of every transport configuration.

`examples/PBRPreview.luau` returns a three-material study as HDR/display textures and a report, without changing the scene.

Current limits: isotropic surface reflection, ideal dielectric transmission, RGB rather than spectral transport, flat geometric transport normals, finite-bounce truncation, caller-selected ray bias, no volumes, subsurface scattering, hair/fiber scattering, anisotropy, rough refraction, dispersion, absorption through dielectric interiors, physical multilayer coatings, bidirectional light transport, GPU acceleration, adaptive sampling, motion blur, depth of field, or denoising. Transparent dielectric objects still occlude direct shadow rays; illumination through them is carried by sampled refractive paths and may have high variance. Nested dielectric media require caller-managed boundary indices; there is no automatic medium stack. Emission geometry is discoverable, but arbitrary directional emission functions are not supported. This renderer does not define a Roblox shader or guarantee numerical parity with Roblox PBR.

## Algorithm references

These sources informed the equations and sampling conventions; this package does not embed their source code:

- [PBRT: Roughness Using Microfacet Theory](https://www.pbr-book.org/4ed/Reflection_Models/Roughness_Using_Microfacet_Theory) — GGX distributions, Smith visibility, and visible-normal sampling.
- [PBRT: Dielectric BSDF](https://www.pbr-book.org/4ed/Reflection_Models/Dielectric_BSDF) — Fresnel reflection/refraction and transport conventions.
- [PBRT: A Better Path Tracer](https://pbr-book.org/4ed/Light_Transport_I_Surface_Reflection/A_Better_Path_Tracer) — next-event estimation, multiple importance sampling, and Russian roulette.
- [PBRT: Infinite Area Lights](https://www.pbr-book.org/4ed/Light_Sources/Infinite_Area_Lights) — directional light distributions and environment sampling.
