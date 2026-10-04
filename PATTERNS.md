# Procedural surface patterns

`E.Pattern` provides deterministic building blocks for texture-bake shaders. Each function takes a world-space position, and some also take a normal, so a `Bake.rasterize` callback can combine them per texel. Patterns are evaluated in world space, so they continue across separate parts, meshes and UV charts without seams, and their scale is in studs.

| Function | Returns | Use |
| --- | --- | --- |
| `Pattern.hash(i, j?, k?, seed?)` | uniform `[0, 1)` per integer cell | per-cell random values (panel tone, tile choice) |
| `Pattern.smoothstep(e0, e1, x)` | cubic Hermite in `[0, 1]` | soft thresholds; `e0 > e1` gives a falling edge |
| `Pattern.fbm(p, {frequency, octaves, lacunarity, gain, seed})` | `[-1, 1]` | broad patches, mottling, grain |
| `Pattern.panels(p, options)` | `{column, row, id, seam, u, v}` | sheet metal, cladding, tiles, planks |
| `Pattern.streaks(p, normal, options)` | `[0, 1]` | rain runs, drip marks, water staining |

## Panels

Panels form a grid of `width × height` studs.
- **`projection = "cylindrical"`** (the default): wraps the grid around the Y axis of `frame`, measured as arc length at a reference `radius`. The column count is rounded to a whole number, so the ring closes without a partial column. Columns start at `seamAngle`.
- **`projection = "planar"`**: lays the grid on `frame`'s XY plane.

The other options are:
- **`rowOffset`** sets the vertical phase in studs.
- **`jitter`** shifts each row sideways by a random fraction of the width, between -jitter/2 and +jitter/2.

The result fields are:
- **`seam`**: the physical distance in studs to the nearest panel edge, measured at the point's own radius. Use it for seam lines, for example `1 - smoothstep(0, 0.08, s.seam)`.
- **`id`**: a per-panel uniform value. Use it to vary the tone from sheet to sheet.

Rows follow the axis rather than the surface, so seams stay straight in the world across folds and bumps, as with sheet cladding on a sculpted form.

## Streaks

Streaks are straight rain or drip runs. Each active source starts at a random height, runs for about `length` studs (between 0.4 and 1.6 times it) with a random strength, and fades toward its bottom. `width` is the run's half-width in studs and `coverage` is the fraction of sources active per height period. The value is largest on vertical surfaces. It fades to zero on surfaces facing up (water stands rather than runs) and on undersides facing down (water drips off).

`projection` decides where sources sit:
- **`"world"`** (default): a jittered grid `spacing` studs apart in the horizontal plane. Each run is a vertical curtain, so it is long on vertical walls and breaks into short dashes where a surface leans or folds away from it.
- **`"cylindrical"`**: sources every `spacing` studs of arc around `frame`'s Y axis at reference `radius`. Depth is ignored, so runs follow a flaring or folded surface the way water runs down it. Use this for statues, columns and towers.
- **`"planar"`**: sources every `spacing` studs along `frame`'s X axis, ignoring depth along Z. Use this for facades.

## Baking a part in world space

`Roblox.fromPart(part)` reads a MeshPart back as an authoring mesh in world space. It also reads unpublished parts (EditableMesh content) in place. It applies the part's size scale and CFrame and maps the stored normals through the transform. Published meshes come back with one vertex per triangle corner, so their normals are not recalculated. `Deform.transform(mesh, frame, scale, { normals = "transform" })` does the same for any mesh. Read-back meshes have no shared vertices, so recalculating their normals makes them faceted. Use `Normals.unify(meshes, {tolerance, angle})` to recompute normals over all the parts cut from one surface; it returns a copy of each part's mesh, keeping its own faces and UVs, with no shading break at part boundaries. Use `UV.cylindrical(mesh, center, height, { seamAngle, normalize = true, margin })` to give a tall part cylindrical UVs that fill its own texture with the seam where it is least visible.

```lua
local mesh = E.Roblox.fromPart(part) -- world space, existing UVs kept
local texture = E.Bake.rasterize(mesh, 1024, 1024, function(ctx)
	local panel = E.Pattern.panels(ctx.position, { width = 3.5, height = 7, radius = 9, jitter = 0.6 })
	local tone = 1 + (panel.id - 0.5) * 0.12 - (1 - E.Pattern.smoothstep(0, 0.06, panel.seam)) * 0.25
	local run = E.Pattern.streaks(ctx.position, ctx.normal, { projection = "cylindrical", radius = 9, spacing = 0.3, length = 8, width = 0.1, coverage = 0.4 })
	local base = Color3.new(0.43 * tone, 0.65 * tone, 0.61 * tone)
	return base:Lerp(Color3.fromRGB(70, 90, 120), run * 0.5), 1
end, { padding = 4 })
```

Because the mesh keeps its UVs, the new texture fits the published part unchanged. Assign it to a fresh `SurfaceAppearance` (see the engine notes in the Studio skill), then publish only the maps with `Roblox.publishMaterials({ part }, metadata, options)`. That uses the same verified transaction and resume ledger as `Roblox.publish`, but no mesh asset is created.
