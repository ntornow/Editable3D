# Spatial intersection diagnostics

`E.Intersections` classifies segment/triangle and triangle/triangle intersections with exact signs for finite stored native Vector3 coordinates. It also scans meshes with a bounded bounding-volume hierarchy. All operations are read-only. This complements topology validation: an intersection-free report does not check orientation, manifoldness, disconnected vertex fans or solid nesting, and a manifold mesh can still intersect itself.

## Primitive queries

`segmentTriangle(a,b,triangle)` takes two Vector3 segment endpoints and an array of three triangle vertices. It includes endpoint, edge, coplanar and zero-length segment contacts. `triangles(a,b)` takes two three-vertex arrays. Winding can be either direction. Degenerate triangles and nonfinite/non-native inputs reject; near-degenerate but exactly nonzero native triangles are supported without epsilon snapping.

The return record contains:

- `kind`: `"none"`, `"point"`, `"segment"` or `"polygon"`; `dimension` is respectively -1, 0, 1 or 2.
- `classification`: `"none"`, `"contact"`, `"crossing"` or `"overlap"`. A transverse segment passing through the triangle interior is a crossing. A positive-length noncoplanar triangle intersection is a crossing only when it traverses the interiors of both triangles. Positive-area coplanar intersections are overlaps. Remaining nonempty cases are contacts.
- `coplanar`: the segment lies in the triangle plane, or the two triangles share a plane.
- `points`: constructed native Vector3 positions; `coordinates`: corresponding `{x,y,z}` arrays of binary64 quotient estimates. Segment endpoints are ordered lexicographically by exact constructed coordinates. Polygon vertices follow a convex boundary, counterclockwise in a dominant coordinate projection of the first triangle.
- `pointData`: position/coordinate records with nonnegative rational `barycentricA` and, for triangle pairs, `barycentricB` arrays. In `segmentTriangle`, A refers to the triangle. Weights are binary64 estimates and sum to one subject to arithmetic roundoff.
- `exactVertices`, `maxRoundingError` and `constructionComplete`: exact distinct vertex count, maximum measured native rounding displacement from the binary64 quotient estimates, and whether the native vertices retain their count and a usable convex boundary.

`kind` and `dimension` describe the exact intersection of stored input coordinates. They do not depend on whether output Vector3 coordinates can represent that intersection. Two distinct exact endpoints can round to the same native position; the result remains `kind="segment"` with `constructionComplete=false`. Polygon vertices may similarly merge or lose convexity when rounded. Consumers constructing new topology must handle this flag explicitly. `maxRoundingError` measures coordinate conversion; it is not an interval certificate for every floating-point operation.

Plane-side and directed line/triangle tests use the package's exact orientation predicates. Coplanar triangle area classification uses separating edge signs. Segment clipping constructs intersections in homogeneous expansion arithmetic; distinct points and endpoint ordering compare those rational coordinates before rounding. Coplanar polygon boundaries are assembled from their oriented source-edge intervals, avoiding coordinate-based angular sorting. Expansion products remain within binary64 range for the supported native coordinate exponents; previously lost or flushed native coordinates cannot be recovered.

```lua
local v = Vector3.new
local hit = E.Intersections.triangles(
    {v(-1,-1,0), v(1,-1,0), v(0,1,0)},
    {v(0,0,-1), v(0,0,1), v(0,2,0)}
)
assert(hit.classification == "crossing" and hit.kind == "segment")
```

## Mesh scans

`mesh(source,options)` returns `(hits,report)` for self-intersections of the mesh's triangulated faces. Simple polygon faces use robust triangulation; malformed, self-crossing or degenerate faces reject instead of disappearing from the scan. Nonplanar polygons use that piecewise-triangle interpretation. Vertex/face IDs, corner indices and all attributes remain unchanged.

A point contact between triangles sharing exactly one vertex ID, or a segment contact between triangles sharing exactly two vertex IDs, is excluded by default. This includes valid triangulation diagonals. Shared identity alone never excludes a larger intersection: a crossing extending beyond a common vertex or a coplanar area overlap along a common edge is still reported. `includeAdjacent=true` retains the excluded records with `ordinaryAdjacency=true`. Such a record only describes the shared geometric feature; edge incidence and manifoldness still need topology validation.

`between(a,b,options)` scans all pairs across the two operands, with separate vertex-ID spaces. It performs a two-operand query even when both arguments reference the same mesh object. Thus identical operands report overlapping coincident triangles. It does not compute solid containment: one closed boundary can lie entirely inside another without their surfaces intersecting.

Each hit adds `faceA`, `faceB`, deterministic triangle indices `triangleA`/`triangleB`, source `verticesA`/`verticesB`, `cornersA`/`cornersB` and `ordinaryAdjacency`. Multiple triangle pairs from the same two polygons remain separate records. Coplanar adjacent output segments are not automatically stitched into face-level intersection curves.

Report fields:

- `complete`, optional `reason`, `intersectionFree`, and `surfaceCrossing`.
- `crossings`, `overlaps`, `contacts`, `ordinaryAdjacencies`, and `reported` hit counts.
- `trianglesA`, `trianglesB`, actual narrow-phase `tests`, `nodePairs`, `work`, and `selfQuery`.
- `constructionFailures` and `maxRoundingError` for discovered nonempty intersections.

`intersectionFree=true` requires a completed scan with no crossings, overlaps or unexpected contacts. It excludes ordinary shared features, even when those are requested in the hit list. `includeContacts=false` omits unexpected contact records from `hits` while still counting them and preventing an intersection-free claim. `surfaceCrossing` records whether any transverse crossing or coplanar overlap was found; it can be false in an incomplete scan that has not reached an existing crossing.

```lua
local hits, audit = E.Intersections.mesh(mesh)
assert(audit.complete, audit.reason)
assert(audit.intersectionFree, "Repair the reported geometry before treating it as embedded")
```

Limits default to `maxTriangles=500000` across prepared operands, `maxTests=1000000`, `maxIntersections=10000`, and `maxWork=5000000`. Face triangulation uses `maxFaceVertices=2000` and `maxFaceWork=maxWork`. Input/index allocation or preparation exhaustion throws. Once pair traversal begins, reaching the work, test or report limit returns partial hits with `complete=false`, `intersectionFree=false` and a reason. Reaching the report limit is conservatively incomplete even if that hit might have been the last. Checkpoints receive `{stage,work,triangles}` initially and every 256 counted work units during preparation, indexing or traversal, and may yield or throw.

The hierarchy uses exact axis-aligned input bounds for rejection, median splits and deterministic pair traversal. It improves separated/local geometry scans; deeply overlapping geometry can still require quadratic pair work. Bounds are in mesh coordinates: transform a source mesh explicitly before comparing it with another coordinate frame. No tolerance expansion, near-contact distance search or automatic repair occurs.

## Checked Booleans

`Boolean.apply/union/intersect/subtract(...,{checkIntersections=true})` requires complete intersection-free scans of both inputs and the output, in addition to the existing topology checks. Reports include `inputIntersections.a`, `inputIntersections.b` and output `intersections`. `intersectionOptions` supplies scan budgets/checkpoints. An incomplete scan or geometric defect throws; `allowInvalid` only relaxes the older topology gate and does not bypass this explicitly requested geometric check. Without this option, the existing BSP behavior and cost remain unchanged.

These checks do not change the BSP construction into an exact-predicate Boolean kernel or repair touching inputs. Unwelded contacts are deliberately strict under this option. The callable `IntersectionAudit` example inspects crossing box boundaries, then performs a checked union.

## Verification and remaining work

`tools/intersection_fixtures.py` uses independent Python Fraction arithmetic and half-plane clipping to generate 216 exact fixtures. The tests verify their dimension, plane relation and classification under operand/winding permutations, including native exponent scales, near-coplanar separation and rounded endpoint collapse. Additional tests cover barycentric data, ordered overlap polygons, cancellation-safe construction, shared-feature exclusions, BVH results against exhaustive pair checks, rigid/scale transforms, budgets, strict Boolean volumes/input rejection and native EditableMesh round trips.

[INTERSECTION_REPAIR.md](INTERSECTION_REPAIR.md) documents implemented source-sheet splitting and bounded solid repair. [BOOLEANS.md](BOOLEANS.md) adds audited arrangement Booleans with independent operand winding regions. Broader near-coincident tolerance regularization, mesh-level curve assembly and analytic/adaptive surface intersection queries remain active work. Diagnostic classification is complete only for the submitted triangulated geometry; it does not certify an unsampled rational surface.
