# Custom corner normals and tangent frames

`E.Normals` edits intrinsic face-corner shading data without moving vertices, changing winding or altering topology/materials. Each function returns `(newMesh, report)` and leaves the source unchanged. A source must have valid, consistently wound topology and finite positive face areas. Other typed channels, skin weights, groups and UVs remain attached to their elements. These operations do not deform a surface or repair face orientation; use `MeshRepair.orient` for winding.

```lua
local mesh = E.Primitives.box(Vector3.new(6,4,2))
mesh = E.Normals.recalculate(mesh, {
    weighting="areaAngle", angle=math.rad(100), faceWeights={[5]=2},
})
local framed, report = E.Normals.tangents(mesh)
assert(report.complete)
```

## Smoothing groups and weighting

`Normals.recalculate(mesh, options)` derives normals from geometry. Corners sharing a vertex join a smoothing group only through incident edges with two faces, no sharp mark, and a local face-normal angle at most `angle` (default pi). The resulting connected groups are transitive: a gradual bend may share one group even when its end faces differ by more than the local angle limit. Comparison uses a `1e-8` cosine tolerance for native precision. Boundaries and disconnected vertex fans never create extra adjacency; invalid disconnected fans sharing a vertex reject before editing.

By default the boolean edge channel `sharp_edge` supplies sharp marks. `sharpEdges` explicitly overrides it with an edge-key dictionary of booleans; `{}` ignores all stored marks for this operation. This connected-group rule differs from the older `Mesh:recalculateNormals` routine's per-reference-face angle filtering. The existing method retains its previous behavior; callers opt into this module deliberately.

`weighting` accepts `uniform`, `area`, `angle` or `areaAngle` (default). Corner angles use the full polygon interior angle, including reflex angles above pi. For each contribution, the geometric weight is raised to `power` (default 1, range 0–16), then multiplied by `faceWeights[faceId]` (default 1, nonnegative). In `areaAngle`, both area and angle factors are raised to the power. Logarithmic weight scaling prevents intermediate area/multiplier overflow. A zero power gives uniform geometric weights while retaining explicit face multipliers.

`faceStrength[faceId]` supplies a finite priority rank (default 0). Only faces at the maximum rank in a smoothing group contribute; all corners in the group receive the result. Zero multipliers remove a contribution but do not change the selected priority rank. Every group must have positive total weight. A cancelling direction sum rejects by default; `zeroSum="face"` explicitly permits a per-face normal fallback and increments `report.zeroSums`. The fallback can leave a shading discontinuity inside that group. The report's `fans` lists the deterministic groups by `"face:corner"` keys.

`Normals.average(mesh, options)` uses the same groups, weights and priorities, averaging existing custom corner normals instead of geometric face normals. Missing corner normals fall back to their face normal. It supports smoothing custom edits while preserving declared boundaries. `recalculate` with `angle=0` produces flat normals at noncoplanar edges; use `average` when the values being merged should remain custom.

## Masks, explicit values and directional edits

All edits accept a corner dictionary `mask`: omitted means all corners; a provided dictionary gives zero weight to missing keys. Values are booleans or finite numbers in `[0,1]`. `mix` (default 1) multiplies the mask. A partial edit normalizes the linear blend between the source and requested direction. An antipodal blend that cancels rejects rather than silently choosing an arbitrary direction. Groups and source data are still validated/computed before masked writes; a mask is not an input-validation bypass. `report.changedCorners` counts writes, even if a resulting value equals its previous value.

- `Normals.set(mesh, values, options)` assigns a dictionary of explicit corner vectors, keyed by `"face:corner"`. Only supplied keys are candidates for editing. Values must be finite/nonzero and are normalized with scalar scaling that also handles very large or very small finite vectors.
- `Normals.direction(mesh, direction, options)` aims selected corners in one constant direction.
- `Normals.point(mesh, target, options)` aims from each corner's vertex toward `target`, or away when `direction="away"`. A selected vertex coincident with the target rejects unless `coincident="keep"`; that option preserves its normal and counts `coincidentCorners`.
- `Normals.rotate(mesh, rotation, options)` applies a CFrame's rotation to source normals. CFrame translation has no effect.
- `Normals.flip(mesh, options)` negates source shading normals. Face winding and geometric volume remain unchanged.

When a written corner already has an intrinsic tangent, it is reprojected onto the new normal plane and normalized. A parallel tangent uses a deterministic orthogonal fallback and increments `tangentFallbacks`. The existing tangent sign remains unchanged. This preserves an orthogonal shading frame; regenerate UV tangents explicitly when the frame should be recomputed from texture derivatives. Generic typed Vector3 channels are not implicitly treated as normals or rotated.

`Normals.markSharp(mesh, edges, options)` writes the boolean edge channel `sharp_edge` using an explicit edge-key/boolean dictionary. It supports clearing false overrides even when the channel's default is true. It normally recalculates normals with the provided weighting options; `recalculate=false` changes only the sharp metadata, preserving existing custom normals and tangents. Marking/clearing edges does not duplicate geometry vertices. Clearing marks with `recalculate=false`, followed by `Normals.average`, merges existing custom directions using the new groups.

## UV tangent construction

`Normals.tangents(mesh, options)` derives intrinsic `tangent` and `tangentSign` at face corners from triangulated geometry and UV derivatives. Existing normals are normalized; missing ones use geometric face normals. Every corner must have finite intrinsic `uv`, or `uvChannel` may name a typed corner Vector2 channel instead. Choosing a typed channel does not overwrite intrinsic UVs.

Triangle derivative directions contribute with their geometric triangle corner angle. Contributions join only inside a connected smoothing group when the native corner normal, UV and handedness match exactly. UV seams, normal splits and mirrored UV handedness remain separate. The accumulated tangent is projected onto the corner normal plane and normalized. The bitangent convention is `normal:Cross(tangent) * tangentSign`, with signs `-1` or `1`. This is the package's angle-weighted derivative algorithm; it does not claim bit-for-bit agreement with an external tangent standard.

`uvTolerance=0` is an absolute determinant threshold for degenerate UV triangles. Such triangles are skipped and counted in `degenerateUVTriangles`. An undefined remaining tangent rejects unless `degenerate="fallback"`; the explicit fallback uses a deterministic orthogonal frame and increments `fallbackCorners`. `report.complete` is true only when neither skipped UV triangles nor fallback corners occurred. A single polygon corner spanning incompatible mirrored handedness always rejects: split that polygon into faces with separate corner data before generating tangents.

Tangent generation accepts only boolean/zero/one masks and `mix=1`, because handedness is discrete. A masked write replaces the complete frame. Its report includes `groups`, `changedCorners`, skipped/fallback counts and `complete`. Typed attributes and original UVs are preserved. Tangent fields persist in the package mesh/checkpoint; the Roblox adapter exports native normals and UVs, while native EditableMesh does not receive an explicit custom tangent channel through this adapter.

## Bounds and verification

Normal edits pass optional `minimumFaceArea` through to mesh validation (default `1e-12`); zero permits positive small faces without disabling topology or attribute validation. Connectivity uses `maxElements=2000000`. `maxWork=5000000` bounds normal fan visits/reductions, tangent searches and accumulation stages; `checkpoint` can yield or throw. Tangent polygon triangulation uses `maxFaceVertices=2000` and `maxFaceWork=5000000`. Shared topology validation also runs, and its allocation is bounded by the input connectivity limit. `markSharp` performs a metadata stage followed by recalculation unless disabled. All failures are transactional and create no native instances.

Tests cover independent anisotropic-box normal formulas, smooth cylinder sides with flat caps, reflex polygon weighting and triangulation equivalence, face priorities/multipliers, sharp defaults/overrides, masks, extreme finite vectors, point/rotation/flip edits, cancellation, invalid fans, source-data preservation, UV mirroring/folds/degeneracy, typed UVs, tilted frames, scale/translation, and custom corner normals through a native EditableMesh roundtrip. The `WeightedNormals` example composes weighted normals, tangent frames and radial edits. Operators that change geometry elsewhere in the library may recalculate normals; apply these shading edits after the final geometric operation when their custom directions must survive.
