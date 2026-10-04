# Feature-guided quad retopology

`Remesh.quads(mesh, targetLength?, options?)` returns a detached mesh and report. It accepts valid oriented manifold polygon meshes, including open boundaries, holes, disconnected components and loose vertices. It creates conforming four-corner faces while protecting source boundaries, marked features and data discontinuities. It does not repair invalid input topology.

```lua
local quads, report = E.Remesh.quads(source, 0.5, {
    pins = { [cornerVertex] = true },
    maxDeviation = 0.05,
    minimumScaledJacobian = 0.3,
    maximumAspectRatio = 4,
})
if not report.complete then
    print(report.reason, report.applied)
end
```

## Construction and guidance

The operator snapshots input geometry, data, pins and nested options before invoking callbacks. It triangulates each source polygon using the mesh's normal geometric definition, then uses these stages:

1. Optional fixed-reference quadric coarsening. Boundary vertices, explicit pins, feature endpoints and attribute seams remain fixed. `targetTriangles` requests an explicit intermediate triangle count. Otherwise a supplied length field estimates this count by summing `triangleArea / (2 * lengthAtCentroid^2)`. This estimate guides coarsening; it is not a promised final face count. `coarsen = false` disables the stage. The simplification contract in [SIMPLIFICATION.md](SIMPLIFICATION.md) applies to each collapse.
2. Conforming longest-edge refinement. An indexed edge incidence table and a deterministic maximum heap select oversized edges. Each split creates one shared native midpoint and splits every incident triangle, retaining an integer reference chart in its original triangle. The intermediate target length is twice the requested final length. Its default split threshold is `4/3`.
3. Deterministic triangle pairing. Candidates cross only eligible interior edges and must form strictly convex projected quads. Higher minimum corner scaled Jacobian takes precedence, then lower edge aspect ratio, then edge-key order. Each candidate must satisfy the shape controls and remaining displacement budget. A rational common-chart calculation checks any change of geometric triangulation.
4. Corner quadrangulation. A triangle becomes three quads; a paired quad becomes four. Adjacent patches share edge midpoints. Original patch vertices remain, and each patch receives a face-center sample. This construction introduces extraordinary vertices at unpaired triangles. It does not promise a globally optimal or all-valence-four quad layout.

All source boundary samples remain at their original IDs and positions. Feature edges may become chains of shorter edges. Their original endpoints remain, and their edge data transfers to the chain. Native rounding of newly constructed positions is included in the surface-distance bound; a subdivided chain is not asserted to lie exactly on its original real-arithmetic line.

Pairing cannot remove an edge with nondefault typed edge data. Positive numeric or true boolean values in `sharp_edge`, `uv_seam`, `subdivision_edge_sharpness` or named `seamAttributes` also protect edges, including values inherited from the channel default. Material changes, intrinsic corner fields except derived normals/tangents, and typed corner/face discontinuities protect their shared endpoints and edges. `uvTolerance` and `attributeTolerance` default to zero. Normal generation alone does not prevent pairing. `featureAngle` defaults to 45 degrees and protects larger changes between adjacent face normals. Angles use radians.

## Density, shape and completion

`targetLength` may be omitted, a positive finite scalar, or `function(position) -> positiveFiniteLength`. The field is sampled at initial triangle centroids for automatic coarsening and at native edge midpoints for refinement and final measurements. It should be deterministic and free of side effects. It can vary spatially; discontinuous or rapidly varying fields can produce valid partial results. These are point-sampled length targets, not certified bounds on a continuous field throughout faces.

| Option | Default | Meaning |
| --- | --- | --- |
| `minimumEdgeRatio` | `0` | Minimum final edge length divided by its midpoint target |
| `maximumEdgeRatio` | `4/3` | Maximum final edge length divided by its midpoint target |
| `minimumScaledJacobian` | `0.1` | Minimum corner cross product projected onto the unit Newell face normal, divided by the two adjacent edge lengths |
| `maximumAspectRatio` | `10` | Maximum longest-to-shortest edge ratio within a quad |
| `splitThreshold` | `4/3` | Intermediate refinement edge-length ratio threshold |
| `maxDeviation` | `0.01 * sourceBoundsDiagonal` | Maximum composed whole-surface displacement bound |
| `maxNormalAngle` | `pi/3` | Maximum sum of stage normal-change measurements; must be below `pi/2` |
| `featureAngle` | `pi/4` | Geometric edge delimiter; must be below `pi/2` |
| `normalAngle` | `featureAngle` | Final connected-fan normal smoothing angle |
| `maxCoarsenIterations` | `500` | Soft collapse-iteration limit |
| `maxSplits` | `5000` | Soft shared-edge split limit |
| `maxDepth` | `16` | Maximum source-chart refinement depth, in `[0,24]` |

Shape measurements use stored native coordinates and scalar-double arithmetic. Projected polygon convexity and orientation use exact native predicate signs. Shape ratios, normal angles and target-field sampling are numerical diagnostics, distinct from the certified displacement bound. The normal-angle comparison permits `2^-42` radians of numerical slack. The operator ranks useful candidate pairs and adapts density; it does not solve a global direction-field or quad-quality optimum.

`report.quality` contains `minimumScaledJacobian`, `maximumAspectRatio`, minimum/maximum corner angles, minimum/maximum sampled edge ratios, `badFaces`, `shortEdges`, `longEdges`, `shapeMet` and `densityMet`. Ratios are absent or zero when there are no sampled edges. `complete` requires valid all-quad output, both measured targets and any explicitly requested intermediate coarse count. An automatic coarse-count estimate need not be met if the final requested quality and density are met.

`applied = true, complete = false` means a valid result was built but a shape, density or explicit coarse target remains unmet. Reasons are `shapeTarget`, `densityTarget` or `coarseningTarget`. Refinement limits and protected geometry can cause this outcome. `requireComplete = true` throws instead of returning a partial. A purely triangular source increases its face count during the last construction stage; use coarsening or a larger density target when reducing an already dense input.

## Geometry certificate and transactional audits

`report.errorBound` encloses the symmetric Hausdorff distance between the complete original polygon surface and returned polygon surface, using their actual stored triangulations. The stages establish surjective correspondences:

- Coarsening uses the checked original-triangle to output-triangle/edge/vertex correspondence described in the simplification guide.
- Refinement retains a partition of each original triangle in an integer barycentric chart. Every final chart triangle has positive area, and the areas sum to the original chart area. Exact expansion arithmetic measures each stored output corner against its reference affine point; directed interval norms bound its displacement. The maximum corner bound controls every point of each affine image in both directions.
- Pairing and corner quadrangulation use canonical integer triangle/square charts. Positive triangulation areas, complete coverage and nonoverlap are checked. Rational vertices of the common subdivision suffice to maximize the norm of the affine displacement in each cell. Exact expansion arithmetic and outward intervals enclose the resulting norms, including native midpoint and center rounding.

The final bound is an outward sum of stage bounds. It can conservatively exceed the true closest-surface distance. A zero tolerance rejects constructions with a positive certified rounding error, even if they look planar. Large translations can collapse a proposed native midpoint; that causes transactional rejection.

Component Euler characteristics and boundary-loop counts are checked after triangulation and quadrangulation. Final meshes must be oriented manifolds with valid projected convex quads and nondegenerate triangles. Protected original vertices are checked again. By default, exact native-coordinate `Intersections.mesh` scans audit both endpoints. Introduced intersections, incomplete endpoint scans, invalid native geometry, topology changes and exceeded geometric bounds return the original polygon input with `applied = false`, `complete = false` and zero returned displacement. Candidate diagnostics remain in the report. `checkIntersections = false` explicitly skips those scans and sets `intersectionChecked = false`.

The audit certifies endpoint surface intersection status. It is not a collision-free animation path between meshes. Per-stage normal changes compare corresponding positive-area triangles; the report sums their maxima as a conservative numerical stage diagnostic. Normals on collapsed lower-dimensional images are not defined.

## Data and correspondence

Vertex, edge, face and corner typed schemas transfer using their declared interpolation modes. Refinement's new vertices and corners reference original triangle barycentric coordinates. Pairing averages eligible source-corner values using source face areas; compatible typed face values inherit equally from the paired faces. Quadrangulation blends adjacent endpoints and face corners. Split edge chains inherit their parent edge data; newly generated interior edges receive schema defaults. Material slots remain with their originating patch. Skin weights and named groups interpolate at new vertices. Original loose vertices and their data survive.

Corner normals are recomputed after geometry audits; tangent vectors and tangent signs are cleared on final generated corners. Explicit sharp metadata and `normalAngle` govern regenerated normals. If tangents are needed, run `Normals.tangents` on the result. The report's `stages` retains triangulation maps, optional coarsening maps, density references/maps, pairing maps, and quadrangulation child/edge/center maps. These are stage-local maps; compose them in stage order to trace data back to the original polygon input.

## Bounds and callbacks

| Hard cap | Default |
| --- | --- |
| `maxVertices` | `20000` |
| `maxFaces` | `40000` |
| `maxCorners` | `160000` |
| `maxTriangles` | `80000` |
| `maxFaceVertices` | `2000` |
| `maxAttributes` | `256` |
| `maxDataEntries` | `1000000` source sparse/intrinsic/group/skin entries |
| `maxWork` | `50000000` charged visits |

Allocation caps apply to intermediate and final geometry as well as input. Work counts geometry visits, heap comparisons, candidate sorting and bounded charges for whole-domain validation/data transfer. Nested coarsening, normal generation and intersection work consume the root budget. Refinement updates edge incidence locally; it does not rebuild all topology for every split. Coarsening and endpoint scans can still dominate runtime. Candidate searches are bounded algorithms, not guaranteed interactive-time operations. Caller-supplied fields and callbacks are outside the instruction-count model.

`cancelled()` is checked at entry, during charged work, around callbacks and at completion. `checkpoint({stage, work, ...})` receives detached status values. Nested `intersectionOptions` callbacks and cancellation compose with the root callbacks and limits. Invalid inputs/options/data, hard cap exhaustion and cancellation throw without modifying the caller's mesh. Soft iteration, depth and target limits are reported as described above.

The verification suite covers analytic planar/warped patches, 96 independent rational overlay cases, 64 independent high-precision barycentric bounds, closed/holed/periodic topology, typed data and skin/groups, seams and pins, scales/translations, snapshots, hard/soft limits, introduced intersections and native EditableMesh conversion. `tools/generate_quad_patch_fixtures.py` regenerates the independent references. `QuadRetopologyPanel` is a callable example.
