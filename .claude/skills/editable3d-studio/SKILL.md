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

## Re-texturing published parts

- Multi-part models made by `toModel`/`partition` are 18k-triangle chunks that can overlap spatially. A part's name doesn't tell you which surface region it covers, so rebuild or re-texture whole groups, not single chunks.
- For streaks on figures, columns and flaring cloth, use `Pattern.streaks` with `projection = "cylindrical"`. The default world curtains break into dashes wherever the surface leans.
- Bake in world space with `Roblox.fromPart(part)`. The part keeps its UVs, so the new texture fits without a new mesh. Combine `Pattern` fields (panels, streaks, fbm) in the `Bake.rasterize` shader; they are continuous across parts because they are evaluated in world space.
- Apply the image on a **new** SurfaceAppearance, copying the other maps' URIs, `Color` and `AlphaMode` from the old one, then destroy the old one.
- Publish with `Roblox.publishMaterials(parts, metadata, {resume = ledger, maxBytes = 2^31})`: only the editable maps upload, and the meshes are guarded but not replaced. Asset-URI maps are skipped, so one changed map per part means one image asset.
- Keep color-map encoding consistent with earlier bakes (`toEditableImage(texture, srgb)`); switching the flag shifts every tone.

## Publishing

- Asset `Name` must be short (a ~60-character name was rejected: "Asset name length is invalid", HTTP 400); keep names under ~50 characters. The rejection happens before creation, so no asset is made.
- Large bundles exceed the default `maxBytes` (256 MB of cumulative snapshot accounting); pass e.g. `maxBytes = 2^31` for 10+ parts.
- Meshes created elsewhere may share corners but not edges (each triangle's edges unique). Smoothing with `pinBoundary` then pins every vertex; pin only vertices used by fewer than three triangles instead.
- `Roblox.publish(bundle, {Name, Description, CreatorId, CreatorType}, {resume = ledger, attempts = 3})`. Keep the `ledger` table across retries; created assets are never auto-deleted.
- A failed readback does **not** change the scene (`committed = false`); the report lists `assets` already created.
- Publishing is outward-facing (assets on the user's account): get the user's approval for the project before the first upload.
