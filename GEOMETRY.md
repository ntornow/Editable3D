# Surface operations and parameterization

These Luau operators return new authoring meshes. They create no instances and do not publish assets. They complement the existing voxel remesher, topology tools and sculpt brushes.

## Polygon solid operations

```lua
local cut, report = E.Boolean.subtract(body, cutter, {
    epsilon = 0.00001,
    materialOffsetB = 2,
    maxWork = 2000000,
    maxDepth = 256,
    maxPolygons = 100000,
    yieldEvery = true,
})
```

`Boolean.union`, `intersect`, `subtract`, and `apply(a,b,operation,options)` default to polygon BSP clipping. `method="arrangement"` selects the audited winding-region method described in [BOOLEANS.md](BOOLEANS.md). Both methods now preserve typed vertex/edge/face/corner channels through explicit correspondence. The following clipping details describe the BSP method. Unlike voxel operations, they retain source surface planes and interpolate corner UVs, normals, colors, skin weights and groups. Material IDs are retained; `materialOffsetB` shifts cutter material IDs so cut surfaces can use a separate material range. Intersected surfaces inherit the originating face's material. At coincident welded vertices, vertex-level weights/groups use the first encountered source; per-corner seams remain independent. Discontinuous rig semantics between operands need deliberate reconciliation.

Inputs must be closed, oriented manifold solids with simple approximately planar faces. Reversed whole-solid winding is normalized. Intersecting shells, malformed vertex fans and self-intersections are not repaired or comprehensively detected. Point/edge-only touching can produce a nonmanifold result and reject. Empty operands follow set identities. Inputs are not mutated.

The implementation centers coordinates during clipping, splits spanning polygons, welds generated points and conforms T-junctions using a spatial point tree. Convex polygon fragments use center-fan triangulation so inserted boundary vertices remain part of both incident surfaces. Returned triangles pass `Mesh:validate()` by default; `allowInvalid=true` returns failures in `report.validation` for diagnosis. This option does not make an invalid result safe for native conversion.

The default tolerance is `max(combinedBoundsDiagonal * 1e-6, 1e-6)` in authoring units. `weldEpsilon` defaults to four times that plane tolerance to reconcile independently calculated intersections; it can be set explicitly but must be at least `epsilon`. Features approaching the weld tolerance can merge. Coordinates and interpolation use Roblox float32 vectors; this is **not an exact-predicate CAD kernel**. Work/depth/polygon limits throw rather than returning partial success. `cancelled()` is checked during clipping; `yieldEvery=true` yields at periodic work checkpoints. BSPs can be expensive on dense meshes; prefer a limited local cutter or lower-resolution authoring surface. Reports include `method`, `operation`, `complete`, `maps`, `inputMaps`, `epsilon`, `weldEpsilon`, `work`, `insertedEdgeVertices`, `validation` and `empty`. BOOLEANS.md distinguishes topology completion from optional geometric auditing for BSP.

## Local and isotropic remeshing

```lua
local detailed, report = E.Adaptive.refine(head, 0.02, {
    region = function(p) return (p - eyeCenter).Magnitude < 0.2 end,
    maxOperations = 300,
    yieldEvery = true,
})
local even, remeshReport = E.Adaptive.remesh(detailed, 0.025, {
    iterations = 3,
    reference = head,
    preserveBoundary = true,
    preserveSeams = true,
    sharpAngle = math.rad(50),
})
```

`refine(mesh,targetLength,options)` triangulates the input and bisects edges longer than `splitThreshold * targetLength` (default 4/3). `targetLength` can be a positive number or `function(position)`; `region(position)` can return a Boolean or positive numeric inclusion value. New vertices lie at edge midpoints. Both incident faces are split, including a face crossing the region boundary, to preserve conformity. Existing vertex positions and IDs remain unchanged. Corner attributes, weights and groups interpolate independently.

`remesh` additionally collapses short edges (default `collapseThreshold=0.8`), flips edges when valence error improves, and tangentially relaxes vertices (`relaxation=0.3`). It projects collapsed/relaxed vertices onto `options.reference` or the original input; `project=false` disables this. Boundary, UV/material seam and sharp-edge vertices are protected by default. `sharpAngle=false`, `preserveBoundary=false`, or `preserveSeams=false` explicitly relax those protections. Normal-flip and link-condition checks reject unsafe local collapses/flips. `minimumNormalDot` defaults to 0.2. `flip=false` disables valence flips. Normals are recomputed after remeshing.

`maxOperations` defaults to 5000 and `iterations` to 3. The budget counts splits, collapses and flips. `budgetReached` means the returned valid mesh stopped at the budget, **not** that it reached the target density. Refinement maintains edge adjacency incrementally and processes long edges through a priority queue. Collapse/flip stages rebuild topology per operation and remain more expensive on dense input. `yieldEvery=true` and `cancelled()` provide cooperative checkpoints. Relaxation is not a self-intersection solver, sharp corners may retain uneven density, seam-interior UVs are not globally reparameterized, and skin weights are interpolated rather than refitted. This is not production retopology or a sculpt stroke engine.

## Least-squares conformal UVs

```lua
local mapped, solve = E.Conformal.lscm(chart, {
    pins = {[firstBoundaryId] = Vector2.zero, [secondBoundaryId] = Vector2.new(1,0)},
    tolerance = 1e-8,
    iterations = 2000,
})
assert(solve.converged)
local atlas, charts = E.Unwrap.unwrap(mesh, seamEdges, {method="lscm", padding=0.04})
```

LSCM minimizes the area-weighted Cauchy-Riemann residual over triangulated faces. A matrix-free diagonally preconditioned conjugate-gradient solver handles the pinned normal equations. The chart must be a connected, oriented topological disk with one boundary loop and no unused vertices. At least two distinct boundary UV pins are required; when omitted, a deterministic farthest-boundary heuristic selects two. Pins are not normalized or moved. The returned UVs may lie outside `[0,1]`.

The solve returns `converged`, `iterations`, absolute/relative normal-equation residual, `conformalEnergy`, `pins`, and `distortion`. `Conformal.distortion(mesh)` reports angle deviations in radians and positive/negative/flipped/degenerate UV triangle counts. A small solver residual alone does not certify a useful texture chart. Inspect orientation, angle distortion and packing; badly conditioned charts or insufficient iterations can remain unsuitable. The default vertex budget is 20,000; `maxVertices` explicitly changes it. `cancelled()` and `yieldEvery=true` are checked periodically.

`Unwrap.unwrap(...,{method="lscm"})` first constructs charts using the existing explicit seam topology, solves each chart, fits it isotropically into its packing cell, and retains the source mesh's topology. Chart-local IDs differ from source IDs; use direct `Conformal.lscm` when specifying pins. Harmonic parameterization remains the default. For current texture-metric packing, density controls, automatic seams, angle-based charts and constrained layout relaxation, see [UV_MODELING.md](UV_MODELING.md).

## References

These inform the algorithms; no external implementation code or model data is embedded.

- [Lévy et al., Least Squares Conformal Maps](https://www.cs.jhu.edu/~misha/Fall09/Levy02.pdf): pinned least-squares parameterization.
- [Blender dynamic topology documentation](https://docs.blender.org/manual/en/3.6/sculpt_paint/sculpting/tool_settings/dyntopo.html): local subdivision/collapse concepts and detail controls.
- [Spatial data structures and BSP lecture](https://www.cs.cmu.edu/~fp/courses/graphics/pdf-6up/17-spatial.pdf): plane partitioning and solid operations.

## Core mesh precision

Data across topology changes is documented in [ATTRIBUTES.md](ATTRIBUTES.md) and [DATA_TRANSFER.md](DATA_TRANSFER.md). Local remesh and simplification preserve typed domains with seam-aware correspondence. Voxel mesh reconstruction now projects source channels, groups, skin, materials and corner fields by default and reports completion separately from geometric accuracy; `transfer=false` explicitly skips it. General `Attributes.project` supports connected source charts, domain masks, source-face selection, distance limits and unmatched reports.

Face normals accumulate centered coordinate products as Luau numbers, avoiding intermediate float32 Vector3 cross-product overflow or underflow. If the complete area vector is uncertain through cancellation, exact projected polygon-area signs supply a fallback. The returned normal remains a native Vector3; area is a number. `Mesh:validate(options)` defaults to `minimumFaceArea=1e-12`. An explicit finite nonnegative threshold controls this area policy; zero permits positive representable areas while still rejecting zero or nonfinite area. All topology and attribute checks remain enabled. Representable tiny triangles are not automatically suitable for native asset conversion.

`Mesh:faceTriangles(faceId,options)` uses exact projected orientation signs for polygon winding and ear decisions. It retains original corner indices. Simple planar polygons are the precondition; `validateSimple=true` explicitly checks nonadjacent projected edge intersections. Default budgets are 2,000 corners and 5,000,000 work units (`maxVertices`, `maxWork`); `checkpoint` can yield or throw during counted work. Nonplanar polygons still use dominant-axis projection and do not have a general nonplanar-surface interpretation.

`Mesh:volume(origin)` accumulates signed tetrahedra with centered scalar arithmetic and compensated summation. With no explicit origin, consistently oriented edge-closed meshes use a local vertex origin for translation stability; open meshes retain the world origin so separate open pieces remain additive, including UV tile partitions. Callers may supply a finite Vector3 origin when all pieces should share another reference. Only closed oriented solids have an origin-independent enclosed-volume interpretation. This improves numerical stability without claiming exact volume arithmetic.

## Exact spatial diagnostics

[INTERSECTIONS.md](INTERSECTIONS.md) documents segment/triangle queries and bounded BVH scans, including coplanar overlaps and native construction failures. Pass `checkIntersections=true` to BSP operations to require complete intersection-free input and output scans; `intersectionOptions` controls their budgets. These optional checks preserve the existing tolerance-based construction and reject unresolved geometry rather than silently accepting it.
