---
name: editable3d-studio
description: Working with Editable3D inside Roblox Studio — engine behaviors that differ from the headless tests, safe long-running job patterns, capture/measurement techniques, the verify→install release flow, and publishing. Load before running Editable3D code in Studio, publishing meshes/images, or debugging something that passes headless but misbehaves in the engine.
---

# Editable3D in Roblox Studio

Headless tests (`tools/headless.luau`, Lune) cover the math. The engine adds behaviors Lune cannot reproduce. Everything below was learned from real failures; check here before assuming a library bug.

## Engine behaviors that differ from headless

| Behavior | Symptom | What to do |
|---|---|---|
| **Published meshes are stored one vertex per triangle corner.** An 18,000-triangle mesh comes back with 54,000 vertices. | Readback that compares vertex welding fails ("content mismatch") although nothing visible changed. | Compare per triangle corner (`NativeContent` does since 0.77.1). Never assume vertex IDs or sharing survive an upload. |
| **Published normals are quantized** (max observed error 8.4e-4); positions, UVs, colors, alpha and image bytes return exact. | Exact readback comparison fails on normals only. | Compare normals with a tolerance (`NativeContent.equivalent`, 0.77.2). To diagnose any mismatch, match triangles by position and report the max delta per channel. |
| **Instance members shadow children.** `script.Capabilities` is the sandboxing property, not a child named `Capabilities` (also `Source`, `ClassName`, `Archivable`, …). | "Attempted to call require with invalid argument(s)" only in Studio. | Use `script:FindFirstChild("Name")` for any child whose name could be a member. The headless harness mirrors this. |
| **Editable memory budget.** Past the editable mesh/image budget, new `EditableImage`s attach fine but render white/blank. `Stats:GetTotalMemoryUsageMb()` may read >10 GB in a big place. | Correct pixel data (`ReadPixelsBuffer`) but a white surface. | Destroy discarded previews (`Roblox.destroy(bundle)`), drop large intermediate meshes, recreate images, and publish finished work so it no longer needs editables. |
| **SurfaceAppearance maps don't reliably refresh in place.** | Assigning a new `ColorMapContent`, or destroying the old bound image, leaves the old/blank texture. | Destroy the `SurfaceAppearance` and create a new one, assign all maps, then destroy old images. |
| **Raycasts hit collision geometry.** `toModel(..., {collisionFidelity = Box})` parts are boxes to `workspace:Raycast`. | A ray reports the bounding-box face, not the rendered surface. | Inspect the source mesh's vertices, or use `Spatial` queries on the authoring mesh. |
| **Quads can become degenerate after heavy deformation.** | `Mesh:faceTriangles` → "Final polygon triangle is degenerate" during `toModel`. | `Topology.triangulate` before large `Deform.map` edits; triangles skip ear clipping. |
| **Read-back meshes have no shared vertices** (see the first row), so `recalculateNormals`, and anything that calls it (`Deform.map`, `Deform.transform` by default), produces faceted, flat-shaded normals. | A re-imported published part renders faceted after a bake or re-upload. | Use `Roblox.fromPart(part)` (0.78), or `Deform.transform(mesh, cf, scale, {normals = "transform"})`, which keeps the stored normals. To recompute, use `Normals.unify(meshes, {tolerance, angle})` (0.78.1) over all the parts cut from one surface, so chunk boundaries don't show. To check a part, compare corner normals at equal positions: a smooth mesh disagrees by under 1°, a faceted one by 10° or more. |
| **EditableImage is capped at 1024×1024.** | `toEditableImage` fails with "Tile textures larger than EditableImage limits"; a 2048 bake also needs `maxBytes` above the default. | Bake at 1024 or less; for more detail use more parts or `UV.box` with tight charts. |
| **Island and clip operators need oriented manifold input.** `UV.packIslands`, `UV.islands`, `Modifiers.clipPlane` and the mesh editors reject read-back meshes ("UV charts require oriented manifold geometry", "Mesh edit requires a valid oriented source"). | A published or chunked mesh can't be packed or clipped. | Use `UV.box` (soup-safe), drop faces with `Topology.extract` by a plane test, or run `MeshRepair.clean`/`orient` first. Unwelded soups also make one UV island per triangle (allocation budget errors). |
| **Coincident co-facing surfaces z-fight**, and `Highlight` or raycasts won't show which part wins. Duplicated chunk sets, a cloth layer modelled on the layer beneath it, or a frame laid on glazing all flicker between textures. | Speckled, checker-like patches of a second texture that shift as the camera moves, worst at grazing angles and from a distance. | Audit with `Spatial.coincidentPairs(meshes)` (0.83) over `Roblox.fromPart` read-backs of every visible part, then remove the hidden layer's faces with `Spatial.trimCoincident(mesh, keepers)` before republishing. **First check that the "duplicate" isn't complementary:** before 0.83.1, `toModel` could split a triangulated quad mesh into checkerboard chunks (one triangle of every quad each). Each chunk is full of holes on its own, and the speckle is two bakes alternating. Render one part alone, close up: a checkerboard means merge the parts and re-chunk (0.83.1 partitions spatially), not delete. |
| **`Highlight` is capped at 31 active instances.** | Highlight-based part identification silently stops colouring parts past 31. | Highlight one group at a time (e.g. only the candidates near the problem). |
| **Lofts and transforms can turn a mesh inside-out.** Ring winding decides a loft's orientation, and a left-handed frame (X × Y = -Z) mirrors any `Deform.transform`. | A solid renders see-through, or shows its far inner walls. | Check the signed volume (sum of a·(b×c)/6 over triangles); reverse with `Topology.reverse` when it is negative, or use `Primitives.prism`, which orients itself. |
| **`Vector3` is a value type in the engine.** Equal vectors are the same table key. | Fine in Studio; in Lune (userdata) they are distinct keys. | Listed as `engineOnly` in `tests/headless-baseline.json`. |
| **Lune 0.10.5 `CFrame.lookAt`/`lookAlong`/`new(pos, target)` face away from the target.** | Headless camera/render tests fail. | The harness rebuilds them from `fromMatrix`; do not "fix" the library for this. |

## Long-running work in Studio

- `execute_luau` calls time out (~120 s). Run real work in `task.spawn` inside a session `ModuleScript` (e.g. `ServerStorage.<Project>.Session` returning a table), store `Job = {state, phase, result, error}`, and poll with short calls that `task.wait` while `state == "running"`.
- Wrap work in `xpcall(fn, debug.traceback)`; report `error` text.
- Code run through MCP is **nonstrict**; types won't catch argument mistakes (e.g. `UV.planar` takes a `CFrame`). Check `API.md` signatures.
- Keep authoring meshes (`E.Mesh`) in the session as the source of truth; native bundles are previews. Destroy a previous bundle before building its replacement.

## Measuring against references

- A single frontal photo can't tell which way a flat object (a plaque, a tablet, a shield) is yawed: a face turned 45° left and one turned 45° right project to the same width. Resolve it with a second view (a side or three-quarter photo shows which face is visible) or with lighting (which face catches the sun or sky).
- Check placement against the body: sample the surface the object rests on, and push parts that must pass behind it (a forearm behind a held slab) out through the correct face. Pushing to the nearest face can flatten them onto the front.

- **Near-orthographic captures:** set `workspace.CurrentCamera.FieldOfView = 4` and capture from ~200 studs. World units per pixel = `2 * distance * tan(FOV/2) / viewportHeight`. Restore the FOV afterwards (record the old value).
- Camera looking along +Z from −Z: image right is world **−X**.
- Grid-overlay the capture (PIL) to read landmark pixel coordinates precisely; compare ratios normalized by a stable feature distance.
- `screen_capture` can return a stale frame; if two captures are pixel-identical, move the camera and re-check state directly.

## Release: verify then install

1. `python3 tools/validate.py` (all gates) → commit.
2. Serve `dist/` on `127.0.0.1:8772`; run `tools/studio_verify.luau` in Edit. It builds a fresh tree and runs **all** suites and examples, including native ones. Poll `TestState`/`CurrentSuite` attributes on the tree.
3. Read the report, require 0 failures and source parity.
4. Write `dist/docs.json` (root guides except CHANGELOG), fill the three placeholders in `tools/studio_install.luau`, run it. It archives the previous install (keeps two) and installs the runtime profile.
5. Remove the verification tree; stop the server.

## Reshaping photo-derived or published sculpts

- Use `Deform.envelope` and `Deform.relief` (0.80) to impose relief from a photo depth map, to symmetrize, or to band-pass sharpen. The recipes are in DEFORMATION.md.
- View coordinates are relative to the view frame (`q.Y` is height minus the camera's height). Mixing them up with world heights silently moves nothing.
- Check the result as numbers, not only in renders: print cross-sections (frontmost z per x bin at a few heights) before and after. A face whose cross-section is flat for most of its width reads as "a mask on a ball" from three-quarter views.

## Diagnosing speckle and see-through

- **Render each suspect part alone, close up, before changing anything.** A checkerboard means interleaved chunks (merge and re-chunk). Hatching along triangle edges means cracks (`Topology.snap`). Two textures alternating as the camera moves means co-facing coincident layers (`Spatial.trimCoincident`).
- Layers behind a surface can hide its holes and cracks. Removing a "hidden" layer exposes them, so seal the front surface first, then trim what's behind.
- To restore a deleted or replaced part, recreate it from its mesh ID with `AssetService:CreateMeshPartAsync`, then find its translation from triangle edge vectors (identical for exact copies) or a translation-only ICP. Destroyed instances keep their properties, so a session reference still gives the old CFrame.

## Reshaping faces and organic forms

- Print horizontal cross-sections (frontmost z per |x| bin at a few heights) before and after any change. A "mask on an egg" shows up as a flat run followed by a cliff.
- Reshape the low frequencies only: blur a frontmost-depth grid, fit a smooth target per row (for example a superellipse through the edge width and the depth near the midline), and offset the front layer by (target − blurred). Weight the front layer from the blurred grid and apply it per vertex with `Deform.map`, which leaves no gaps; the fine detail rides along.
- World-projected rain streaks and sheet seams from a large-surface shader read as stripes on a face. Give faces their own shader with mottling and orientation weathering only.

## Masks, shells and seams

- A sculpt built as a front "mask" (a face, a relief) looks like a mask in profile. Build a closed volume behind it that tracks the mask's own per-row arcs, set slightly behind the mask's centre but in front of its rim. Then remove the mask's faces where the volume covers them (raycast along the view and compare depths). Coincident rims z-fight as small tears.
- Before treating a line on a surface as a crack, check it two ways: `MeshRepair.audit` for boundary and crack edges near it, and a front-depth profile across it (raycasts along the view at a few x). A continuous profile with no boundary edges means it's texture, such as a panel seam in the shader, or a fold seen at grazing angles.
- Run `MeshRepair.unfold` on heavily deformed sculpts (faces after several relief and smoothing passes) before publishing. Folded triangles render as small tears.
- Serrated, sawtooth lips along folds or layer edges are usually open boundary edges: a sheet cut along a diagonal of its grid leaves a staircase. `Sculpt.smooth` pins the boundary, so smoothing never removes them. Weld, then run `Sculpt.smoothBoundary` (about 12 iterations, `rings = 2`) and map the result back to the soup parts by position key. To confirm, mark boundary vertices with small neon parts and check that they lie on the teeth.
- A capped loft whose rings run along a negative axis comes out inside-out and is culled, so only its other pieces show. Pass `outward = true`.
- A preview model built with `toModel` and parented to `workspace` stays there after publishing. Re-parent it into the target model, or later scans of that model will miss it.
- On a read-back part, a session reference to a hidden original makes `Transparency < 1` filters skip it. Measure on the preview parts you are actually showing.

## Re-texturing published parts

- Multi-part models made by `toModel`/`partition` are 18k-triangle chunks that can overlap spatially. A part's name doesn't tell you which surface region it covers, so rebuild or re-texture whole groups, not single chunks.
- For streaks on figures, columns and flaring cloth, use `Pattern.streaks` with `projection = "cylindrical"`. The default world curtains break into dashes wherever the surface leans.
- Bake in world space with `Roblox.fromPart(part)`. The part keeps its UVs, so the new texture fits without a new mesh. Combine `Pattern` fields (panels, streaks, fbm) in the `Bake.rasterize` shader; they are continuous across parts because they are evaluated in world space.
- Apply the image on a **new** SurfaceAppearance, copying the other maps' URIs, `Color` and `AlphaMode` from the old one, then destroy the old one.
- Publish with `Roblox.publishMaterials(parts, metadata, {resume = ledger, maxBytes = 2^31})`: only the editable maps upload, and the meshes are guarded but not replaced. Asset-URI maps are skipped, so one changed map per part means one image asset.
- Keep color-map encoding consistent with earlier bakes (`toEditableImage(texture, srgb)`); switching the flag shifts every tone.

## Publishing

- After a committed publish, the bundle's model is the scene. Clear any session variable that still points at the bundle, or call `Roblox.release(bundle)` to free its editables. Since 0.82, `Roblox.destroy` refuses published bundles. Before that, a later "clean up the previous preview" `destroy` on a stale reference deleted a published model; it had to be rebuilt from its asset IDs by re-running `toModel` on the source mesh (deterministic chunking) and applying each mesh asset with `ApplyMesh`.

- Asset `Name` must be short (a ~60-character name was rejected: "Asset name length is invalid", HTTP 400); keep names under ~50 characters. The rejection happens before creation, so no asset is made.
- Large bundles exceed the default `maxBytes` (256 MB of cumulative snapshot accounting); pass e.g. `maxBytes = 2^31` for 10+ parts.
- Meshes created elsewhere may share corners but not edges (each triangle's edges unique). Smoothing with `pinBoundary` then pins every vertex; pin only vertices used by fewer than three triangles instead.
- `Roblox.publish(bundle, {Name, Description, CreatorId, CreatorType}, {resume = ledger, attempts = 3})`. Keep the `ledger` table across retries; created assets are never auto-deleted.
- A failed readback does **not** change the scene (`committed = false`); the report lists `assets` already created.
- Publishing is outward-facing (assets on the user's account): get the user's approval for the project before the first upload.
