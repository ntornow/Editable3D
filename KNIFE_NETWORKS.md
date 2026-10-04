# Constrained planar domains and knife networks

`Planar.constrain(outer, holes, paths, options)` triangulates a simple polygon with disjoint holes while retaining every supplied finite path segment. Boundaries follow `Planar.triangulate` rules. Each path is an array of at least two finite native Vector2 points. Endpoints can be inside the domain or on its boundary; paths may cross, touch, overlap, retrace, branch through shared points or close by repeating their first point. A closed path retains the domain on both sides; it does not create a hole. Supply excluded regions in `holes`.

```lua
local v = Vector2.new
local domain = E.Planar.constrain(
    {v(0,0), v(8,0), v(8,8), v(0,8)}, {},
    {{v(0,4), v(8,4)}, {v(4,0), v(4,8)}, {v(1,1), v(2,2)}}
)
local mesh = E.Planar.toMesh(domain)
```

The engine arranges all source segments using exact signs, inserts shared crossing/overlap points and triangulates the boundary domain. Interior points split containing triangles or shared edges. A queue of convex diagonal exchanges recovers the constrained edges and preserves already recovered constraints. This handles recovery regions with pinched boundaries. The output is a constrained triangulation, without a Delaunay or minimum-angle guarantee. All triangles have positive projected orientation; boundary incidence/winding, paired interior edges, total area, retained constraints and the Euler count are checked before success.

The result includes `points`, `triangles`, `boundaryLoops`, `area`, `holes` and `complete=true`, plus:

- `inputPaths[pathIndex]`: point indices for the original path points.
- `paths[pathIndex]`: ordered point indices including every inserted intersection. Closed and retraced paths retain their order and repeated visits.
- `constrainedEdges["smallerId:largerId"]`: `{a,b,boundary,paths,sources}`. `paths` is a set of source path indices; `sources` lists `{kind="boundary"|"path",group,segment}` occurrences, including repeats.
- `constructionError`: maximum measured distance between an inserted native point and each original segment on which it was inserted.
- `work`, `recoveredEdges` and `edgeFlips`: measured work and recovery counts.

Classification signs are exact for stored native coordinates; constructed intersections remain float32 Vector2 values. Paths become piecewise linear through those represented points. Coincident represented points share one identity, including distinct constructions that round to the same point. This is a native-precision arrangement, not exact algebraic coordinate construction. A proper crossing rounded onto one of its own segment endpoints, indistinguishable segment ordering, an unresolved crossing/overlap after rounding, invalid domain or failed recovery rejects explicitly. `maxConstructionError` optionally bounds the reported deviation; zero accepts only constructions lying exactly on their source segments. No epsilon welding or automatic domain repair is performed.

All path pieces must remain inside the domain or along its boundaries. Crossing a concavity or entering a hole rejects. Simple disjoint holes may be connected to each other or the exterior by constraints. Touching/nested input holes and disconnected exteriors still require separate domains. Inputs are copied. Defaults are `maxVertices=10000`, `maxSegments=20000` (applies to both source and arranged segments), `maxTriangles=20000`, and `maxWork=5000000`. `maxTriangulationWork` optionally limits each initial triangulation as well as the total work limit. Budget exhaustion or cancellation throws; `checkpoint(progress)` is called initially and every 256 counted work units. Extremely small triangles can pass planar predicates yet fall below Mesh validation's geometric threshold.

## Face-local mesh networks

`MeshEdit.knifeNetwork(mesh, strokes, options)` returns `(newMesh,report)` and leaves the source unchanged. A stroke is `{face=sourceFaceId,path={point,...}}`. Multiple strokes may target the same planar face. Any path point can be:

- A native Vector3 strictly inside the source face and within `planeTolerance=1e-5` of its plane, including free interior endpoints.
- `{corner=i}`, using the source face's one-based corner index.
- `{edge=i,t=fraction}`, along the directed source edge from corner `i` to the next corner, with `t` strictly inside `(0,1)`.

Boundary contacts must use topological descriptors. Interior coordinates retain their two dominant projection components; the third component is reconstructed on the source face plane. Crossing, closed, overlapping, retraced and self-crossing paths have the same arrangement semantics as `Planar.constrain`. Whole strokes must stay within their specified face. This API does not perform screen picking or automatically trace a 3D stroke across multiple source faces.

```lua
local detailed, report = E.MeshEdit.knifeNetwork(E.Primitives.box(), {
    {face=5,path={{edge=1,t=0.5},{edge=3,t=0.5}}},
    {face=5,path={{edge=2,t=0.5},{edge=4,t=0.5}}},
})
assert(detailed:validate().closed)
```

Selected faces become oriented triangles, with the first triangle retaining the source face ID. Existing vertices keep their IDs. Boundary cuts use a canonical global edge direction and identical native positions reuse one vertex. Every incident neighbor receives the same edge points, even without its own stroke; those neighbors retain their polygons and face IDs. A selected face with only boundary-following strokes is also triangulated. Empty stroke arrays return an independent mesh copy.

New interior vertex, skin and group data use nonnegative barycentric interpolation in a containing original source triangle. Corner data interpolates separately for each face, preserving intrinsic and typed UV seams. All output triangles inherit their source face channels and material. Split source edges inherit their edge channels; new interior edges use schema defaults. Geometry edits recalculate normals; use `Normals` afterward for a chosen custom shading policy. Generic typed vector values are interpolated without an implicit geometric transform.

Reports include the shared edit correspondence maps and added/replaced IDs, `faceMap[sourceFaceId]`, `paths[strokeIndex]` as mesh vertex IDs, `complete`, `work`, and the maximum projected `constructionError`. Each `networks[sourceFaceId]` gives the mesh vertex IDs corresponding to planar point indices, constraint edges with global source stroke sets, construction error and recovery statistics. Unstroked neighbors changed by edge cuts appear in `faceMap`.

Mesh allocation and validation limits follow [MESH_EDITING.md](MESH_EDITING.md). Additional defaults are `maxPathPoints=10000` over all strokes, `maxNetworkVertices=10000`, `maxNetworkSegments=20000`, `maxNetworkTriangles=20000` per selected face, and `maxWork=5000000` across network work for the whole call. `maxFaceWork` also bounds each seed triangulation; `maxConstructionError` applies in projected coordinates. Checkpoints may receive numeric progress from connectivity or builder records `{stage,vertices,faces}`. Failures leave the source and all attributes intact. Final mesh validation checks topology and local geometry; global 3D intersection certification remains separate work.

`MeshEdit.knife` remains available for a single simple boundary-to-boundary cut that produces two polygons. Its existing restrictions and return shape are unchanged. Use `knifeNetwork` for finite interior endpoints and simultaneous arrangements.

## Verification

The tests check independent domain area and closed-solid volume, holes, grids, free endpoints, crossing/T junctions, self-crossing/closed/retraced paths, overlap provenance, pinched recovery regions, deterministic randomized networks with reversed input order, thin/translated coordinates, all attribute domains, UV seams, skin/groups, neighboring-face conformity, rigid transforms, repeated edits, native EditableMesh conversion, construction error bounds, cancellation and allocation/work limits. The callable `KnifePanel` example builds a closed box with crossed and closed panel strokes.
