# Editing published parts in Studio

A published MeshPart stores its mesh and its SurfaceAppearance maps as uploaded assets. Editing one is a round trip: read the asset back into an authoring `Mesh` or `Texture`, build an editable preview beside or in place of the part, then publish the preview (or revert it) and free the editables. The functions below do that round trip for whole sets of parts: chunked meshes, many parts sharing one colour map, or a model rebuilt from offline data. Everything here runs in Studio's Edit context. Publishing contracts (transactions, verification, resume ledgers) are in [PRODUCTION.md](PRODUCTION.md); the point maps used with `Roblox.reshape` are in [DEFORMATION.md](DEFORMATION.md#point-maps-for-read-back-and-published-meshes).

## Reading parts back

`Roblox.fromPart(part, {space})` returns the part's mesh as an authoring `Mesh`. `space = "world"` (default) applies the part's size scale and CFrame and maps the stored corner normals through the transform; `"mesh"` keeps the stored coordinates. An unpublished part (EditableMesh content) is read in place.

A published mesh comes back with one vertex per triangle corner: its UV and normal seams are split everywhere, and vertex ids do not survive an upload. Weld it (`Topology.weld`) before anything that walks neighbours, and recompute normals over all the parts cut from one surface together (`Normals.unify`), never per part, or chunk boundaries show. `Topology.componentLabels(mesh, {tolerance})` labels the connected pieces of such a soup without rebuilding it.

## Reshaping geometry

`Roblox.reshape(parts, map?, options?)` reshapes parts as a preview and returns `{entries, publish, revert}`:

1. Each part is read back in world space.
2. Every vertex goes through `map(position, part, piece?)` (a world-space point map; nil keeps positions).
3. Normals are re-derived across all the parts together (`Normals.unify` with `angle` in radians, default `math.rad(75)`, and `tolerance` 1e-3; `unify = false` skips it), so seams between chunks stay smooth. A smaller `angle` keeps sharp edges sharp (a ridge whose faces meet at 40 degrees stays two-toned at `math.rad(30)`).
4. A new bundle with the part's material, colour, DoubleSided and SurfaceAppearance is shown in the part's parent, and the original is hidden.

`:publish(metadata, options)` uploads each bundle and puts it in the original's place (a single-part holder model of the same name is replaced whole). `metadata` is a table, whose `Name` gets `" <part name>"` appended (trimmed to 50 characters), or a function of the part. `:revert()` restores the originals. Report rows are keyed by part name in `published` and `failures`; `parts` lists every entry in order.

Options:

| Option | Effect |
| --- | --- |
| `edit = function(mesh) -> mesh` | All parts are read back, joined and welded (`weld`, default 1e-3) into ONE mesh; `edit` returns it with moved vertices (same ids), and every part's vertices take their welded vertex's new position. Neighbourhood edits (`Sculpt.smooth` with a mask, `Sculpt.fair`, `Sculpt.brush`, `Deform.mapComponents`) then cross part seams without opening cracks. `map` applies on top. |
| `components = true` | `map` receives a third argument: the vertex's connected piece of its part (`Topology.componentLabels`, welded within `weld`, default 1e-4) as `{index, centroid, count, min, max}`. Transform pieces whole by their own piece, never by the nearest axis: pieces whose bases overlap would trade vertices. |
| `keep(centroid, part) -> boolean` | Trims faces: a face whose ORIGINAL centroid fails is removed; surviving faces keep their UVs and textures. A part that loses every face gets no preview, stays hidden (`entry.removed`) and is destroyed when the publish succeeds for every other part. |
| `changedOnly = true` | Parts that no vertex of moved more than `epsilon` (default 1e-5) are left alone: no preview, no publish, `unchanged = true` on their entry and report row. They still join the normal unification, so changed neighbours keep matching seam normals. A local edit of a chunked mesh rebuilds and uploads only the chunks it touches. |
| `maxTriangles`, `collisionFidelity` | Passed to the rebuilt bundles (defaults 18000 and Box). |

Point maps for `map` and `edit` (section scaling, cylindrical remaps, per-piece segment maps, tables of moves computed offline) are described in [DEFORMATION.md](DEFORMATION.md#point-maps-for-read-back-and-published-meshes). A table of per-vertex moves computed outside Luau (a relaxation or fit on exported geometry) applies with `Deform.moveTable` as `map`, together with `changedOnly`.

Moving a part rigidly needs no reshape: set `part.CFrame` (store the previous one, for example in an attribute).

## Re-texturing

Each of these leaves meshes untouched, writes new EditableImage colour (or normal) maps for the parts, shows them on new SurfaceAppearances, and returns a handle with `images` and `revert()`. Parts that share a colour map are read back, joined and processed together in that map's UV space. Publish the result with `Roblox.publishMaterials(parts, metadata, options)`, which uploads only the editable maps of the parts and keeps their meshes.

| Function | What it writes |
| --- | --- |
| `modulateColor(parts, factor, options)` | `colour × factor(position, normal, current)`, a number or a per-channel `Color3`, rasterized in the map's UV space and padded by `padding` texels (default 6). Texels it does not cover stay byte-identical. Returns `changed`, the texels written. |
| `rebake(parts, shader, options)` | A full re-bake of each part's own UVs from `shader(position, normal, part, ctx, previous) -> (Color3, alpha?)`. `previous` is the part's current colour map read back as a `Texture`, so a shader can modulate it with `previous:sample(ctx.uv)`. Returns a handle whose `:publish(metadata, options)` uploads the maps. |
| `localContrast(parts, options)` | Compresses (`strength > 0`) or expands (`< 0`) baked shading by scale, in world space. Pass 1 averages texel luminance into cells of `cell` studs (0.25) and coarse cells of `coarse` studs (1), bucketed by the normal's dominant axis. Pass 2 multiplies each texel by `(m2/m1)^strength · (m3/m2)^broadStrength`, clamped to `[minFactor, maxFactor]`, with the means interpolated between cell centres. Detail finer than a cell is kept. |
| `fillColor(parts, weight, options)` | Inpaints a region (`weight(position, normal)`: 0 outside, 1 inside, soft between) from its surroundings. The fill is the inverse-distance-squared mean of outside cells (`cell` 0.05) within `reach` (0.6) studs, interpolated between cell centres; region texels become `lerp(colour, fill, weight)`. Use it to remove a painted feature before new shading goes on. |
| `bakeCavity(parts, options)` | Darkens concave creases and lightens ridges from the welded surface's curvature (`strength`, `ridge`, `scale`, `radius`, `smooth`), so folds read under lighting without ambient occlusion. Keep `radius` near the mesh's vertex spacing: a wide one blurs fine grooves away. |
| `bakeNormalMap(parts, normal, options)` | A normal map from a world-space shading normal per texel (`normal(position, meshNormal)`, nil leaves it flat), at the colour map's size or `options.size`. A published colour map paired with an editable normal map renders white, so the preview carries an editable copy of the colour map, and `publishMaterials` uploads both. |

All of them take the common limits (`maxSeconds`, `maxWork`, `maxBytes`, `checkpoint`, `cancelled`, `maxTriangles`; see [PRODUCTION.md](PRODUCTION.md)). Over many parts, pass a long `maxSeconds` and a yielding `checkpoint` (`function() task.wait() end`), or run them in a task, so Studio stays responsive.

Judge the result after publishing. An EditableImage copy of a published map renders brighter than the asset itself, so a preview looks lighter than its published neighbours. A map published moments ago can render white for up to a minute while it loads. Measure statistics (contrast, brightness) on published maps, never while a pass is partly applied.

## New parts from offline data

`Roblox.gridModel(rows, options)` builds textured parts from a grid of points with per-vertex data, the usual output of an offline fit (a height field sampled on rows and columns, a lofted sheet):

- `Topology.gridSectors` cuts the grid into column sectors (`sectors`, 1-based column boundaries), each with its own UV rectangle and map.
- Each sector becomes a `bakedModel` whose `color(ctx, {row, column})` and optional `normal(ctx, {row, column})` shaders receive the texel's fractional grid position. Read per-vertex tables (shade, occlusion, fold normals) there with `Bake.gridSample(values, row, column)`.
- `vertexNormal(r, c, position)` supplies whole-grid normals, so sectors join without seams. `padding` (8) keeps the UV islands inside each map's border; SurfaceAppearance maps wrap, so islands touching the border show thin lines along seams.

It returns one bundle per sector, named `name .. k` (default `"Grid" .. k`).

`Bake.transfer(target, source, texture, width, height, options)` carries a texture onto a rebuilt mesh with a new topology, UV layout or domain. Each target texel goes to its closest point on `source`, whose corner UVs are interpolated and sampled. `options.map` carries target positions into the source's space; `options.factor(ctx, colour, hit)` re-shades a sample; texels farther than `maxDistance` stay uncovered for `padding` to fill.

## Replacing parts: stage, publish, revert

`Roblox.stage(bundles, replaced)` shows new bundles (keyed by name) in place of existing parts, which are hidden. Parent each bundle's model yourself, and list its EditableImages in `bundle.images` so they are released. `:publish(metadata, options)` publishes every bundle with `Roblox.publishInChunks`; only when all of them commit are the replaced parts destroyed (with any Model they leave empty), and the committed bundles' editables released. A failure leaves the previews and the hidden parts as they are; rerun with the same resume ledger to finish. `:revert()` destroys the uncommitted bundles and shows the replaced parts again. `metadata` is a table (its `Name` suffixed with the key, cut to 50 characters) or `function(key, bundle)`.

A resume ledger refuses an object it published earlier whose content has changed since (edited, or destroyed: a destroyed EditableImage reads as 1×1). The error starts `Resume source changed`. Publish a new object, or use a fresh ledger for new content.

## Memory: release and sweep

Editables count against the engine's editable memory budget. Past it, new textures render white although their pixels read back correctly, so free editables as soon as their parts render published assets:

- `Roblox.release(bundle)` frees a published bundle's editables without touching its model. A reshape keeps one bundle per entry (`entries[i].bundle`).
- `Roblox.sweep(value, options)` destroys the editables reachable from `value` (keys and values of nested tables, to `depth` 8) that nothing displays (`Roblox.liveEditables(roots)`). `keep` lists editables, or tables holding them, that a session reuses without displaying them (shared material maps, templates). `dryRun` only counts. The report counts `destroyed`, `kept`, `tables`, and `stale`: editables an earlier sweep destroyed that `value` still references, neither destroyed nor counted again.
- `Roblox.liveEditables(roots?)` lists the editables that instances display: MeshPart mesh and texture, SurfaceAppearance maps, Decal/Texture and image GUI content. Roots default to Workspace, ServerStorage, ReplicatedStorage, Lighting and StarterGui.

To check that a place no longer depends on editables, scan its instances for content with `SourceType == Enum.ContentSourceType.Object`, or count `Roblox.liveEditables({game})`: both should be empty once everything is published.
