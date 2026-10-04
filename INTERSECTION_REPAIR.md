# Intersection splitting and solid repair

`MeshRepair.splitIntersections(mesh, options)` and `MeshRepair.resolveIntersections(mesh, options)` return a new mesh and a report. The source is unchanged, including on cancellation or failure. They build on the exact native-coordinate diagnostics in [INTERSECTIONS.md](INTERSECTIONS.md), constrained planar arrangements, explicit source correspondence and a declared geometric tolerance. The resulting mesh is triangulated.

## Separate source sheets

`splitIntersections` inserts the point, segment and polygon boundaries found between source triangles. Cuts propagate to adjacent triangles and faces. Open sheets and closed components are supported, provided the source has valid oriented topology and simple triangulatable faces. Crossing sheets keep separate vertex identities, while incident triangles on the same sheet share boundary cuts. This is useful for inspection and subsequent editing; splitting alone does not remove intersections or produce a union.

The report has `mode="separate_sheets"`, `complete`, `validation`, `vertices`, `faces`, `faceMap`, `fragmentFaces`, `nodeMap`, `maps`, `vertexBlend`, `work` and `arrangement`. Here `complete` means the arrangement was constructed and its reconstructed source topology validates. It is not an intersection-free claim. `nodeMap[geometricNode]` lists the output vertex IDs at that geometric node, potentially from several sheets. Unreferenced source vertices are omitted.

## Select a solid boundary

`resolveIntersections` requires closed, consistently oriented source sheets, or an empty mesh. The source may contain crossings, overlaps, nested components or reversed components. First it arranges intersecting triangles. It then samples each fragment on both sides, retains changes in the selected winding region, orients the retained surface outward, removes duplicate coplanar fragments, synchronizes boundary subdivisions and welds the selected boundary.

`windingRule` selects the region:

| Rule | Occupied region | Typical effect |
| --- | --- | --- |
| `"nonzero"` (default) | signed winding number differs from zero | Union of outward components; inward-only components also occupy space; opposite nested components create cavities |
| `"positive"` | signed winding number is positive | Excludes purely inward lobes/components |
| `"odd"` | absolute winding number is odd | Alternating layers and symmetric-difference occupancy |

For example, a nested pair of outward boxes becomes the outer box under `nonzero`, but a cavity under `odd`. Coincident opposite sheets cancel. Some winding regions have intrinsically nonmanifold edge/point contacts; this operation does not invent a gap or a connecting bridge to make those regions manifold. Try a different rule only when it represents the intended solid.

```lua
local source = E.Topology.join({outerShell, crossingShell})
local mesh, report = E.MeshRepair.resolveIntersections(source, {
    windingRule = "nonzero",
    tolerance = 1e-5,
})
assert(report.complete, report.reason)
```

The report has `mode="winding_boundary"` and the reconstruction fields listed above, plus `classification`, `conformity`, `intersections`, `empty` and optional `reason`. **Always check `complete`.** It is true only when the final topology is valid, the result is closed or empty, and a complete exact native-coordinate scan finds no crossings, overlaps or unwelded contacts. Otherwise the candidate is returned with `complete=false` and `reason` equal to `invalid_topology`, `open_boundary`, `incomplete_audit` or `remaining_intersections`. The candidate can be inspected; it must not be treated as a successfully repaired solid.

Construction ambiguity, invalid inputs, exhausted construction/classification budgets and cancellation raise errors. A partial diagnostic input scan cannot construct an arrangement and raises an error. A partial final scan produces the incomplete report described above.

## Numerical contract

`tolerance` is an absolute world-space distance, defaulting to `max(usedVertexExtent*1e-6, 1e-7)`. Existing used source vertices register first in stable ID order, followed by intersection constructions. Native points within this distance can share a canonical node. Intersections near a source edge/corner snap their source correspondence to that feature. Collapsed native intersection constructions are accepted only with positive tolerance and rounding error within that tolerance. Excessive tolerance that merges distinct corners, reverses fragments or collapses necessary topology rejects.

Rounded segments on an intended common intersection line can enclose thin slivers. Sub-tolerance slivers may exchange a long diagonal for a bent cut chain when the replacement triangles preserve orientation and improve the local altitude. After winding selection, boundary edges receive retained vertices along the same chain within tolerance. These steps allow a declared geometric approximation; they do not constitute exact Boolean construction. `tolerance=0` disables proximity welding, feature snapping and nonzero-altitude sliver correction, and requires complete native intersection constructions.

`arrangement` records the complete input scan, tolerance, geometric node and fragment counts, `maxWeldDisplacement`, `featureSnapDisplacement`, `planarConstructionError`, `collapsedIntersections`, `sliverEdgeFlips`, `sliverDisplacement` and construction work. `conformity` records edge splits, added fragments and maximum displacement from an original boundary segment. These are measured local changes, not an interval certificate or a global Hausdorff error bound. Original face triangulation diagonals are implementation geometry and may change.

`windingPrecision` selects `"auto"` (default), `"native"` or `"exact"`. Auto first uses native side samples and exact-sign crossing predicates. If native sample/endpoint precision, clearance or ray agreement fails, it restarts the entire classification with exact rational samples. Work already spent remains charged. Cancellation, callback errors and exhausted budgets propagate without retry. Native mode reports those precision failures directly; exact mode skips the native attempt.

Both methods cast finite rays to points outside the source bounds and count transverse triangle crossings. Rays touching an edge, vertex or coplanar patch are retried with deterministic alternative endpoints; two unambiguous rays must agree for each side sample. `maxRayDirections` defaults to 12 and accepts 2 through 12. Native classification additionally requires agreement at two offset distances on each side. `classificationOffset` is a positive upper bound, default `extent*1e-4`; native samples reduce it using fragment size and triangle clearance.

Exact classification forms each seed on its original source triangle from the fragment's stored barycentric weights. Those binary64 weights and native source coordinates are treated as exact rationals. The source normal defines the sampling line. Exact intersections with every other noncoplanar triangle bound the offset to at most one quarter of the closest crossing distance. When that line lies in another triangle's plane, exact half-plane clipping bounds the entire line/triangle interval. A seed contact rejects. Coplanar source sheets contribute their simultaneous winding jumps. Homogeneous integer predicates classify the resulting rational samples without rounding them to `Vector3`; narrow gaps can therefore be resolved even when no native sample fits inside them.

`classification` reports the rule, selected `windingPrecision`, `sampleMethod`, ray tests, ambiguous rays and classified/discarded/duplicate/reversed fragment counts. `exactSamples`, `exactFragments` and `exactWork` distinguish the exact path; it also reports `exactRays` and an optional `nativeFailure` reason. With exact samples, `minOffset` and `maxOffset` conservatively enclose the world-space offset range and `offsetRangeCertified=true`. Native reports retain their measured offset range.

Exact side labels and clearance bounds do not certify constant classification over an entire fragment or equality to an exact Boolean solid. Native arrangement construction, tolerance choices and reconstruction still apply; excessive welding or unresolved cut geometry can fail the final audit. That audit certifies only the produced native triangulation, not equality to an exact algebraic solid or an unsampled rational surface.

## Explicit source regularization

`regularization={method="vertexClusters", distance=d}` optionally moves nearby used source vertices to common positions **before** intersection detection and winding classification. Omit the option to preserve the original source positions. This is useful for nearly duplicate layers or matching boundaries separated by a small gap; it intentionally changes the solid being classified. `distance` is a finite world-space radius between `2^-126` and `2^130`. The method defaults to `"vertexClusters"` when omitted.

Vertices are processed in stable ascending source-ID order. Each moves to the nearest previously accepted representative within the radius; equal distances choose the lower ID. Representatives stay at original native positions, and clusters do not grow through transitive chains. Squared-distance membership, nearest selection and tie decisions use exact expansions of the stored native coordinates. A bounded point hierarchy accelerates those comparisons. Unused vertices remain unchanged. Boolean operands use one joined source order, with A before B; operand order can therefore affect the chosen regularized geometry.

```lua
local mesh, report = E.MeshRepair.resolveIntersections(source, {
    regularization = { distance = 1e-4 },
    tolerance = 1e-6,
})
assert(report.complete, report.reason)
local displacement = report.arrangement.regularization.sourceSurfaceHausdorffBound
```

`distance` controls source movement; the existing `tolerance` separately controls arrangement construction and welding. A zero construction tolerance still requires exactly representable cuts and can reject a regularized source. Classification uses the moved source positions, while attribute references retain the original source IDs and corner values. Separate-sheet splitting retains separate vertex identities even when their positions coincide.

The preprocessor checks every original source triangle through the entire linear motion of its vertices. The dot product of its moving normal with its original normal is a quadratic polynomial; all three exact Bernstein coefficients must be positive. This sufficient condition rejects collapse, reversal and uncertified intermediate motion. Each face must also retain its original triangulation. If a polygon changes triangulation, triangulate the input explicitly before retrying. These checks are conservative and raise errors transactionally.

`arrangement.regularization` records `method`, `distance`, `representatives[usedSourceVertexId]`, `usedVertices`, `clusters`, `movedVertices`, `triangles`, and an outward `maxDisplacement`. `sourceSurfaceHausdorffBound` equals this bound: corresponding barycentric points on the unchanged source triangulation differ by no more than the largest vertex displacement, in both directions. Exact radius membership also bounds this value by `distance`. `displacementCertified`, `sourceSurfaceBoundCertified` and `triangleHomotopyOrientationCertified` are true after those checks. This bound describes the regularization step, before subsequent arrangement construction; it is not a bound on the final repaired solid.

`globalIsotopyCertified` and `originalSolidEqualityCertified` remain false. Nearby distinct sheets can merge, gaps can close and thin layers can disappear. Triangle orientation preservation does not establish global topology preservation. The mandatory final topology and intersection audits still decide repair success. Vertex clustering does not project unmatched vertices onto edge or face interiors, and it does not promise to resolve every nearly coincident arrangement.

Regularization shares `maxWork`, `maxVertices`, face-triangulation limits and cancellation with construction. Checkpoints include `stage="regularize"`. Meshes and the nested regularization settings are snapshotted before callbacks. The `RegularizedLayers` example closes a narrow box gap and reports its source displacement. Tests include 1,728 independent exact-distance memberships, narrow gaps/overlaps, duplicate and opposite layers, all winding rules and Boolean operations, oblique transforms, attributes, idempotence, rejection, snapshots and native conversion.

### Conforming vertex-to-feature regularization

`regularization={method="features",distance=d}` extends the source preprocessor to unmatched vertices near another source vertex, edge interior or triangle interior. Original used vertices run in stable ascending ID order. Earlier vertices and inserted target vertices are frozen anchors. The closest eligible feature is selected using exact rational Gram, barycentric and squared-distance predicates; ties prefer lower feature dimension, then stable target IDs. A target edge requires both endpoints frozen; a triangle requires all three. Features sharing an original source face with the moving vertex are excluded to protect its incident triangles. Boolean operands use the joined A-before-B order.

Source polygons are triangulated first. An interior edge snap splits every incident triangle, and an interior face snap splits that triangle into three. Target and source keep separate vertex IDs at exactly the same native position. This permits winding repair to join geometrically matching surfaces while retaining each source sheet's attributes. Existing triangulation diagonals are eligible features. The default feature pass handles vertex-to-feature contacts. The optional edge-interior pass below extends that search. Neither pass promises to resolve every near-coincident arrangement.

Exact projection coordinates are rounded for native storage. Both the moving source vertex and each inserted target point must stay within `distance` of their original-reference position. Inserted references use exact barycentric subdivision of the original triangles. Frozen anchors and original-reference checks prevent cumulative drift. A rounding result outside the radius rejects, even when the exact projection lies inside. Every refined triangle must pass the same exact quadratic motion-orientation check. Tiny native triangles must also satisfy the mesh validity contract.

The refined reference triangles cover the original source triangles. Corresponding barycentric points give a bidirectional source-surface distance bound. `displacementCertified`, `sourceSurfaceBoundCertified` and `triangleHomotopyOrientationCertified` describe those checked properties; global isotopy and equality to the original solid remain uncertified. As with vertex clustering, the bound applies only to preprocessing, before arrangement construction.

The report includes `snaps` (source vertex, target vertex, selected feature dimension and original target face), `addedVertices`, `usedVertices`, `triangles`, `topologyChanged`, `exactRefinementEntries`, the source displacement bounds and preprocessing `maps`. Final output `maps` and `faceMap` refer directly to the original source, composing both stages before sampling typed data, groups, skin weights and intrinsic corners. Original edge channels follow refined boundary segments; interior edges use defaults. The exact coefficient cap also bounds accumulated refinement records and reference weights.

The `FeatureRepairedLayers` example closes a gap against a face with an unmatched center vertex. Twenty-five tests include 144 independent exact closest-feature witnesses, 216 independently interpolated motion coefficients and 648 determinant samples, shared-edge conformity, analytic repaired and Boolean volumes, native rounding rejection, transformed geometry, operand order, original correspondence, idempotence, snapshots, resource limits and native conversion.

### Optional edge-interior proximity

Add `edgePairs=true` inside the `method="features"` settings to process two close edge interiors after the vertex pass. Original triangulation edges retain their ordered chains through refinement. Pairs run in stable original endpoint-ID order; edges sharing an original source face are excluded. Exact rational Gram predicates find the unique interior closest pair for nonparallel segments. Parallel segments with a positive projected overlap use that interval's exact midpoint. Endpoint-only minima remain outside this pass; zero-distance contacts remain for the arrangement constructor.

For each original edge pair, the current eligible segment pair with the least positive distance within the radius is selected. The earlier edge owns the native anchor. Both edges split at their respective exact closest parameters, using separate new vertex IDs at the same native position. Every incident triangle splits conformingly. Existing endpoints stay fixed during this pass. Each inserted node must satisfy the original-reference radius bound, and the final refined triangle-motion audit remains mandatory. Native rounding outside either checked radius rejects transactionally.

The original edge bounding hierarchy uses a `3*distance` search envelope: each current source and target point lies within `distance` of its reference edge, and the candidate pair is within one further radius. Exact box-distance comparisons preserve this exclusion proof. This is a bounded deterministic pass with at most one selected contact per original edge pair; it does not establish that all nearby features coincide afterward. A valid regularized source can still fail the final winding repair audit, including when contact creates nonmanifold topology.

`arrangement.regularization.edgePairs` records whether the pass ran. `edgeSnaps` records each original `sourceEdge`/`targetEdge` key and the two new vertex IDs. Original triangulation diagonals are included. The shared work, vertex, face and exact-reference budgets apply; callbacks include `stage="regularizeEdges"`. `edgePairs` must be boolean and requires `method="features"` when enabled. `EdgeContactSheets` demonstrates a crossing with endpoints outside the snap radius. Sixteen added cases cover 160 independent nonparallel and parallel closest-pair witnesses and their reversals, exact radius boundaries, original data maps, native precision rejection, conforming chains, snapshots, limits and native anchor identity.

## Attribute correspondence

`maps` contains explicit output-to-source references for vertex, edge, face and corner domains with identity fallback disabled. Surviving original vertex IDs and the first retained fragment of each source face retain their IDs where possible. Remaining IDs allocate above the source counters. Face material and typed face channels follow the source face. Intrinsic corner fields, corner channels and UV seams interpolate in their own source triangle. Source edges transfer edge channels to their segments; newly created interior edges use schema defaults.

Welded vertex attributes, groups and skin weights blend barycentric contributions from retained source triangles. `vertexBlend="average"` averages one contribution per participating source triangle; it is not an area-weighted average. `"first"` uses the lowest participating source triangle index. Typed channel interpolation policies still apply. Separate-sheet output never blends across independent sheet identities. Normal values are recalculated; reversed corners flip intrinsic tangent signs. Apply the normal/tangent APIs afterward when a particular custom shading treatment is required.

## Bounds and verification

Construction/reconstruction limits are `maxVertices=100000`, `maxFaces=200000`, `maxWork=5000000`, `maxFaceVertices=2000`, `maxFacePoints=10000`, `maxFaceTriangles=20000` and `maxSegments=20000`. `maxFaceWork` bounds source-face triangulation. Input diagnostics use `maxTriangles=500000` by default. `intersectionOptions` supplies diagnostic scan budgets; contact inclusion and ordinary-adjacency exclusion are fixed for repair correctness. Diagnostic scans have their own work budget, inherited from `maxWork` unless overridden. The report's `work` counts arrangement, classification, conformity and reconstruction visits, including integer limb operations in exact classification; scan work remains in the corresponding scan reports.

Exact arithmetic additionally uses positive integer limits `maxExactBits=8192` and `maxExactCoefficients=1000000`. The coefficient preflight requires an allowance of `96*sourceTriangleCount+128`. These options are validated even when native classification succeeds. Exact classification can consume substantially more work; the transformed overlap in `PreciseRepair` explicitly supplies `maxWork=50000000`.

Both repair calls snapshot their meshes and options before callbacks. `maxSnapshotEntries=4000000` bounds copied table entries across all inputs, counting repeated references each time. Cyclic data and nesting beyond 64 levels reject before callbacks. A callback can modify the caller's tables without changing the in-progress operation.

`checkpoint(record)` runs at phase entry and periodically, including `stage="topology"` and `stage="classifyExact"` progress. Throwing cancels transactionally. Classification and final conformity use bounded triangle/edge searches; this is an authoring operation, not a real-time collision kernel.

Tests cover separate open/closed/coplanar sheets, isolated contacts, analytic box union and rotated-square volumes, triple-overlap inclusion/exclusion, nested/cancelling/inward shells, a self-intersecting connected source, unresolved nonmanifold tangencies, all attribute domains, UV seams, groups/weights, scale and oblique transforms, idempotence, empty inputs, limits/cancellation, incomplete final audits and native EditableMesh round trips. Exact winding cases include 54 independent rational crossing references, 64 homogeneous-coordinate references, sub-resolution gaps, coplanar sampling lines, independently rounded transformed overlaps and callback snapshots. `RepairedSolid` demonstrates a triple overlap; `PreciseRepair` demonstrates exact recovery of a transformed overlap. [BOOLEANS.md](BOOLEANS.md) extends this arrangement to independently classified Boolean operands. Both source regularization methods are described above. Exact rational-surface contacts are documented in SPLINE_QUERIES.md.
