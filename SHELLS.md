# Sharp shell joins and thickness diagnostics

`Modifiers.shell(mesh, thickness, options)` returns `result, report`. It creates two offset skins, reverses the inner skin's winding, and closes every source boundary edge with a rim. Positive thickness and `offset` in [-1,1] place the skins at signed target distances `thickness*(offset+1)/2` and `thickness*(offset-1)/2`. Offset zero is centered; -1 and 1 place the added thickness on one side. All work uses the mesh's coordinates. There is no scene mutation or asset publishing.

```lua
local shell, report = E.Modifiers.shell(sheet, 0.2, {
    join = "miter",
    offset = 0,
    maxOffsetError = 0.00001,
    miterLimit = 4,
})
assert(report.complete, report.reason)
```

The source must have valid consistently wound manifold topology, at least one face, and an incident face at every vertex. Disconnected components, inward-oriented closed components, open sheets and holes are supported. Nonmanifold branches and inconsistent winding must be repaired before this operator. The result and all transferred data are independent of the source; failures and cancellation leave the source unchanged.

## Join calculation

`join="miter"` is the default. At a source vertex, the operator solves `n_f · d ≈ 1` for every incident face's unit normal, using the minimum-norm weighted least-squares displacement d. A scalar 3×3 symmetric eigensolve handles planar fans, two-plane edges and fully constrained corners without inventing a tangential displacement in unconstrained directions. `rankTolerance=1e-12` is the relative eigenvalue cutoff, required to lie in (0,1). Plane normals are normalized in scalar arithmetic. `report.ranks[1..3]` counts the solved vertex ranks.

`joinWeighting="angle"` uses each face's interior corner angle, including reflex corners, and is invariant to subdivision of a planar face into triangles within numerical precision. `"uniform"` weights incident faces equally. Where all offset planes have a common intersection, the solution reproduces their miter up to native precision. At an overconstrained high-valence vertex there may be no exact intersection. The operator keeps the least-squares solution and measures its error; it does not silently describe that corner as constant-thickness geometry.

Miter faces must be planar within `planarityTolerance=max(thickness*1e-4,1e-6)` in position units. The measurement is the greatest source corner distance from the plane through the face's first corner with its area normal. `maximumSourcePlanarityError` records it. Use `Topology.triangulate` explicitly before shelling a nonplanar polygon mesh. Increasing this tolerance accepts a less planar source; it does not change the representative face plane or add adaptive geometry.

The two output positions are `p + d*sideDistance`, converted directly to native Vector3. For each source face/corner and each skin, the operator then measures `abs((outputPosition-sourcePosition)·faceNormal-sideDistance)`. `maximumOffsetError` is the maximum of those actual native-coordinate residuals. `maxOffsetError=max(thickness*0.05,1e-6)` is the default acceptance limit in position units; supply a tighter explicit limit for dimension-sensitive work. This is a face-normal offset measurement, not a global minimum-distance or volumetric wall-thickness guarantee. It also detects offsets lost to large-coordinate rounding.

`miterLimit=4` bounds the ratio `|d|` of displacement length to requested signed plane offset. Exceeding it makes the result incomplete. Miters are not clamped, since clamping would change the requested thickness. `maximumMiter` and `miterLimitExceeded` expose the largest ratio and number of exceeding vertices. A very acute corner may require a larger limit, a smaller thickness to avoid collisions, or a separate bevel/edit to change the source geometry.

`join="normal"` uses the earlier area-weighted averaged normal with unit displacement. It reports the same measured face-offset residual, but that mode does not gate completion on `maxOffsetError`: reduced face-normal thickness at sharp corners is part of its stated algorithm. The other requested geometry checks still apply.

## Geometry checks and incomplete output

The operator validates output topology, requires a closed result, and checks that each mapped skin face retains the expected orientation relative to its source. Each closed source component also receives an independent signed-volume comparison for both mapped skins. This detects an inner shell that has passed through and inverted its source even when the two skin boundaries no longer intersect. `componentVolumes` records each component's source, top and reversed-bottom signed volumes; `closedComponents` and `orientationFailures` report the checks. Signed volumes use a local origin. These checks do not prove that every local neighborhood remains embedded.

`checkIntersections=true` is the default for `shell`. A complete, intersection-free input scan is required. The output receives a separate bounded self-intersection scan, including unexpected contacts and coplanar overlaps; ordinary shared topology is excluded. `inputIntersections` and `outputIntersections` contain the [Intersections](INTERSECTIONS.md) reports. Input defects or an incomplete input scan throw. An output defect or incomplete output scan prevents completion. `intersectionOptions` supplies the scan's budgets and callback; its work budget is separate from the shell construction budget. Disabling this check sets `intersectionChecked=false` and removes that gate; a completed result then makes no global intersection claim.

By default any incomplete output throws. `requireComplete=false` instead returns the constructed mesh with `complete=false` and `reason`, for inspection or further repair. Such output can be invalid, overlapping, inverted, or outside the requested error/length limits. This option does not bypass malformed-input, source-planarity, source-intersection, allocation, cancellation or nonfinite-coordinate errors. Check completion before using a result as a valid solid.

`complete=true` means the requested checks passed, including the selected mode's error rules. It does not establish an exact CAD offset, a minimum separation between nearby surfaces, collision clearance under later changes, or a general nonmanifold thickening algorithm. Audits use exact predicates on the returned native positions; construction and numerical solves use floating-point coordinates.

## Data, shading, budgets and compatibility

Vertex, edge, face and corner channels transfer through explicit correspondence. Both skins duplicate source skin weights and groups. Rim faces/corners inherit their source boundary face and corner data; newly generated vertical edges use channel defaults. Reversed inner corners invert stored tangent handedness. Other stored custom vectors remain data, rather than receiving an automatic geometric transform. UV seams remain per-corner. `top[oldVertexId]` and `bottom[oldVertexId]` map to the returned vertex IDs; `inputMaps` contains all four transfer domains.

Normals are recomputed. `normalAngle` defaults to 60 degrees in radians for miter joins, retaining sharp shading at larger corners, and to the earlier smooth-normal behavior for normal joins. Pass an explicit angle when the model needs different shading. Apply custom normals/tangents afterward when required.

Defaults are `maxVertices=500000` output vertices, `maxFaces=500000` output faces, and `maxWork=2000000` counted construction/solve/check visits. Mesh validation, normal recalculation and intersection audits have their own costs; these limits are not a wall-clock or total-memory guarantee. `cancelled()` and `checkpoint(progress)` can abort or yield. Construction checkpoints contain stage/work/maxWork; audit checkpoints include the audit stage and intersectionWork, and preserve any nested intersection callback.

Reports contain `complete`, optional `reason`, `join`, `validation`, `maximumOffsetError`, `maxOffsetError`, `maximumSourcePlanarityError`, `maximumMiter`, `miterLimitExceeded`, `ranks`, `orientationFailures`, `closedComponents`, `componentVolumes`, `intersectionChecked`, optional input/output audits, the correspondence maps and construction `work`.

`Modifiers.solidify(mesh,thickness,options)` retains its existing **single-mesh return** and normal-offset default. It accepts `join="miter"` to use the new corner calculation and its geometric gates, but keeps intersection scanning off unless explicitly requested. Use `shell` for its diagnostic report, default miter mode and default intersection audits. The earlier normal-only `solidify` validity gate is retained for compatibility; it is not upgraded silently to a global geometric certificate.

`ShellTests` checks independent box and folded-sheet positions/volumes, planar and sharp ranks, both corner directions, miter limits, incompatible plane residuals and least-squares balance, triangulation invariance, transformations, all typed domains, native UV/skin conversion, separate inward/outward components, consumed inner shells, shell-induced collisions, nonplanar rejection, cancellation/budgets and large-coordinate precision loss. `Examples.MiterChannel` creates a bounded, audited U-channel. The broader workflow is described in the [Blender Solidify manual](https://docs.blender.org/manual/nl/5.0/modeling/modifiers/generate/solidify.html); the original Luau algorithm and contracts above define this implementation.
