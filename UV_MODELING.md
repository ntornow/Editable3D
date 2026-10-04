# UV islands, measurements and packing

These headless operators work on intrinsic `face.corners[i].uv`. They complement `UV.planar`, `UV.cylindrical`, `UV.spherical`, `UV.faceCharts`, `Unwrap.unwrap` and `Conformal.lscm`. The callable baseline includes [Blender 5.0 island scaling, transforms and packing](https://docs.blender.org/manual/en/5.0/modeling/meshes/uv/editing.html). This implementation uses bounded rectangle packing and its own documented metrics; it does not reproduce Blender's solver or exact-shape packer.

```lua
local charts = E.Unwrap.unwrap(mesh, E.Unwrap.sharpSeams(mesh), {method = "lscm"})
local atlas, packing = E.UV.packIslands(charts, {
    textureSize = Vector2.new(1024, 512),
    normalizeDensity = true,
    margin = 4,
    requireComplete = true,
})
local analysis = E.UV.analyze(atlas, {textureSize = Vector2.new(1024, 512)})
assert(analysis.complete and analysis.overlapFree and analysis.consistentOrientation)
```

`Examples.UVAtlas` produces a six-chart rectangular box atlas. No API creates scene instances, sends HTTP requests or publishes assets.

## Discovery and selection

`UV.islands(mesh, options?) -> islands, report` groups polygon faces through manifold mesh edges. An edge joins its two faces only if both endpoint UVs match **exactly** and the edge is not explicitly cut by `options.seams[edgeKey] == true`. A shared UV point or coincident disconnected geometry does not join islands. There is no proximity welding. Materials, normals, typed channels and existing `uv_seam` attributes do not implicitly alter connectivity; pass an explicit edge boolean set to cut additional edges.

Input geometry must have finite vertices, consistent winding, manifold edges/vertex fans, no duplicate faces or zero-length edges, and triangulatable simple projected polygons. Unused vertices are retained. A UV chart may have holes, handles or several boundary loops; chart discovery and transforms do not require the disk topology used by the existing unwrap solvers. Geometry intersection detection is separate.

Islands are sorted by `id`, the minimum source face ID in that component. Each entry contains `faces`, `{face, corner}` references, triangle records, `minimum`/`maximum` numeric `{u,v}` bounds, `uvArea`, `surfaceArea`, `density`, orientation counts, `mixedOrientation` and missing/nonfinite UV corner references in `missing`. Bounds are absent if no finite corner exists. `report.faceToIsland` maps every source face; `report.seams` marks mesh boundaries, explicit cuts and discontinuous/missing UV edges. An explicit cut can remain inside one connected island when another path joins its sides.

`options.islands` is a boolean set keyed by those stable IDs. Omit it to select all, or use `{}` to select none. Discovery and analysis still describe the whole mesh and include an island's `selected` flag. Editing acts on whole selected islands. IDs refer to the input and may change if an edit subsequently makes two UV components exactly continuous.

`complete` for discovery means all corners have finite UVs. `requireComplete=true` rejects missing/nonfinite UVs. Missing data is otherwise reported, not replaced with invented UV coordinates. Density/area totals for an incomplete chart include only available UV triangles and should not be interpreted as a complete measurement.

`UV.seamsFromIslands(mesh, options?) -> mesh, report` writes the discovered edge cuts to a boolean edge channel named `options.attribute` (default `uv_seam`). It replaces that channel's values on all edges, including explicit `false` values when its existing default is `true`; its schema must already be edge/boolean if present. It preserves all other channels and geometry. The `islands` selection does not restrict this whole-mesh seam discovery. `complete` and strict missing-UV behavior match discovery.

## Geometry, distortion and overlap diagnostics

`UV.analyze(mesh, options?) -> report` uses the **actual geometric face triangulation**, including concave polygons. Each triangle records its face, three corner indices and vertex IDs; native UV coordinates and bounds; exact orientation sign; numerical UV and surface areas; and minimum/maximum singular stretches of the differential from an orthonormal triangle frame to the texture metric.

`textureSize` defaults to `Vector2.one`. Each dimension must be an integer in `[1,65536]`. With `(width,height)`, metric coordinates are `(u*width,v*height)` and stretches/density are in texels per geometry unit. This accounts for non-square images. With `(1,1)`, they are in UV units. Density is `sqrt(sum(abs(UV triangle area))*width*height / sum(surface triangle area))`; this measures area scale, not uniformity within an island. `anisotropy` is maximum/minimum singular stretch, with infinity for a degenerate map. `maximumAnisotropy` summarizes available triangles. Areas and stretches are scalar-double numerical measurements, not certified error bounds.

Diagnostics distinguish:

- `positiveTriangles`, `negativeTriangles` and `degenerateTriangles`: exact signs in stored `(u,v)` order relative to the ordered geometric triangle. A uniformly negative island is mirrored; `mixedOrientationIslands` contains islands with both signs. The sign convention is mathematical UV orientation, independent of an image display's downward V axis.
- `consistentOrientation`: complete UVs, no zero-area triangles and no mixed signs inside any island. This alone does not establish injectivity or absence of overlaps.
- `allPositive`: complete UVs and exclusively positive triangles.
- `missingCorners` and `complete`: whether every corner was available for analysis. A complete diagnostic report may describe flipped, degenerate or overlapping UVs.
- `overlapChecked` (default true), `overlapCount`, `overlapFree`, `internalOverlaps` by island, and `overlaps` records containing global triangle indices plus face/island IDs. Disable scanning with `checkOverlaps=false`; then `overlapFree` is absent. Degenerate triangles do not have positive area, so use the degeneracy count as well as `overlapFree` when validating a map.

Overlap decisions use the separating axes of both nondegenerate triangles and the package's exact native-coordinate orientation signs. A positive-area intersection exists exactly when neither triangle has an edge line with all vertices of the other in the exterior closed half-plane. This includes containment, identical triangles, folds within one face and overlap across islands. Mere shared edges or points are excluded; no floating intersection coordinates or area tolerance enter this decision. A sorted X-bound scan excludes disjoint pairs before exact checks. Worst-case pair work is quadratic and subject to `maxWork`.

`maxOverlaps` (default 10000, nonnegative integer) caps stored pair records, not the scan or count. `overlapsTruncated` explicitly reports omitted records. `requireComplete` requires all UVs, not an overlap-free or positive map; inspect those separate flags.

## Whole-island edits

`UV.transformIslands(mesh, transforms, options?) -> mesh, report` accepts a dictionary keyed by selected island IDs. Each value has optional `translation: Vector2`, `rotation` in radians, nonzero `scale` as a number or `Vector2`, and `pivot: Vector2`. Defaults are zero translation/rotation, unit scale and the island's UV bounding-box center. Scaling occurs about the pivot along U/V, followed by rotation and translation. These transforms operate in UV coordinates; `textureSize` only changes the error/density reporting metric. Negative scales deliberately support mirroring.

`UV.equalizeDensity(mesh, options?) -> mesh, report` uniformly scales each selected island about its bounding-box center. `options.density` is a positive target in the texture metric. If omitted, it is `sqrt(total selected texture area / total selected surface area)`, preserving total selected absolute UV triangle area before rounding. It does not make individual triangles isometric, remove existing folds or preserve space between islands; packing can follow. `report.targetDensity`, each island's `expectedDensity` and measured output `density` distinguish the target from native rounding.

Both edit APIs require complete, nondegenerate selected UV charts. They snapshot meshes, selections, transform dictionaries and options before callbacks. Positions, topology, stable IDs, normals, materials, groups, skin weights and every typed attribute domain remain unchanged. Changed UV corners lose intrinsic `tangent` and `tangentSign`; regenerate tangent frames when needed. Typed UV-like channels are independent data and are not modified.

`report.complete` means finite output and each output triangle retaining the expected exact orientation after the prescribed transform, including intentional reflection. A finite but rounded/collapsed result is returned with `complete=false`, `reason="nativeOrientation"` and per-island `nativeOrientationChanges`. Native overflow returns an unchanged clone with `reason="nativeOverflow"`. `requireComplete=true` throws on either condition. `maximumNativeError` is the measured distance between constructed native corners and the computed scalar-double targets; it is not an outward error bound. Transform completion does not claim absence of global overlaps.

## Density-aware packing

`UV.packIslands(mesh, options?) -> mesh, report` packs selected, unpinned islands into the UV rectangle `minimum` to `maximum` (defaults `(0,0)` and `(1,1)`). The rectangle can target a different texture tile or several tiles. Unselected islands and those in the boolean `pinnedIslands` set stay fixed and reserve their full UV bounding boxes. Obstacles outside the region are handled by their intersection with free rectangles. Existing overlaps or out-of-region UVs between fixed islands are left unchanged.

Packing options:

| Option | Meaning |
| --- | --- |
| `textureSize` | Integer image dimensions; rotation and rectangle fitting occur in this texture metric |
| `margin` | Metric units reserved on **each** island side and the region border; movable island pairs and fixed obstacles receive at least `2*margin` axis separation; default 0.5% of the region's shorter metric side |
| `rotate` | Default true; allows zero or 90-degree rotations in the texture metric, preserving texel angles on non-square textures |
| `normalizeDensity` | Default false, retaining relative island scale; true first normalizes each movable chart's density, then applies one common atlas scale |
| `scale` | Optional fixed positive common scale; omission searches for a fitting scale |
| `iterations` | Scale search iterations, default 32, range 1–64 |
| `maxIslands` | Input island count limit, default 2000 |
| `maxFreeRectangles` | Limit on intermediate free-rectangle allocation, default 4096 |

The deterministic heuristic sorts rectangles by area, longest side and island ID. It scores placements by short-side fit, long-side fit, Y, X and rotation. Every placement splits intersecting free rectangles and removes contained duplicates. The automatic scale search uses a rectangle-area upper bound and bounded bisection, retaining observed successful placements. Feasibility of the heuristic is not assumed monotone and no optimality or infeasibility proof is claimed. Holes and concavities inside island bounding boxes are unused; tight shape packing remains an optional extension rather than a guarantee of this API.

Movable charts must have complete, nondegenerate UVs. An input internal positive-area overlap or mixed orientation returns `reason="foldedIsland"`; disconnected islands may overlap before packing. Missing UVs on any fixed or movable chart are invalid input because obstacle bounds would be incomplete. Existing mirrored charts may pack while retaining their orientation.

An additional native-scale clearance aids construction. After constructing float32 UVs, packing checks:

1. Every moved triangle has its original exact orientation.
2. Every moved native bounding box lies inside the target with the requested border margin.
3. Every pair involving a moved island has the requested axis gap, including fixed obstacles.
4. Every moved island is free of internal positive-area triangle overlaps.

Texture dimensions are bounded integers, so native UV times image dimension is exactly representable in binary64. Outward interval subtraction supplies lower bounds for the stored-coordinate margins. `marginCertified=true` means these margin checks passed for pairs involving moved islands; it says nothing about relationships among fixed islands. A no-movable-islands call is a successful unchanged result and the margin assertion is vacuous.

Packing is transactional: any failed search or native audit returns an unchanged clone, `complete=false`, `applied=false` and a reason (`noPlacement`, `nativeBorderMargin`, `nativeIslandMargin`, `nativeInternalOverlap`, or a native edit reason). Attempted placements/native edit measurements may remain in the report for diagnosis. Successful packing includes `applied=true`, common `scale`, per-island applied scales/rotations in `placements`, `attempts`, `nativeEdit`, counts and work. `requireComplete` throws instead of returning incomplete output. Hard budgets, cancellation, invalid options and malformed geometry always throw.

## Limits and verification

Common defaults are `maxVertices=250000`, `maxFaces=250000`, `maxCorners=1000000`, `maxFaceVertices=2000`, and `maxWork=20000000`. Input sizes are checked before cloning. Counted visits cover core input sizes, edges/corners/triangles, face triangulation, overlap comparisons, rectangle splits/pruning/search, and native audits; sorting, table copies, basic topology analysis and exact-predicate internals are bounded by input limits but do not represent individual work units. These are allocation/count limits, not wall-time or byte guarantees.

`cancelled()` is checked during visits. `checkpoint(status)` receives fresh `{stage,work}` records at major stages (`begin`, `islands`, `analysis`, `packedRectangles`, `edited`, `packVerified` as applicable); it cannot mutate captured input through those records. Callback failures propagate. No scene mutation occurs.

The suite covers analytic affine singular values/density, non-square texture metrics, exact-touch versus positive-area overlap, mirrored/folded/missing UVs, concave polygons, deterministic rectangle layouts, pins/obstacles, native rounding, every typed domain, skin/groups, sparse IDs/transforms/extreme UV scales, input snapshots, cancellation/budgets and native UV/normal conversion. The independent Python `Fraction` polygon-clipping generator supplies 320 triangle pairs across five scales and common translations; reversal/swap variants exercise 1,280 overlap decisions in Studio.

Angle-based unwrap and broader UV relaxation remain tracked in MODELING_PARITY.md. Island edits do not replace a parameterization solver, weld UV seams or optimize arbitrary concave packing.

## Automatic disk-chart seams

`Unwrap.autoSeams(mesh, options?) -> seams, report` constructs useful cuts from geometry and explicit features. It returns an edge boolean set ready for `Unwrap.unwrap`, with no changes to source positions, topology, UVs, intrinsic data, typed channels, materials, skin or groups. It handles closed surfaces, genus, holes, concave polygons and disconnected components by constructing cut charts with verified disk topology. It does not promise a distortion-optimal cut graph or a successful numerical parameterization under arbitrary settings.

```lua
local seams, cuts = E.Unwrap.autoSeams(mesh, {
    angleLimit = math.rad(45),
    normalCone = math.rad(60),
    maxChartFaces = 128,
})
local flat, unwrap = E.Unwrap.unwrap(mesh, seams, {method = "lscm"})
for _, chart in unwrap.reports do assert(chart.converged) end
local atlas, packing = E.UV.packIslands(flat, {normalizeDensity = true})
assert(packing.complete)
```

`Examples.AutomaticAtlas` applies this workflow to a closed torus. The original unwrap solver's convergence and UV quality remain separate checks; a disk-topology certificate alone does not imply low distortion, valid native triangle orientations or absence of UV overlaps. Wide angle/cone limits can produce a single chart of a whole closed object with substantial distortion.

Controls and defaults:

| Option | Behavior |
| --- | --- |
| `angleLimit=pi/3` | Force a seam when neighboring polygon normals exceed this dihedral angle |
| `normalCone=pi/2` | Every face of a grown chart must be within this angle of its seed face normal |
| `maxChartFaces=256` | Maximum polygon faces in each grown chart |
| `seams` | Explicit source edge boolean set; true edges stay cut |
| `seamAttributes` | Additional edge boolean/numeric channel names; default protection always includes existing `uv_seam`, `sharp_edge` and `subdivision_edge_sharpness`; true or positive values force cuts |
| `splitMaterials=true` | Force cuts between different face materials |
| `preserveUVSeams=false` | If true, differing stored UVs at either shared-edge endpoint force a cut; otherwise existing corner UV coordinates do not guide automatic cuts |
| `recoverCycles=true` | Remove additional cuts when a fresh chart audit accepts the new corner quotient |
| `maxClosureTests=1000000` | Soft cap on cycle-recovery candidates; zero retains the initial forest cuts |

Angles lie in `[0,pi]`. Normals use scalar-double Newell sums; angle comparisons use a `2^-45` dot-product allowance. These are numerical geometric criteria, including at an angle limit of zero. Polygon normal variation, rather than a triangulated approximation's per-triangle normals, guides polygon chart growth.

Edges eligible for retention are scored by `edgeLength*(1+normalDot)/2`. The deterministic descending order uses numeric endpoint IDs to break exact ties. Starting at the lowest unassigned face ID, a priority frontier attaches unassigned faces through one retained edge while respecting the seed-normal cone and chart size. This creates a forest in the face-adjacency graph; gluing polygon disks along those tree edges yields initial disk charts. Strongly curved or short edges tend to remain cuts. This is a geometric heuristic, not a global minimum-seam-length optimization; floating changes near score ties can change cuts under general transforms.

Cycle recovery then tries additional eligible edges within each chart. A private corner union groups only source corners linked through retained edges, constructing the actual cut mesh. Each accepted quotient must be connected, consistently oriented and manifold, have Euler characteristic one and exactly one boundary loop of at least three edges. A cut whose two endpoint corner groups become identical on both sides cannot be represented by the package's endpoint-pair edge identity. If that cut is protected, recovery rejects the candidate. Otherwise it may simultaneously remove those now-redundant cuts; their endpoint equivalence is already established, so doing so does not further change the quotient. The final charts are rebuilt and audited again. This protects isolated interior feature cuts from disappearing during topological closure.

The source geometry has the same oriented-manifold, finite, nondegenerate and projected-simple polygon requirements as the island APIs. Source mesh self-intersections are not checked. The cut-chart audit is topological and does not flatten or modify the geometry. In particular, distinct chart vertices may retain identical source positions along opposite sides of cuts.

`report.complete=true` means all source faces belong to audited disk charts and every protected edge remains represented as a cut. Hard limits, invalid inputs and cancellation throw. Cycle recovery is an optional simplification: `closureLimited=true` can accompany a complete valid result when its soft cap is reached. Reports contain:

- `charts`: entries with seed/minimum face `id`, source `faces`, cut-chart vertex/edge/boundary counts, `eulerCharacteristic=1`, `boundaryLoops=1` and measured `maximumNormalAngle` from the seed;
- `faceToChart`, `closureTests`, `recoveredEdges`, `closureLimited` and counted `work`;
- `reasons` for retained cuts: `boundary`, `explicit`, `attribute`, `angle`, `material`, `uv`, `chartBoundary` or `cutGraph`.

An empty mesh returns empty cuts/charts and a complete result. All meshes and option tables are snapshotted before user callbacks. Common source/work limits match the island APIs; `maxCharts` defaults to `maxFaces`. The chart-size limit bounds each reconstruction, but many cycle candidates can still require substantial work. Counted visits cover source sizes, geometric loops, feature checks, heap operations, chart corner/edge construction and audit element counts; sorting, copying and connectivity internals are not individual work units. `cancelled()` is checked during visits, and fresh `checkpoint({stage,work})` records are emitted at `begin`, `chartForest` and `seamsVerified`.

Eighteen cases verify planar cycle recovery against independent Euler counts, tree-only/soft-limit output, represented hole and closed sphere/torus cuts, normal cones and chart sizes, isolated feature preservation, boolean/numeric/custom fields, material/UV delimiters, disconnected and concave inputs, complete source-data retention, snapshots, transforms and sparse IDs, cancellation/budgets, polygon/triangle versions, and an automatically seamed torus atlas through native conversion.

## Angle-based charts and atlases

`Unwrap.angleBased(mesh, options?) -> mesh, report` flattens a single connected disk. It uses the mesh's actual geometric face triangulation, including concave polygons, without changing source topology. Oriented manifold geometry, one boundary loop and Euler characteristic one are required; unused vertices are retained. Use `Unwrap.autoSeams` and the atlas call below for closed or holed objects.

```lua
local flat, chart = E.Unwrap.angleBased(disk, {
    pins = { [boundaryVertexA] = Vector2.zero, [boundaryVertexB] = Vector2.xAxis },
    requireComplete = true,
})

local seams = E.Unwrap.autoSeams(mesh)
local atlas, report = E.Unwrap.unwrap(mesh, seams, {
    method = "angle",
    textureSize = Vector2.new(1024, 512),
    packing = { margin = 4 }, -- texels in this texture metric
    requireComplete = true,
})
```

The angle-space formulation is informed by [Sheffer et al., ABF++](https://www.cs.ubc.ca/~sheffa/papers/abf_plus_plus.pdf). This implementation has its own bounded matrix-free solver and conditioning choices; it does not implement the paper's hierarchical acceleration or claim a global optimum.

For each geometric triangle corner, `beta` is its original 3D angle and `alpha` is its unknown planar angle. The objective is `sum(((alpha-beta)/max(beta,minimumAngle))^2)`. Triangle sums equal pi; interior vertex sums equal 2*pi. Each interior wheel also requires equality of the products of sines of opposite ordered angles. The implementation evaluates the equivalent difference of their geometric means using mean log-sines, avoiding product underflow at high valence. Triangle and vertex equations are divided by pi and 2*pi respectively. Reported constraint residuals refer to these normalized equations, including the geometric-mean wheel equation.

Each iteration solves an equality-constrained quadratic approximation with an analytic constraint Jacobian, then uses an L1 merit function and a bounded positive-angle line search. Matrix-free Jacobi-preconditioned conjugate gradients solve the multiplier system. A separate least-squares conformal reconstruction uses the optimized triangle shapes and two fixed coordinates. Both linear solvers refresh the actual residual periodically and check it again before reporting convergence. Constraints, derivatives, energies and angle measurements are scalar-double numerical quantities, not interval-certified bounds.

`pins` must contain exactly two distinct boundary vertex IDs with finite, distinct `Vector2` values. With no pins, two deterministic far-apart boundary vertices fix a unit span in the texture metric. The reconstructed chart is mapped by a similarity in `(u*width,v*height)` to the requested pins; pins retain their exact native values. `textureSize` defaults to `(1,1)`, with integer dimensions in `[1,65536]`. Pins fix translation, rotation and scale; they do not impose additional boundary shapes.

| Option | Default and meaning |
|---|---|
| `minimumAngle` | `1e-8` radians; strictly between zero and pi/3; optimization maintains angles strictly inside `(minimumAngle,pi-minimumAngle)` |
| `iterations` | 50 accepted-step limit, integer `[0,500]` |
| `constraintTolerance` | `1e-8`, maximum absolute normalized constraint residual |
| `stationarityTolerance` | `1e-8`, maximum quadratic-step magnitude divided by the corresponding objective weight |
| `lineSearchSteps` | 32 trials per step, integer `[1,64]` |
| `linearTolerance`, `linearAbsoluteTolerance`, `linearIterations` | `1e-10`, `1e-12`, 4000 for each multiplier solve |
| `reconstructionTolerance`, `reconstructionAbsoluteTolerance`, `reconstructionIterations` | `1e-10`, `1e-12`, 4000 for UV reconstruction |
| `reconstructionAngleTolerance` | `1e-5` radians, maximum measured angle difference between stored UVs in the texture metric and optimized triangle angles |
| `checkOverlaps`, `maxOverlaps` | Scan by default; optional record-storage cap retains full counting, as in `UV.analyze` |

All tolerances must be finite and positive. Linear iteration limits are nonnegative integers. A zero step/iteration budget can still converge when the corresponding initial state already meets its equations. Infeasible minimum-angle constraints, poorly conditioned charts or strict tolerances can return incomplete results. The solver does not replace requested constraints with relaxed values.

The chart report contains `targetAngles`, `optimizedAngles` and matching `triangles` records with source `face`, `corners` and `vertices`; `pins`; `angleOptimization` with energy, normalized constraint residual, relative step, history, accepted steps and linear diagnostics; and `reconstruction` with equation energy and actual residual. `maximumNativeError` measures conversion displacement in the texture metric and is not an outward error bound.

`complete` requires all of the following:

1. `angleConverged`: constraint and step tests pass after a converged multiplier solve.
2. `reconstructionConverged`: the separate linear reconstruction meets its residual threshold.
3. `nativeOrientation`: every stored UV triangle has a strictly positive exact orientation sign.
4. `maximumAngleResidual <= reconstructionAngleTolerance`: measured native texture-metric angles match the optimized angles.
5. If requested, `overlapFree`: the exact positive-area triangle overlap scan finds no overlap.

Local positive orientation alone does not prevent global overlap. Disabling `checkOverlaps` omits `overlapFree` and weakens the completion contract accordingly. The angle residual measures reconstruction accuracy, not distortion from the original surface; objective energy and target/optimized angles describe the latter. No successful report promises isometry, optimal cuts, uniform density inside each chart, a global energy minimum or absence of geometric self-intersections in the source.

`reason` distinguishes `angleOptimization`, `reconstructionSolve`, `nativeOrientation`, `nativeAngleResidual` and `uvOverlap`. Subreports distinguish linear, line-search and iteration failures. A finite approximate chart is returned on ordinary nonconvergence; nonfinite reconstruction or native overflow returns an unchanged clone with `reconstructionNonfinite` or `nativeOverflow`. `requireComplete=true` throws on any incomplete result. Empty inputs return an identity result and do not have iteration subreports.

### Multi-chart angle unwrap

`Unwrap.unwrap(mesh, seamSet?, {method="angle", ...})` reconstructs seam-separated corner charts, runs the angle solver on each, packs them with `UV.packIslands`, and repeats orientation, angle and overlap audits on the **final stored atlas UVs**. Each cut chart must be a representable disk; a cut whose endpoint identities collapse across both sides is rejected. With `seamSet=nil`, an edge-boolean channel named `seamAttribute` (default `uv_seam`) supplies cuts. Existing intrinsic UV discontinuities do not automatically supply cuts to this call.

Single-chart solver options also apply here, except `pins` is forbidden: use `Unwrap.angleBased` for explicit pins. `packing` supplies `UV.packIslands` options, with the root `textureSize` and actual cuts enforced. `normalizeDensity` defaults true. `padding`, when supplied, becomes the packing margin only if `packing.margin` is absent. Packing operates on the newly constructed charts; use a subsequent packing call when preserving an already authored fixed atlas is required. The harmonic and LSCM methods retain their existing regular-grid layout behavior.

The atlas report contains `charts` (count), per-chart `reports`, `chartMaps` with source IDs and corner correspondence, `seams`, `packing`, `nativeAudit`, `work`, `complete` and `applied`. Any failed chart, packing result or final audit returns the unchanged source clone with `applied=false`, and `reason` respectively `chartUnwrap`, `packing` or `nativeAtlasAudit`; `failedChart` identifies a failed chart by its minimum source face ID. Strict mode throws. Empty input is a complete identity with `applied=false`.

### Data, limits and verification

Only intrinsic corner UVs change. Changed UVs clear `tangent` and `tangentSign`; positions, IDs, polygon order, normals, materials, all typed channels, skin weights and groups remain unchanged. Meshes, pins, seam sets and nested option tables are captured before callbacks.

Angle operations default to `maxVertices=20000`, `maxFaces=40000`, `maxCorners=200000`, `maxTriangles=40000`, `maxFaceVertices=2000` and `maxWork=50000000`. Atlas calls additionally accept `maxCharts` and `maxChartFaces`, both defaulting to `maxFaces`. Atlas allocation counts cover the original mesh and total triangulation; the work budget is shared across cut topology, every solver, packing and final audits. Allocation/work limits and cancellation throw. Visits cover core sizes, triangle/corner equations, vector and sparse-matrix operations, reconstruction, packing and native audits; copies, sorting, elementary topology and predicate internals remain bounded by allocations without individually counted instructions. These limits do not guarantee wall-clock time or bytes.

`cancelled()` is checked during visits. `checkpoint` receives fresh `{stage,work}` records at `begin`, `anglePrepared`, `angleIteration`, `reconstructed` and `nativeVerified`; atlas child stages are prefixed by `chartN:` or `packing:`, followed by `atlasVerified`. Nested packing callbacks are also honored. Callback errors propagate without changing source data or scene state.

Twenty-one cases cover analytic pyramid fans, nine independently solved NumPy dense reference problems (130 source triangles), finite-difference Jacobians, high-valence sine-product underflow, concave polygons, non-square pins, transforms/sparse IDs, all data domains, infeasible constraints, distinct solver failures, native collapse/overflow, global overlaps, cut errors, callback snapshots, shared budgets/cancellation and native UV/normal export. `tools/generate_angle_fixtures.py` regenerates the numerical references; NumPy is only a fixture-generation dependency. `Examples.AngleAtlas` composes automatic torus cuts, angle optimization, density-aware packing and final native validation.

## Relaxing an existing layout

`UV.relax(mesh, options?) -> mesh, report` improves existing finite corner UVs without cutting or repacking them. It supports holed charts and uniformly mirrored islands. Shared nodes follow exact corner continuity across uncut edges; different UV copies of one geometry vertex can move independently. The same `islands`, `seams` and `textureSize` options as `UV.islands` apply.

```lua
local relaxed, report = E.UV.relax(mesh, {
    method = "symmetricDirichlet", -- or "angle" (default)
    pinBoundary = true,
    pins = { ["12:3"] = true }, -- preserve this face corner's existing UV
    iterations = 100,
    requireComplete = true,
})
```

The angular method provides the callable behavior of reducing differences between geometric and UV angles described in [Blender's Minimize Stretch documentation](https://docs.blender.org/manual/id/5.0/modeling/meshes/uv/editing.html). The other method uses the symmetric-Dirichlet distortion energy discussed in [Rabinovich et al., Scalable Locally Injective Mappings](https://igl.ethz.ch/projects/slim/). This implementation uses its own L-BFGS optimizer, not SLIM's proxy-energy algorithm or its performance claims.

### Fixed samples and selections

- `islands` is a boolean set of stable minimum-face IDs. Omit it to relax all islands.
- `pins` is a boolean set of `"faceId:cornerIndex"` keys, fixing each true entry to its existing native UV.
- `corners` is an optional boolean selection using the same keys. All unselected corners stay fixed.
- `pinBoundary=true` by default preserves every island boundary, including holes and seams. Set it false to allow boundary motion.

An entire connected UV node stays fixed if **any** of its corner copies is pinned or unselected. This preserves continuity and unselected data simultaneously. Masks contain booleans, not desired coordinates or influence weights. Existing coordinates can be edited before relaxation when different pin locations are needed.

Each selected island has at least two distinct fixed coordinates to remove the similarity gauge. If no node is fixed, the first node in source face/corner order is pinned. If all fixed nodes coincide in UV space, a farthest node in the texture metric supplies another anchor. `automaticPins` reports groups of source corner references for these added anchors. Fully fixed islands are already converged under their constraints even when their distortion is nonzero.

### Energies and numerical steps

The actual geometric triangulation supplies source angles and reference triangle frames. Each triangle's weight is its geometric area divided by its island's total geometric area. The two objectives are:

- `angle`: the weighted sum of squared differences between each UV triangle angle and its corresponding 3D angle, in radians. Its unconstrained lower bound is zero; it does not directly penalize area variation.
- `symmetricDirichlet`: the weighted sum of `||J||F^2 + ||inverse(J)||F^2`, where `J` maps a source orthonormal triangle frame to UV texture coordinates divided by `density`. Its unconstrained lower bound is four. It penalizes both stretching and compression relative to that density.

`density` defaults to each island's original area-based texture density. A supplied positive finite value sets the symmetric-Dirichlet reference density for all selected islands. Angular energy is scale-invariant, so this option does not change its objective. The reference density remains fixed during optimization; pins may prevent attaining it.

Each island's optimization coordinates subtract the original UV minimum and divide texture distances by its largest texture-space bounding-box extent. Gradients and `gradientTolerance` refer to this dimensionless coordinate system and the area-normalized objective. They are numerical measurements, not certified physical error bounds.

The solver uses analytic gradients and limited-memory BFGS. A bounded backtracking line search rounds every candidate to native `Vector2` coordinates, requires a negative actual directional derivative and a strict decrease in the evaluated energy, and verifies every triangle's exact orientation against its original sign. The accepted native values are retained directly. Curvature updates that fail the numerical conditioning test are discarded; a non-descent direction falls back to steepest descent. Stored intermediate and final triangles retain their signs; no continuous motion between stored layouts is certified.

| Option | Default and meaning |
|---|---|
| `iterations` | 100 accepted steps, integer `[0,1000]` |
| `gradientTolerance` | `1e-6`, positive finite maximum absolute free-coordinate gradient |
| `lineSearchSteps` | 40 trials per step, integer `[1,64]` |
| `historySize` | 8 stored L-BFGS pairs, integer `[1,32]` |
| `checkOverlaps` | True; exact global positive-area triangle checks before and after relaxation |
| `maxOverlaps` | As in `UV.analyze`, caps stored output pairs while retaining full counting |

The method is local numerical optimization. It does not guarantee a global minimum, uniform texel density per triangle, recovery from existing folds, or continuous injectivity during a hypothetical animated transition. The source mesh is not geometrically altered or checked for 3D self-intersections.

### Reports and partial results

`report.islands` contains records only for selected islands. Each has `id`, `nodes`, `movableNodes`, `pinnedNodes`, `automaticPins`, reference `density`, `initialEnergy`, final `energy`, `gradientNorm`, accepted `iterations`, `lineSearchSteps`, `converged`, optional `reason`, and `history` entries of energy and gradient norm. Accepted energy entries strictly decrease; all-pinned and already converged cases can have no accepted steps.

`report.complete` requires every selected island to converge, preserved native orientations, and no global UV overlap when that check was requested. `nativeOrientation` means preserved winding, including intentionally negative islands. It does not mean all triangles are positive. `applied` indicates actual corner changes; `changedCorners` counts them. `work`, `converged`, overlap counts/pairs and truncation diagnostics accompany the result.

A soft `iterationLimit` or `lineSearch` failure can return valid, improved partial UVs with `complete=false`, `applied=true` and top-level `reason="optimization"`. Native rounding can prevent further strict energy decrease before a requested gradient tolerance is attained. A zero iteration limit can still succeed if the initial free gradient already meets the tolerance. `requireComplete=true` throws on any incomplete result.

The following failures return an unchanged source clone with `applied=false`:

- `missingUV`: any island has a missing or nonfinite corner UV.
- `inputOrientation`: any island has a zero-area triangle or mixed triangle signs.
- `inputOverlap`: a requested initial scan finds positive-area overlap, including between separate islands.
- `nonfiniteEnergy`: numerical energy or free-gradient evaluation is not finite.
- `nativeOrientation`: the final stored layout does not retain the original signs.
- `outputOverlap`: the proposed result collides within an island or with another, including an unselected fixed island.

On rollback, per-island records describe the attempted optimization, `changedCorners` is zero, and `candidateChangedCorners`, when present, counts attempted changes. Disabling `checkOverlaps` skips initial/final scans and omits `overlapFree`; orientation checks remain active. Empty, unselected and fully pinned valid inputs are complete identities.

### Data, bounds and verification

Only intrinsic corner UVs change. Changed samples clear tangent frames; unchanged samples retain them. Geometry, IDs, polygon order, normals, materials, typed channels, skin weights and groups are preserved. Mesh and option/mask snapshots precede callbacks.

Defaults are `maxVertices=20000`, `maxFaces=40000`, `maxCorners=200000`, `maxTriangles=40000`, `maxFaceVertices=2000` and `maxWork=50000000`. Input/triangle allocations, corner-node construction, all solver and candidate checks, and both overlap scans share the work limit. Matrix/vector and energy visits are counted; copies, sorting, basic connectivity and exact-predicate internals are bounded through allocations without individually counted instructions. Limits and cancellation throw without mutating the input. These are operation/allocation controls, not wall-time guarantees.

`cancelled()` and `checkpoint({stage,work})` follow the common UV contract. Stages include `begin`, `islands`, `relaxPrepared`, `relaxIteration` and `relaxVerified`; callback failures propagate. No scene objects are created by the operator.

Twenty-four cases cover analytic planar optima, eight independent SciPy dense BFGS references, finite-difference gradients in both windings, non-square texture metrics, seams, pins, partial selections, holes, free-boundary anchors, all data fields, extreme geometry/UV scales, sparse IDs, callbacks, budgets, native precision, partial convergence, initial/final overlaps and native UV/normal conversion. `tools/generate_uv_relax_fixtures.py` needs NumPy and SciPy only when regenerating references. `Examples.RelaxedUVPanel` improves a curved panel with its border fixed.
