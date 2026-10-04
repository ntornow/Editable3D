# Trimmed surface domains

`E.SurfaceTrim` represents NURBS surface regions using an exterior UV loop and optional holes. It uses the validated Planar triangulator and exact native-coordinate predicate signs. Surface controls remain editable independently of the trim loops. These APIs create data only.

`surface(surface,outer,holes={},options)` returns `{kind="trimmedSurface",surface,outer,holes}` with copied controls, weights and loops. UVs must be finite native Vector2 values in [0,1]². The source surface is converted to an equivalent clamped active-domain representation. Polygon loops must satisfy the simple-domain requirements in [PREDICATES.md](PREDICATES.md); touching, crossing, outside and nested holes reject. A repeated closing point is accepted and removed from the copy.

`classify(trimmed,uv)` returns `"inside"`, `"outside"` or `"boundary"`. Hole interiors are outside; either kind of boundary is included. `evaluate(trimmed,u,v)` rejects outside parameters and evaluates the source surface at the classified native Vector2 UV. The u/v arguments are therefore rounded to native UV precision before classification and evaluation. If loops are edited directly, tessellation revalidates the complete domain; classify alone is not a full domain-validity check.

## Rational curve boundaries

`fromCurves(surface,outerCurve,holeCurves={},options)` samples closed NURBS curves in the XY parameter plane. Each control's Z must be within `closingTolerance` (default 1e-6), and sampled first/last positions must coincide within that tolerance. `curveTolerance` defaults to 1e-4 UV units and uses SplineQuery's geometric curve-to-polyline bound. A sampling result that does not converge rejects. Cyclic curves can first be converted using `Cyclic.toNURBS`.

It returns `(trimmed,report)` with each curve's sampling report and `parameterTolerance`. The resulting trim domain contains polylines; it does not retain analytic trimming intersections. The tolerance is in parameter space, not authoring-space distance on the surface. Native UV rounding and closing tolerance also apply. After sampling, the normal polygon validation rejects self-intersections or contacts introduced by an unsuitable approximation.

```lua
local surface = E.Surfaces.plane(CFrame.identity, Vector2.new(4,4))
local exterior = E.Surfaces.arc(CFrame.new(0.5,0.5,0), 0.45, 0, 2*math.pi)
local hole = E.Surfaces.arc(CFrame.new(0.5,0.5,0), 0.15, 0, 2*math.pi)
local trimmed, boundaryReport = E.SurfaceTrim.fromCurves(surface, exterior, {hole}, {
    curveTolerance=0.002,
})
local mesh, tessellationReport = E.SurfaceTrim.tessellate(trimmed, {levels=2})
```

## Tessellation

`tessellate(trimmed,options)` triangulates the UV domain, then uniformly splits each triangle into four for `levels` rounds (default 3, range 0–12). Shared midpoint indices keep the mesh conforming, and every child position is evaluated on the exact source surface at its stored UV. Per-corner UVs and analytic normals are retained; `material` sets the face slot. The original trim polygon is preserved subject to native midpoint-coordinate rounding.

This tessellator has **no geometric approximation-error bound**. It reports `geometricErrorBound=false`, plus `method`, `levels`, `triangles`, `vertices`, `boundaryEdges` and the original `parameterArea`. Raising levels improves resolution but does not guarantee triangle quality, world-space tolerance or fair distribution of triangles. Use `adaptive` below for a bounded geometric approximation. The existing uniform API keeps its original behavior.

`maxTriangles` defaults to 200,000 and is checked before subdivision; `maxVertices` defaults to 100,000. Planar validation also uses its input vertex and work limits. `checkpoint(progress)` can yield or throw during validation, each subdivision round and surface evaluation. Input data is not mutated. Samples at singularities, such as a sphere pole included in the domain, reject; this uniform API does not weld periodic trim seams or collapse trimmed poles; the adaptive API below provides those operations. Midpoints that collapse at native UV precision, invalid resulting topology and allocation limits also reject explicitly.

The original `surface` constructor requires one valid domain in the rectangle. Use `regions` below to decompose disconnected, overlapping or wrapped polygonal regions automatically. Automatic repair of self-intersecting source loops and analytic curve-on-surface Boolean trimming remain separate capabilities.

Tests cover polygon and hole classification, area and boundary preservation, rational circular annuli, curved source surfaces, source copies, invalid boundaries, singular samples, cancellation, budgets and native EditableMesh round trips with preserved holes and normals.

## Adaptive trimmed tessellation

`adaptive(trimmed,options)` returns `(mesh,report)` with a geometric approximation bound. It shares the rational Bernstein bound and quadtree partitioner with `SurfaceAdaptive`: for rational-to-bilinear deviation R and bilinear twist magnitude T, any parameter triangle contained in a patch has interpolation error at most `2*R+T/4`. Refinement targets 90% of `tolerance`, reserving space for parameter and seam construction effects. Cells conservatively known to lie outside the trim are retained as coarse partition cells and skipped during refinement.

The native UV partition edges and trim loops form a constrained arrangement over the unit rectangle. Collinear partition intervals are merged before recovery. Triangles are classified by propagating inside/outside labels across edges; trim edges act as barriers. This avoids using rounded centroids to classify very narrow regions. Every retained triangle must fit inside one bounded patch. Shared intersections eliminate cracks between unequal refinement levels. The represented trim loops are checked again for contacts, repeated vertices and reversed orientation after intersection construction.

```lua
local trimmed = E.SurfaceTrim.surface(E.Surfaces.sphere(CFrame.identity,2), {
    Vector2.new(0.25,0), Vector2.new(0.75,0),
    Vector2.new(0.75,1), Vector2.new(0.25,1),
})
local mesh, report = E.SurfaceTrim.adaptive(trimmed, {
    tolerance=0.1, closedV=true,
})
assert(report.converged)
```

The report has `geometricErrorBound=true`, `errorBound`, `faceErrorBounds[faceId]`, `converged`, and an explicit `reason` when the remaining bound exceeds tolerance. Depth/leaf exhaustion returns the valid coarse mesh with nonconvergence. Topology errors, invalid input, unresolved singularities and allocation/work exhaustion throw. No source data is changed and no native instances are created.

Three construction terms supplement the patch bounds:

- `parameterRoundingBound`: patch parameter limits round to native Vector2 coordinates. Positive-weight homogeneous derivative control bounds provide global partial-derivative bounds Lu/Lv. A rectangle displacement `(du,dv)` contributes `2*(Lu*du+Lv*dv)` to triangle interpolation error.
- `trimBoundaryErrorBound`: native arrangement intersections can shift a trim polyline. The measured parameter `constructionError` is multiplied by `sqrt(Lu^2+Lv^2)` to account for its surface-space displacement. This concerns the supplied polygonal trim; the earlier analytic-curve sampling tolerance remains a separate report from `fromCurves`.
- `stitchingError`: the largest actual positional change from sharing coincident periodic or pole samples, bounded by `seamTolerance`. This is added to the interpolation report.

As with `SurfaceAdaptive`, these are computed geometric bounds for the rational control-net model, subject to floating-point extraction/subdivision/evaluation roundoff. They are not outward-rounded interval arithmetic certificates. Native mesh validation also has geometric degeneracy thresholds. Exact classification signs do not imply exact constructed coordinates or permit reliable sub-float32 modeling tolerances. The bound does not limit normal error, triangle aspect ratio, surface folds or global self-intersections.

`closedU`/`closedV` explicitly weld corresponding opposite boundaries. Their partition and trim-contact coordinates are synchronized before triangulation, including unequal active trim ranges on the two sides. Each paired position must coincide within `seamTolerance` (default 1e-6). Per-corner UVs preserve both sides of the seam. A seam interval retained on only one side remains a physical trim boundary. Mismatched underlying surface seams reject.

`collapsePoles=true` detects boundary isocurves whose controls coincide within seam tolerance and shares their mesh vertices. Singular pole normals use a regular interior sample, as in `SurfaceAdaptive`. Parameter triangles mapping to a repeated pole vertex are omitted only when their collapsed image vertices/edges belong to the retained mesh. Their count is `collapsedPoleTriangles`; their UV area remains included in `parameterArea`. Both full closed spheres and partial polar domains are supported. Singular interior samples and nonmanifold quotient domains reject. These options also act on the normalized pieces produced by `regions`. That constructor accepts explicit unwrapped polygonal domains spanning multiple periods; it does not infer an unwrapped path from ambiguous normalized curve samples.

Other report fields are `triangles`, `vertices`, physical `boundaryEdges`, represented `parameterArea`, `originalParameterArea`, represented `trimLoops`, detected `poles`, `leaves` requiring refinement consideration, total `partitionLeaves`, coarse `discardedLeaves`, `refinements`, `work`, all `parameterTriangles` and `retainedParameterTriangles`. The latter include collapsed polar images before mesh emission. `material` assigns emitted faces; corners retain native UVs and analytic or pole-limit normals.

Limits and cancellation:

| Option | Default and scope |
| --- | --- |
| `tolerance` | 0.01 authoring units, positive |
| `maxLeaves`, `maxDepth` | 10,000 total partition leaves; depth 16, maximum 24 |
| `maxVertices`, `maxTriangles` | 100,000 mesh vertices; 200,000 emitted triangles |
| `maxTrimVertices` | 2,000 input boundary vertices |
| `maxParameterVertices`, `maxParameterTriangles` | Default to mesh limits; apply to the complete unit-rectangle arrangement, including excluded regions |
| `maxSegments` | 20,000 source or arranged constraint segments |
| `maxWork` | 5,000,000 counted trim validation, arrangement and traversal units |
| `maxConstructionError` | Optional maximum native intersection displacement in UV units |
| `checkpoint` | Receives records for `begin`, `refine` and `trim` stages; may yield or throw |

These limits bound work rather than promising a fixed frame time. Dense arrangements remain more expensive than untrimmed patch fans. Explicit bounds can be raised for offline authoring. `TrimmedShell` is a callable spherical-band/window example. Tests additionally verify pointwise error inside triangles, affine areas, curved holes, concave/multiple-hole domains, thin strips, pruning, arbitrary knot boundaries, seam topology and UV discontinuities, complete/partial poles, nonconvergence, native round trips, scale/translation/common-weight behavior, invalid seams and cancellation.


## Disconnected and wrapped region sets

`regions(surface, regions, options)` returns `(trimmedSet, decomposition)` with `kind="trimmedSurfaceSet"`, an independent clamped surface, normalized `regions={ {outer,holes}, ... }`, and explicit `closedU`/`closedV` flags. Each input region has one simple exterior and optional simple, disjoint holes. Input winding is normalized. Regions may overlap or meet along an edge: their **union** is retained. Repeated coverage never cancels. An island inside another region's hole remains a separate region; an overlapping filled region can cover a hole. A union with a pinched point boundary rejects explicitly.

```luau
local trimmed, decomposition = E.SurfaceTrim.regions(surface, {
    {
        outer = {
            Vector2.new(0.625, 0.125), Vector2.new(1.375, 0.125),
            Vector2.new(1.375, 0.875), Vector2.new(0.625, 0.875),
        },
        holes = {{
            Vector2.new(0.875, 0.375), Vector2.new(1.125, 0.375),
            Vector2.new(1.125, 0.625), Vector2.new(0.875, 0.625),
        }},
    },
}, { closedU = true })
local mesh, approximation = E.SurfaceTrim.adaptive(trimmed, { tolerance = 0.1 })
```

For a closed direction, coordinates are **explicit unwrapped native Vector2 values**. A loop from U=0.8 to U=1.2 crosses the seam; a loop from U=0.8 to U=0.2 takes the stated segment through the rectangle. No shortest-path or seam-crossing inference changes those segments. Nonperiodic coordinates must stay in [0,1]. Integer translations whose bounding boxes have positive-area contact with the unit rectangle are enumerated, and their filled regions are united there. This supports loops spanning several periods, both periodic directions, seam-crossing holes and concave clips that become disconnected pieces. A bounded filled strip can describe a noncontractible band after periodic identification. Open paths and unbounded universal-cover domains are not input region descriptors.

Clipping uses exact homogeneous expansion arithmetic before native coordinate construction. New intersections are recomputed from their original polygon edge or exact rectangle corner, preventing algebraic degree growth through successive cuts. Binary32 coordinates are selected by exact midpoint comparisons with ties to even. Corresponding periodic cuts therefore receive the same representable seam coordinate. An outward per-vertex displacement bound is reported as `clippingError`. A constrained arrangement then sums signed integer winding across all clipped region boundaries. Positive winding selects the union; oriented boundary extraction separates exteriors, holes and nested islands. Region areas, simple boundaries and winding consistency are checked again after construction. Proper crossings that collapse at native precision, collapsed edges and ambiguous boundary topology reject.

The report includes `complete=true` on success, `regions`, `copies`, `area`, `loops`, arrangement `triangles`/`retainedTriangles`, `work`, `clippingError`, and the Planar arrangement's measured `constructionError`. Empty input returns an empty set with zero area. These two construction errors describe parameter-space construction, not an outward certificate for the entire original Boolean domain or analytic curve boundary. `maxClippingError` optionally gates the outward clipping displacement; `maxConstructionError` independently gates the later arrangement's measured displacement. The descriptor's `parameterConstruction` retains both values as metadata.

`classify` and `evaluate` accept either descriptor kind. Classification is in the represented rectangle: artificial chart cuts can return `"boundary"` even when periodic welding makes them interior to the physical surface. Parameters are not implicitly wrapped. An empty set classifies every point as outside.

`adaptive` triangulates every region together in one synchronized parameter arrangement. It defaults its closed-direction flags from the set, shares seam and pole samples across different pieces, and retains separate corner UV records. The final quotient must have valid manifold edge and vertex topology. Actual surface samples at paired boundaries must satisfy the existing seam-tolerance checks; merely declaring a direction closed does not prove arbitrary underlying surface geometry periodic. Its approximation bounds refer to the **represented normalized regions** after decomposition. They do not silently absorb the constructor's original-domain or analytic-curve approximation errors. `PeriodicTrimWindow` demonstrates a patch and hole crossing a torus seam.

`tessellate` also accepts sets and preserves their disconnected regions and holes. It retains the existing uniform contract: it does not weld periodic boundaries or collapse poles, and reports `periodicWelding=false`. Use `adaptive` for the periodic quotient. Both tessellators snapshot controls, regions and options before callbacks, revalidate directly edited sets for inter-region overlap/contact, and support root cancellation. Empty sets return empty meshes; adaptive reports convergence and zero error.

Region-construction limits:

| Option | Default and scope |
| --- | --- |
| `maxControls` | 10,000 source surface controls; also checked by set tessellation |
| `maxRegions` | 256 input or resulting normalized regions |
| `maxTrimVertices` | 2,000 total input loop entries, including repeated closing points |
| `maxCoordinate` | 1,024 maximum absolute unwrapped coordinate; allowed 1 through 2^20 |
| `maxCopies` | 256 translated region copies considered |
| `maxParameterVertices` | 20,000 clipped loop entries and arrangement vertices |
| `maxParameterTriangles` | 40,000 arrangement triangles, including excluded regions |
| `maxSegments` | 20,000 source or arranged constraint segments |
| `maxWork` | 5,000,000 counted clipping, classification and arrangement visits |
| `maxClippingError`, `maxConstructionError` | Optional nonnegative parameter-space displacement limits |
| `cancelled`, `checkpoint` | Transactional cancellation; constructor checkpoints include `begin`, `decompose`, `finish` and `work` |

Tessellators retain their own limits; their `maxTrimVertices` now bounds all regions together, and `maxRegions` and `maxControls` apply before snapshotting. The uniform tessellator additionally bounds counted work with `maxWork=5000000` and reports that count. Allocation/work exhaustion throws without changing source data. These budgets bound visits and allocations rather than elapsed time. Existing geometric tolerance, native precision and nonconvergence limits still apply.

Twenty-four cases cover analytic region areas, overlap/duplicate union, nested islands, concave disconnected clips, seam/corner disks, bands, closed tori, wrapped holes/poles, negative and translated coordinates, thin-feature rejection, snapshots, edited-domain validation, budgets/cancellation, valid partial approximation and native conversion. The clipping kernel is checked against 160 independent Fraction/400-digit references containing 712 constructed vertices, plus exact native midpoint ties. The previous uniform and adaptive trim suites remain part of the regression.
