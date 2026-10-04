# Mesh simplification

`Simplify.decimate(mesh, targetFaces?, options?)` performs bounded, constrained triangle edge collapse with the controls and surface bound below. `Simplify.planar(mesh, angleLimit, options?)` reduces nearly planar regions to polygons and optionally simplifies their boundary chains. Angles use radians. These are separate operations; planar reduction does not target a face count or reconstruct a pre-subdivision cage. Blender's [limited dissolve and un-subdivide operators](https://docs.blender.org/api/5.0/bmesh.ops.html) provide the comparison baseline. `Simplify.unsubdivide` supplies bounded whole-component and opt-in local grid coarsening, described below.

```luau
local reduced, report = E.Simplify.planar(cage, math.rad(2), {
    maxPlaneDeviation = 0.002,
    dissolveBoundaries = true,
    maxBoundaryDeviation = 0.001,
    requireComplete = true,
})
```

The operation snapshots mesh data and options before calling user callbacks. It creates no scene objects and does not modify the caller. Surviving vertices keep their exact native positions and IDs. An output face uses the smallest original face ID in its region. No positions are flattened or averaged. Polygon retriangulation and optional boundary reduction can change the represented surface, so geometry checks and data correspondence remain part of the result.

## Region and boundary rules

`angleLimit` must lie in `[0, pi/2)`. Each region retains its original source faces. Every source-face normal must be within that angle of the region's lowest-ID source-face normal. This fixed reference prevents accumulated angle drift along a curved strip. Every original region vertex must also lie within `maxPlaneDeviation` of the candidate polygon's Newell plane. The default distance is half the input bounding-box diagonal times `sin(angleLimit)`. Supply a distance explicitly when modeling accuracy matters.

Zero angle requires exact coplanarity of the stored native coordinates, checked using robust orientation signs. Exactly coplanar regions report zero plane deviation. Positive angles use double scalar normal and distance calculations. Native rounding after a transform can prevent a merge under a strict tolerance; the operation retains those faces.

Regions merge only when their entire common boundary can be removed to form one simple polygon. The operation checks winding, projected boundary simplicity, orientation of every original triangle under that projection, and final triangulation. Pinched boundaries and holes prevent a merge. A planar region with a window therefore retains a partition into disk polygons. This is deterministic greedy reduction, not a minimum-face partition or a global optimization.

`options.faces` is an optional boolean set of original face IDs. Omission selects every face; an empty set selects none. Only selected regions can merge. Boundary simplification changes a vertex only when every incident output region is selected, preserving conformity with unselected neighbors.

`dissolveBoundaries=false` is the default. When true, a vertex with two distinct neighbors in the complete region-boundary graph can be removed simultaneously from all incident polygons. Junctions remain. Each original segment in the resulting chain must lie within `angleLimit` of its final chord. Every original chain vertex must project onto that chord segment and stay within `maxBoundaryDeviation`, whose default is `maxPlaneDeviation`. Distances are always checked against the original chain, including vertices removed by earlier steps. Zero angle retains only exact collinear removals. The resulting polygon must still pass the region geometry checks.

Plane and chain deviation reports describe these local geometric tests. They are numerical measurements, not an interval certificate, a whole-mesh Hausdorff bound, or a guarantee about curvature or texture distortion. The default final intersection audit detects new collisions introduced by accepted near-planar reductions.

## Attributes and correspondence

Default `preserveSeams=true` prevents merging across material differences, intrinsic corner discontinuities, typed corner/face discontinuities, and positive numeric or true boolean `sharp_edge`, `uv_seam`, or `subdivision_edge_sharpness` fields. Additional edge fields can be named in `seamAttributes`. Intrinsic normals and tangents are excluded from seam comparisons. `uvTolerance` defaults to `1e-6`; `attributeTolerance` defaults to zero. Every removed common edge is checked, including edges other than the candidate that initiated a region merge.

Boundary simplification preserves a constant value along every typed edge field when seam preservation is enabled. It can coarsen a consistently marked sharp or UV seam while retaining its edge value. Changing edge values retain the intervening vertex. `preserveSeams=false` permits these data discontinuities to be discarded or blended.

Surviving vertex fields, groups and skin weights retain their original values. Removed unused vertices and their data are pruned. Each surviving corner comes from the original face contributing its outgoing boundary edge. Typed face fields use original source-face area weights and the field's declared interpolation; categorical ties use deterministic source order. The representative source face supplies the material. New boundary edges use original segment-length weights for typed edge fields. Other surviving edges retain identity correspondence.

Geometry simplification does not preserve arbitrary interior field samples or a nonlinear UV function exactly. Output corners receive flat geometric face normals; stale intrinsic tangents are cleared. All other surviving intrinsic fields and typed schemas remain. Call `Normals` afterward for a different shading policy. `report.maps` exposes face, corner and new-edge correspondence; `regions` and `sourceFaceToOutput` record original face membership.

## Completion, audits and limits

The returned report contains `complete`, `success`, `reason`, `initialFaces`, `finalFaces`, `merges`, `boundaryRemoved`, `maximumAngle`, `maximumPlaneDeviation`, `maximumBoundaryDeviation`, `work`, `blocked`, `validation` and correspondence. `maximumAngle` measures source-normal deviation from each region reference. Plane deviations concern modified regions; they do not claim that an untouched source polygon met the requested merge tolerance.

`complete=true` means no further candidate was accepted under the configured rules, the output validates, and any requested intersection audit passed. It does not promise a target face count. `reason="constrainedFixedPoint"` is successful completion. `blocked` counts rejected region pairs in the last merge scan, with reasons such as `angle`, `deviation`, `seam`, `holes`, `pinch`, `fold`, `projection` or `faceVertices`. These constraints are ordinary stopping conditions.

`maxMerges` and `maxBoundaryRemovals` are soft limits. Their defaults are the face and vertex allocation limits, respectively. A limit reached while another accepted candidate exists returns a partial mesh with the corresponding reason and `complete=false`. Invalid output or an unsuccessful output audit also returns an incomplete result. `requireComplete=true` throws for incomplete results. Invalid input, hard allocation/work exhaustion, and cancellation always throw.

`checkIntersections=true` is the default. The input must pass a complete self-intersection audit; the output gets a separate audit after simplification. Reports include `inputIntersections`, `outputIntersections` and `intersectionChecked`. `intersectionOptions` configures the existing bounded scan. Setting `checkIntersections=false` explicitly omits both checks, and successful completion then makes no intersection claim.

Defaults are `maxVertices=250000`, `maxFaces=250000`, `maxCorners=1000000`, `maxFaceVertices=2000` and `maxWork=20000000`. Input allocation checks precede copying. These operations never increase face or vertex counts. Work counts geometry, topology, predicate and audit visits; it is not a byte, instruction or wall-clock guarantee. Greedy region scans and repeated boundary checks can be expensive on large grids; budget exhaustion is explicit. Nested intersection triangulation retains its own face-work limit.

`cancelled()` is checked during counted work. `checkpoint({stage,work,merges,faces})` runs at `begin`, each accepted `merge` or `boundary` change, intersection progress, and `complete`; it may yield or throw. Callbacks may edit the original mesh or options without changing the operation's snapshot.

Twenty tests cover independent areas, concave outlines, holes, partial selections, material/UV/typed seams, face-area and edge-length data transfer, original-chain bounds, cumulative angular limits, source snapshots, transforms, sparse IDs, native precision, budget/cancellation failures, new output intersections and native UV/normal conversion. `Examples.PlanarPanel` reduces a tiled panel with a window.


## Quad-grid un-subdivision

```luau
local coarse, report = E.Simplify.unsubdivide(cage, 2, {
    maxDeviation = 0.02,
    keepVertices = { [chosenCorner] = true },
    requireComplete = true,
})
```

In the default whole-component mode, one iteration replaces each recognized group of four quads by one coarse quad. `iterations` is an integer from zero through sixteen. This full-level convention differs from Blender's alternating grid-removal steps. Surviving control points retain their current native positions; the operation does not invert Catmull–Clark smoothing or recover a historical cage.

Recognition works on each connected surface component. It identifies old corner vertices, edge points and face centers through two graph colorings. Every fine face must have the cyclic roles corner–edge–center–edge. A center has four incident quads; an edge point joins two old corners and one or two face centers. Coarse edges must be unique, and every reconstructed face must have four distinct corners. Extraordinary old vertices and open boundaries are supported. Odd grids, nonquad components and connectivity incompatible with this pattern remain unchanged and receive an explicit rejection reason.

Closed regular grids can have four valid choices of retained corners. Each phase must pass the geometry and data constraints. The operation chooses the accepted phase with the smallest error bound, breaking exact ties by numeric retained-vertex ID order. `keepVertices` is an optional boolean set of input vertices that must survive every requested level as old corners. Pins can select an ambiguous phase; incompatible pins can prevent a component from coarsening. The report exposes the number of recognized phases and the retained IDs, rather than claiming to identify the original authoring cage.

`faces` is an optional boolean set of original face IDs. Omission selects all faces; an empty set is an identity operation. By default, a selected component must be selected in full. A partial component remains unchanged with reason `partialComponent`; other fully selected components may still coarsen. Set `transitions=true` for the local conforming mode described below.

### Surface error and geometry checks

`maxDeviation` bounds the changed **polygon surface**, including all requested levels. Its default is one percent of the input bounding-box diagonal. Source and output positions remain native coordinates, while the error calculation uses exact expansions and outward double intervals. A zero deviation budget can accept exactly equivalent piecewise-linear grids. It does not require approximate equality within a hidden epsilon.

Each recognized four-quad patch has a canonical square parameterization: old corners at its corners, edge points at side midpoints, and the face center at the square center. The evaluator uses the actual triangulation of every source quad and the proposed coarse quad. Their common parameter triangulation has vertices among the nine grid points and four quarter-square centers. The paired position difference is affine in every common triangle, so its norm reaches a maximum at one of those vertices. Checking these thirteen points bounds the entire pair of piecewise-linear surfaces. Checking only the nine stored vertices would miss a change caused by crossing triangulation diagonals.

All barycentric weights in this calculation are exact dyadic fractions. Expansion arithmetic preserves weighted native-coordinate differences, including cancellation of large common translations. Outward component squares and square roots bound the distance. Every patch's parameter domain covers its source and target surfaces; consequently the maximum patch bound is also a Hausdorff bound for that coarsening level. The result's `errorBound` adds per-level maxima outward, using the triangle inequality for the whole call. This can be conservative when different components attain the maximum on different levels. Isolated unused vertices, shading and attribute distortion are outside this polygon-surface bound.

`minimumNormalDot` defaults to `0.1` and must lie in `[0,1]`. Source and target triangle normals are compared wherever their parameter interiors overlap with positive area. The overlap classification uses exact small-integer diagonal-side tests. The normal-dot comparison is a numerical quality threshold. Invalid coarse polygons, degenerate triangles, excessive deviation and rejected normal changes prevent a phase from being accepted.

Input and output self-intersection audits run by default, with the same `checkIntersections` and `intersectionOptions` conventions as planar reduction. A bound on surface displacement does not guarantee that the result is intersection-free; a new collision makes completion false even when its deviation fits the requested budget.

### Data, reports and limits

Default seam protection uses the same material, intrinsic corner, typed corner/face and named edge rules as planar reduction. An internal edge between an edge point and a face center cannot be removed across a protected seam or feature. A vertex with positive `subdivision_vertex_sharpness` must survive as an old corner. The two fine edges forming a new coarse edge must have equal values in every typed edge field. Consistently marked coarse feature edges therefore survive, while a change along the middle of an edge can prevent coarsening. `preserveSeams=false` explicitly permits approximation across these data constraints.

Coarse corners retain the corresponding old-corner intrinsic and typed values. Per-level source-face areas weight merged face fields; original segment lengths weight the two contributing edge fields. Declared field interpolation still applies. The smallest source face ID supplies the coarse face ID and material. Surviving vertex fields, groups and skin weights retain their source values; unused vertices and their data are pruned. Reconstructed faces get flat geometric normals and cleared intrinsic tangents. Unchanged faces retain their source corner fields. Geometry error bounds do not bound lost interior attributes or texture distortion.

The report includes `requestedIterations`, `iterationsCompleted`, `appliedLevels`, `initialFaces`, `finalFaces`, `errorBound`, `maxDeviation`, `steps`, `work`, `validation`, `complete`, `success` and `reason`, plus requested intersection audit reports. Each step includes component diagnostics, accepted/rejected counts, its maximum error, per-patch source faces and bounds, and face/corner/edge correspondence maps. Component diagnostics expose `recognizedPhases`, `retainedVertices`, `errorBound`, and phase-rejection counts such as `keepVertex`, `feature`, `seam`, `edgeData`, `coarsePolygon`, `deviation`, `normal` or `errorBudget`.

If any selected component cannot coarsen, the call stops after that attempted level. Other accepted components at that level remain in the returned partial mesh. `appliedLevels` counts levels that changed any component; `iterationsCompleted` counts levels that completed for every selected component. `reason="components"` identifies such a partial result. Successful requested levels use `reason="iterations"`; an empty selection uses `emptySelection`. Invalid output or a failed output audit has its own reason. `requireComplete=true` throws for incomplete results. The caller's source stays unchanged, including on error.

Input defaults are `maxVertices=250000`, `maxFaces=250000`, `maxCorners=1000000` and `maxWork=20000000`. At most four phases are considered per component per level. Counts never increase. Work counts graph, geometry, expansion and audit visits, not bytes or exact machine instructions; nested intersection face-work limits remain applicable. Hard limits, invalid input and cancellation throw. Options and mesh data are snapshotted before callbacks. `cancelled()` is checked during counted work. `checkpoint({stage,work,iteration,faces,errorBound})` runs at `begin`, recognized component decisions, completed `level` boundaries, audit progress and `complete`, and may yield or throw.

Twenty-one tests cover independent even/odd grids, subdivided boxes, periodic phase ambiguity, pins and seam fields, whole-component selections and partial results, repeated levels, source data/callback isolation, sparse IDs, transforms, native precision, budget/cancellation failures, new collisions and native UV/normal export. Eighty independent Python Fraction triangle overlays verify the distance bounds and 1,280 positive-area overlap decisions over all fine-triangulation patterns, scales and translations. `Examples.CoarseCage` demonstrates bounded coarsening of a subdivided box.


## Local coarsening with transition polygons

```luau
local coarse, report = E.Simplify.unsubdivide(panel, 1, {
    transitions = true,
    faces = selectedFineFaces,
    keepVertices = { [featureSample] = true },
    maxDeviation = 0.02,
    requireComplete = true,
})
```

`transitions=true` uses the same component/phase recognizer and four-quad patch convention, while allowing a selected region inside a finer component. A patch is eligible only when all four fine faces are selected. Three or fewer selected faces are reported as `partialPatch`; they are not rounded up into a larger selection. Accepted patches become polygons with four old corners and any required retained edge samples: quads through eight-sided transition polygons. Every original sample on an edge adjoining an uncoarsened patch remains, so both sides retain the same edge segmentation. There are no newly introduced T-junctions.

In this mode, `keepVertices` fixes old corners and edge samples at their original positions and IDs. A pinned face center prevents its patch from coarsening (`keepCenter`); a pinned edge sample adds a retained polygon corner. Positive vertex sharpness follows the same policy. Protected internal seams/feature spokes prevent their patch from merging. Different typed values on the two halves of a coarse edge retain the midpoint and both original edge records rather than rejecting all adjacent patches. With `preserveSeams=false`, these data constraints are relaxed while explicit pins remain enforced.

Rejected patches change the boundary of the accepted region. The algorithm therefore recomputes retained frontier samples and revalidates every surviving candidate after each batch of geometric rejections, until the active set stops changing. This finite process can conservatively reject patches; it is not a maximum-cardinality region optimizer. Among recognized phases, the mode chooses the most accepted patches, then the smallest maximum error bound, then numeric retained-vertex ID order. The resulting mesh must preserve oriented manifold validity and each original component's Euler characteristic and boundary-loop count. Distinct components cannot join or split.

### Bounds for transition surfaces

The bound uses the actual native triangulations of all four fine quads and the proposed four-to-eight-sided polygon. Canonical UV vertices have integer coordinates zero, two or four. Exact small-integer segment intersections enumerate their common cells; intersection vertices may be rational rather than dyadic. Positive-area overlap decisions are exact. At every common-cell vertex, exact expansion numerators and integer denominators evaluate the difference between paired native piecewise-linear positions. Outward division, squares and square roots enclose its norm. Since the difference is affine inside a common cell, the maximum over these vertices bounds its entire surface image. Positive target chart triangles must be nonoverlapping and cover the whole canonical square.

A retained edge sample may make a native triangle whose canonical UV area is zero: the old corner, edge midpoint and next old corner all lie on one chart boundary, while their 3D positions form a thin triangle. Such a boundary triangle is handled separately. If its native points are `a`, `m`, `b`, the original fine surface contains the boundary segments `a–m–b`. Split the target triangle at the UV midpoint and map each half affinely to the corresponding source segment. The displacement is zero at its original vertices; its only other extreme is the chord midpoint, with distance `length(m - (a+b)/2)`. An outward bound on that quantity covers the entire additional target triangle. Taking the maximum with the ordinary common-cell bound therefore bounds both directions of Hausdorff distance, including these boundary triangles. Other degenerate or reversed chart constructions are rejected.

Normal constraints compare positive-area chart pairs as before, and also compare each nondegenerate boundary triangle with the fine triangles incident to its source boundary segments. This numerical quality check can reject a thin triangle whose normal flips after native rounding even when its distance bound is small. The operation reports that constraint rather than treating a small displacement as proof of a good orientation. Bounds are accumulated outward across accepted levels. Each later level uses the remaining cumulative deviation budget when selecting patches, allowing independent lower-error patches to proceed if others exceed that remainder. The bounds cover polygon geometry rather than shading, attributes or a continuous deformation path.

### Local data and completion

Unselected polygons retain their geometry and intrinsic corner records. Retained vertices, including original loose vertices, keep their positions, skin and groups. Selected merged face fields use source area weights; removed edge-midpoint chains use source segment-length weights. Retained half-edges keep their values, and transition corners take the compatible source corner at the same retained vertex. Existing typed interpolation applies; explicit default-valued entries may become sparse without changing channel values. New faces receive flat geometric normals and cleared intrinsic tangent/sign fields. Interior samples and attributes removed by a merge are not reconstructible from the result.

`steps[*].components[*]` additionally reports `selectedFaces`, `coveredSelectedFaces`, per-center `patches` with accepted/reason fields, `frontierRounds`, `transitionPolygons` and rejection counts. Step totals also include `transitionPolygons`. If some selected patches fail, valid accepted patches remain as a partial result with `complete=false`; `iterationsCompleted` advances only when every selected face completes that level. `appliedLevels` counts any changed level. `requireComplete` retains its strict behavior.

Recognition is performed again for each requested level. Fully selected grids can continue through multiple levels. A local result containing transition polygons can stop a later level with `nonquad`; the already verified level remains a valid partial result. The API does not silently treat a requested multi-level local operation as complete when the resulting mixed topology cannot be recognized. Existing mixed polygon inputs have the same explicit recognition restriction.

Local mode preserves the existing allocation/work limits and input-validation requirements. It performs input/output intersection audits by default, shares root and nested cancellation checks, and snapshots source/options before callbacks. If the final output topology or intersection audit fails or is incomplete, **the entire local-mode call rolls back to its original input snapshot**. The report retains attempted steps plus `candidateAppliedLevels` and `candidateErrorBound`, resets committed levels/error to zero, and reports `reason="outputAudit"`. A topology-type failure during a level keeps the previous valid level with `transitionTopology`. Hard invalid input, source audit failure, budgets and cancellation throw transactionally.

Twenty-two additional cases cover all sixteen frontier patterns, analytic curved errors, pins/features and typed data, selection limits, holes/periodic grids, scales/transforms/sparse IDs, source snapshots, revalidation after rejection, rollback and native conversion. There are 240 independent Fraction/400-digit reference configurations with 7,680 triangle-pair decisions, including 3,251 positive-area pairs and 236 boundary-triangle adjacency pairs. A separate numerical check sampled 28,800 points in both surface directions. `TransitionPanel` demonstrates curved local coarsening with a conforming UV boundary.


## Controlled triangle decimation

```luau
local reduced, report = E.Simplify.decimate(source, nil, {
    ratio = 0.6,
    pins = { [centerVertex] = true },
    group = "reduction",
    weightFactor = 1,
    symmetry = { axis = "X", origin = 0 },
    maxDeviation = 0.25,
    maxIterations = 2000,
    requireComplete = true,
})
```

The input is copied and triangulated with bounded, simple-polygon checks and source face/corner transfer. `targetFaces` is a nonnegative triangle count. Alternatively, omit it and supply `ratio` in `[0,1]`; the target is `floor(initialTriangles * ratio)`. They are mutually exclusive. Each iteration accepts at most one edge or one atomic symmetry group. A group can cross below the target. Nonempty surface components are retained, so a zero target generally returns a constrained partial result.

Original triangle planes contribute area-weighted quadrics to their three vertices. Collapses add endpoint quadrics, retaining the original references throughout the run. Coordinates are normalized independently per connected component. Scores are converted back to world units (area times squared plane distance, scaling by length to the fourth power). This is a greedy numerical score, with deterministic edge-key ties; it is neither a surface distance certificate nor a global optimum. The original [quadric error method](https://www.mgarland.org/research/quadrics.html) motivates the score. This implementation restricts placement to the current edge segment and does not reproduce every Blender decimator policy.

`placement` is `"segment"` by default: minimize the numerical quadratic along the edge and clamp its parameter to `[0,1]`, using the midpoint for zero/nonpositive numerical curvature. `"midpoint"` uses `t=0.5`; `"endpoints"` chooses the lower-scoring endpoint. An exact pin or a symmetry constraint can override these choices. Positions use scalar interpolation before native Vector3 storage. Endpoint choices retain the original vector exactly. Candidate scores and the surface bound use the stored native position. `maxError`, when supplied, limits the sum of the fixed-reference quadric scores for the candidate group; it has the length-to-the-fourth units above, unlike `maxDeviation`.

### Selection, features and data

`pins` is a vertex boolean set. True entries retain their ID and exact position, and can absorb an eligible neighbor without moving. `faces` is an optional boolean selection in the original polygon face IDs; every vertex incident to an unselected face is fixed. Unselected faces therefore retain their geometry after the initial triangulation.

A `mask` vertex dictionary, named `group`, scalar vertex `attribute`, and `maskField(position, id)` multiply values in `[0,1]`. Booleans are accepted as zero/one. Missing mask/group entries are zero; attribute defaults are honored. Zero influence fixes the vertex. Positive influence changes priority rather than the collapse displacement: a pair's quadric score is divided by `weight^weightFactor`, where the weight is the smaller positive endpoint influence (or the other endpoint's influence when one is fixed at zero). `weightFactor` defaults to one and must be finite and nonnegative. After a collapse influences interpolate with the same edge parameter. A zero-influence survivor stays fixed. A zero quadric score remains zero regardless of a positive weight.

`preserveBoundary=true` and `preserveSeams=true` are defaults. Boundary protection blocks all collapses touching a boundary vertex. Explicit `preserveBoundary=false` permits boundary edges subject to link and topology checks; interior edges joining two boundary vertices remain forbidden. Seam protection blocks incident vertices at material, intrinsic/typed corner and typed face discontinuities, as well as positive `sharp_edge`, `uv_seam`, `subdivision_edge_sharpness` and named `seamAttributes` edge fields. Positive numeric `subdivision_vertex_sharpness` fixes the vertex. Existing UV/attribute comparison tolerances apply. Explicitly disabling seam protection permits these merges.

Each step uses chart-local edge-parameter transfer for intrinsic corners, every typed domain, skin weights and groups. Source face/material identity follows the surviving triangle; new triangulation diagonals use channel defaults. Original loose vertices and their data remain. `sourceVertexToOutput` maps original IDs to retained representatives; it is a geometric correspondence, **not** a set of attribute interpolation weights. `outputFaceToSource` maps output triangle IDs to original polygon IDs. `collapseLog.operations` records each survivor `a`, removed vertex `b`, interpolation `t` and native `position`, enabling the actual sequence to be inspected.

Changed geometry clears intrinsic tangent/sign fields. Fan-aware normals are recalculated by default with optional `normalAngle`; `recalculateNormals=false` retains the transferred intrinsic normals. Other typed vector fields follow their declared interpolation rules.

### Exact reflection symmetry

`symmetry={axis="X"|"Y"|"Z", origin=0}` requests reflection in one coordinate plane. The input triangulation must have unique native vertex positions, a bijective involutive reflected vertex map, and reflected face connectivity with reversed winding. Exact expansion arithmetic checks the coordinate reflection relation. Asymmetric input, ambiguous coincident vertices, incompatible diagonals and a plane whose reflected native samples are not exactly representable are rejected; no nearest-vertex matching or automatic retriangulation is implied. Source attributes need not be symmetric.

Disjoint mirrored edges collapse together to exactly reflected native points. An edge wholly in the plane stays in it. A self-reflected crossing edge collapses to its midpoint on the plane. Two edges sharing a plane vertex absorb both off-plane vertices into that unchanged survivor. Pins and data/boundary constraints apply to every member. The entire group is checked before commit, including the resulting reflection map. Intermediate sequential link checks may conservatively reject some otherwise conceivable groups. A rejected pair never leaves a one-sided edit.

### Whole-surface deviation bound

`errorBound` is an outward upper bound on the two-sided Hausdorff distance between the original **triangulated polygon surface** and the returned surface. It is computed from original native positions and their final stored representatives, not by summing local errors. Optional `maxDeviation` is finite, nonnegative and in position units; every accepted candidate must satisfy it. With no limit supplied, the bound is still computed and reported.

The certificate uses a checked piecewise affine correspondence. Each original triangle's three vertices map to current representatives. Three distinct representatives must be that same surviving triangle in the original order; two must form an output surface edge; one must be incident to an output face. Every output triangle must be covered by an original triangle. Thus the affine map sends the entire source surface onto the output surface. At any barycentric point its displacement is a convex combination of the three vertex displacements, so its norm is at most the largest vertex displacement. Surjectivity provides the reverse distance bound as well. Exact coordinate differences and outward interval squares/square roots enclose the maximum, including native position rounding. Loose vertices are preserved separately and do not define polygon surface area.

This correspondence bound can be conservative: a planar collapse can leave part or all of a surface unchanged yet have a positive bound because a removed vertex maps to a distant representative. A zero deviation limit can therefore block such a collapse. The quadric score, original-normal angle and greedy priority are numerical diagnostics, distinct from this outward geometric bound.

### Validation, limits and results

Source geometry must be finite, positive-area, consistently oriented and manifold. Every accepted group passes the edge link checks, a complete native topology validation, original-component coverage, and unchanged Euler characteristic and boundary-loop count per component. Each surviving triangle's normal is compared with its **original** triangle normal; `minimumNormalDot` defaults to `0.1`, accepts `[-1,1]`, and is a numerical gate. The final bound is recomputed independently of candidate scoring.

Input and final self-intersection audits run by default. A failed or incomplete audit returns the untouched original input snapshot with `complete=false`, `applied=false`, zero committed `collapses`/`errorBound`, and an explicit `reason`. Attempted output counts remain in `candidateCollapses`/`candidateErrorBound`; the log describes those attempts. `checkIntersections=false` explicitly omits that guarantee. The audits cover endpoints, not continuous vertex trajectories or intermediate collapse states.

`complete`, `success` and `targetReached` are true only when the requested triangle target is reached and final checks pass. A constrained fixed point reports `reason="constraints"`; exhausting the soft iteration limit reports `"iterations"`. Both may return valid partial progress. `maxIterations` defaults to the initial triangle count and accepts zero; it counts atomic groups, while `collapses` counts their individual edges. `requireComplete=true` throws on any incomplete result. `applied` records committed collapse/triangulation changes; default normal recomputation may also update corner normals. Final counts, correspondence, cumulative rejection counts, normal angle, bound, audit reports and work are inspectable.

Hard defaults are 20,000 vertices, 40,000 input faces, 200,000 corners, 40,000 triangles, 2,000 vertices per input face and 50,000,000 charged work visits. Override with the corresponding `maxVertices`, `maxFaces`, `maxCorners`, `maxTriangles`, `maxFaceVertices`, and `maxWork`. Allocation limits bound geometry, not arbitrary attribute payload sizes. Whole-mesh reconstruction and validation remain conservative and can be expensive; this is not an interactive large-mesh performance claim. Work/allocation exhaustion, invalid input and cancellation throw without changing the caller's mesh. Root/nested intersection callbacks share the work/cancellation checks. Inputs and option tables are snapshotted before callbacks; `checkpoint` reports preparation, iterations, audits and completion.

`ReducedPanel` demonstrates exact reflection, a center pin, UV transfer, a deviation limit and native conversion. Tests include an analytic quadric, 64 independent Fraction/400-digit distance references, barycentric surface samples, boundary and component topology, all reflection cases, constraints, source/data preservation, scale/translation/sparse IDs, limits, collision rollback and native round trips.
