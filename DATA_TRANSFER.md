# Data projection between mesh topologies

`Attributes.project(source, target, options?)` returns `(mesh, report)`. It leaves both inputs unchanged and retains the target's positions, faces and IDs. Source and target must have valid oriented topology; open sheets and loose target vertices are supported. Projection uses triangles from selected source faces, so loose source vertices do not participate. It creates no native objects.

```lua
local result, transfer = E.Attributes.project(reference, rebuilt, {
    names = {"temperature", "region", "uv_seam"},
    maxDistance = 0.5,
    cornerMode = "chart",
    masks = {vertex = vertexMask},
    factor = 0.8,
})
assert(transfer.complete)
```

## Domain correspondence

| Target domain | Source sample |
| --- | --- |
| Vertex | Nearest selected surface triangle; its barycentric weights interpolate source vertices |
| Face | Nearest triangle to the arithmetic mean of the target face's vertices; the contributing source face supplies the value |
| Corner | Nearest triangle within the connected source chart selected by the target face's center; barycentric interpolation uses source face corners |
| Edge | Nearest source perimeter segment to the target edge midpoint; the source edge supplies the value |

BVHs accelerate surface, chart and edge queries. Exact equal-distance corner samples in chart mode prefer faces with fewer connected-face steps from the target face's source anchor, then stable source order. This distinguishes the two sides of a periodic UV seam even when both sides belong to one connected chart. Other exact ties use stable source order. Native coordinates and nearest-point calculations remain floating-point; nearly tied cases can change their selected primitive under transforms. At medial-axis points several nearest source positions can be equally valid. Reports retain the actual correspondence rather than implying a unique geometric inverse.

Source charts connect across manifold edges only where material, intrinsic corner fields, typed corner channels and typed face channels agree at both endpoints. Normal/tangent vectors do not define chart discontinuities. Comparison tolerances are `uvTolerance=1e-6` and `attributeTolerance=0`; categorical values compare exactly. Positive numeric or true boolean `sharp_edge`, `uv_seam`, `subdivision_edge_sharpness` channels and optional `seamAttributes` also separate charts. Disconnected source sheets remain separate charts.

The default `cornerMode="chart"` keeps each target face in one source chart. A target face spanning a source seam samples the closest positions within its chosen chart, which can clamp its corner values to the chart boundary. It does not insert new target edges at that seam. Use suitably aligned target topology, `sourceFaces`, or explicit source correspondence when exact seam location matters. `cornerMode="nearest"` instead queries each corner against the entire selected source surface and can cross chart boundaries.

Edges query source polygon perimeter segments, including interior mesh edges, but excluding triangulation-only diagonals. Nearest-edge transfer can spread a marked source edge onto several target edges. It does not detect a corresponding topological edge chain or guarantee preservation of a sharp feature. `maxDistance` applies to segment distance too, so a target interior edge can be far from source edges while lying on the source surface.

## Data selection and blending

`names` is an optional array of source channel names; omitted means all. An empty array disables typed channel transfer. Selected schemas must agree with an existing target channel's domain, type, default and interpolation. Missing selected schemas are added with their source defaults. Unselected target channels remain intact. Source channel interpolation policies apply to both barycentric samples and partial blends, including nearest categorical choices and min/max reductions. Zero mask values leave existing target values intact; newly added schemas resolve to their default there. Explicit false values remain valid sparse data.

`corners`, `materials`, `groups`, and `weights` each default to true and control additional intrinsic data. Intrinsic corner fields interpolate numerically or use nearest contribution for strings/booleans; sampled fields overlay the existing target corner. Normal/tangent directions are normalized, with tangents reprojected against the normal. Face materials replace at a blend weight greater than one-half. Group values blend linearly; unrelated target group names survive. Skin weights blend over the combined bone-ID set and normalize a nonzero total. Bone IDs must already refer to the intended common rig; this API does not retarget skeletons.

`factor` lies in `[0,1]` and defaults to one. `masks` is an optional dictionary of `vertex`, `edge`, `face`, and `corner` dictionaries using target IDs. Values are booleans or numbers in `[0,1]`. An omitted domain is fully active; missing entries in a supplied domain mask are zero. The effective factor is the product. Vertex masks also control skin/groups, face masks control materials, and corner masks control intrinsic fields. Face-center anchor queries may run for active corners even when the face data mask is zero.

`sourceFaces` optionally restricts sampling to a source face selection, with true or positive numeric values selecting faces. Default sampling includes every source face. This is useful for selecting a particular shell or side before transferring close, overlapping geometry.

## Completion, limits and cancellation

`maxDistance` defaults to infinity and includes its boundary. A required query with no source within this distance rejects by default. Set `unmatched="keep"` to retain unmatched target data and return `complete=false`; newly created channel elements use defaults. `unmatched="error"` is the default. Zero factor makes no sampling queries.

The report contains `complete`, `sourceCharts`, `queries`, `work`, `maxSourceDistance`, matched counts and unmatched element sets for each domain. Face counts include chart-anchor queries. `chartTieSearches` and `chartTieReferences` measure connected-face traversal used for ambiguous corner samples; the cache retains at most sixteen anchor maps and traversal counts toward the work budget. `maps` records the actual weighted source references in the same format as `Attributes.transfer`; identity is disabled in every domain. These maps describe samples before masks and partial blending. They do not include skin normalization or intrinsic normal normalization.

Defaults are `maxElements=2000000` for each connectivity index, `maxQueries=2000000`, and `maxWork=5000000`. Work counts BVH construction/comparisons, queries, chart traversal and channel writes; connectivity has its own element limit, and each source polygon triangulation uses the supplied work limit separately. These are algorithmic limits rather than elapsed-time guarantees. `checkpoint({stage="project",work,queries,maxWork})` and `cancelled()` run at entry, periodic work boundaries and completion. Throwing or returning cancellation aborts transactionally. Bounds, masks, schemas and invalid source/target topology reject explicitly.

Projection does not alter geometry, detect global self-intersections, guarantee a bijection, create a bake cage or solve UV overlaps. These restrictions distinguish data sampling from retopology and geometric repair.

## Voxel integration

`Remesh.voxel(mesh, cellSize, options?)` and `Remesh.boolean(a,b,operation,cellSize,options?)` now return `(mesh, report)` and project source data by default. Existing single-result callers still receive the mesh. Pass a projection options table as `options.transfer`, or `transfer=false` for geometry-only reconstruction. The latter retains the previous geometry while explicitly skipping source data. Analytic `Remesh.fromField` has no source channels and still returns one mesh.

Voxel reconstruction remains marching tetrahedra over a sampled signed-distance field. Data is sampled from the original source surfaces after geometry construction; it is an approximation, not exact constructive provenance. Booleans join both source schemas, reject conflicts, optionally apply numeric `materialOffsetB`, and reverse cutter corner orientation for subtraction. `inputMaps` and `sourceRefs` relate the joined projection source to original A/B domain keys, including reversed cutter corners. If an operand lacks a channel, its source elements resolve to the joined schema default. Proximity can choose a geometrically hidden source sheet near a Boolean junction; explicit transfer source restrictions and distance limits are available where semantic ownership matters.

Reports include geometry `validation`, `transferred`, `sourceTriangleSamples`, optional `projection`, and `complete`. Completion means valid output topology and completed requested data queries; it does not certify geometric accuracy, feature quality or absence of global intersections. A partial projection with `unmatched="keep"` makes the combined result incomplete.

Cell size and bounds must be finite. Defaults: `maxCells=250000`, `maxVertices=500000`, `maxFaces=500000`, and `maxSourceTriangleSamples=10000000`. The last is the grid sample count multiplied by source triangle count, bounding winding-number work before sampling. Analytic fields do not use that source limit. `checkpoint` and `cancelled` run before work and at grid layer boundaries; the top-level callbacks also feed projection unless overridden in `transfer`. `yieldEvery` remains an optional positive integer number of layers. Padded bounds are generated for mesh-based reconstruction; explicit analytic-field bounds can produce an open surface if the isosurface reaches the box.

`Examples.ProjectedRemesh` demonstrates voxel reconstruction with a preserved scalar channel and source group. Projection tests independently check affine values, distances, domain masks, sparse IDs, chart boundaries, source restrictions, transforms, unmatched results, budgets, source immutability and native skinned export.
