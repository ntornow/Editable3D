# Edge and vertex bevels

`MeshEdit.bevelEdges(mesh, selected, width, options)` and `MeshEdit.bevelVertices(mesh, selected, width, options)` return `(newMesh, report)` without changing the source. `selected` is an edge-key or vertex-ID dictionary. Boolean true selects the full width; numeric weights in `[0,1]` multiply it. False, zero and missing keys do not select an element. Width is positive and finite. Edge bevel measures the perpendicular offset inside each incident source face. Vertex bevel measures distance along each incident source edge. These distances agree at right angles but are different definitions in general.

```lua
local box = E.Primitives.box(Vector3.new(4,2,3))
local rounded, report = E.Modifiers.bevel(box, 0.15, {
    segments=4, profile="round", join="patch",
})
assert(rounded:validate().closed)
```

Normal edge bevel requires exactly two incident faces, consistent with the [Blender bevel tool's topology requirement](https://docs.blender.org/manual/uk/5.0/modeling/meshes/editing/edge/bevel.html). Vertex bevel also supports open surface boundaries. The package implementation supports concave solids, reentrant edges, reflex planar polygon corners, partial selections, unequal selection weights and higher-valence junctions. It is not limited to the older `Modifiers.bevelConvex` clipping routine.

## Face offsets and topology

Inputs must have valid oriented topology and simple planar polygons. Affected source faces are checked with `planarTolerance=1e-5`; triangulate nonplanar polygons explicitly before beveling them. The operator retains source face IDs and untouched vertex IDs. A selected vertex's old ID disappears when no resulting face uses it. Reports describe newly allocated IDs and corner paths; exact coincident junction samples may be merged, with aliases recorded in `mergedVertices`.

For an edge bevel, a face corner touching two selected edges moves to the intersection of their offset lines. `miterLimit=16` bounds displacement divided by the larger local edge offset. Compatible straight offsets are supported; incompatible parallel constraints reject. A corner touching one selected edge slides along the other edge when that forward intersection exists. At a reflex or straight termination that cannot slide forward, the offset point connects back to the original corner. Remaining incident face sectors are trimmed to connect the junction. Every cut on an unselected edge is inserted into incident faces where that segment survives, avoiding T junctions when the two faces request different cut distances.

Vertex bevel replaces every selected face corner by a profile between the two incident edge-cut points. At open vertices this becomes part of the surface boundary. At interior vertices the remaining hole receives a junction patch. Adjacent vertex cuts, edge rails or offsets that consume/reverse source edges or leave a required source polygon reject. Width is not automatically reduced, and the operator does not silently clamp an oversized request.

## Profiles

`segments` ranges from 1 to 64. One segment produces a straight chamfer. Multiple segments use `profile="round"` by default, or `"linear"` for a subdivided straight chamfer. At an edge endpoint, the profile is evaluated in a plane perpendicular to the selected edge, while its axial coordinate interpolates between the two face rails. Equal offsets yield a circular arc tangent to the incident face directions. Vertex profiles use the source face's normal as the profile-plane axis.

Flat coplanar edges use linear profiles, counted in `flatProfiles`. If a circular construction is unavailable because of degenerate or unequal native rail measurements, the round profile uses an affine quarter-circle construction in the two rail directions and increments `affineRoundProfiles`. This distinction is explicit in the report. Profile construction and spherical compatibility use positions relative to the original vertex before final conversion to world coordinates, reducing translation-dependent native rounding.

For a custom profile, pass an array of finite Vector2 coefficients. It must start at `(1,0)`, end at `(0,1)`, decrease monotonically in X and increase monotonically in Y, with no identical adjacent samples. Coordinates lie in `[0,1]`, and the array contains 2–129 samples. The profile is sampled by linear interpolation in sample-index parameter at each of the requested segment fractions. Its X/Y coordinates multiply the two radial rail vectors from the original edge/vertex; the axial coordinate still interpolates linearly. More source samples than output segments can therefore lose small profile features; choose the segment count accordingly. Custom profiles are not automatically resampled by arc length.

## Junctions

`join="patch"` is the default. Boundary loops are built from the remaining oriented face/strip edges at each affected vertex. A star-shaped loop gets a center and a triangle/quad patch. When at least three round edge profiles agree on a common sphere within `width*1e-5`, the center and radial rings lie on that sphere, recorded in `sphericalJoins`. This covers rounded box corners and compatible regular junctions. The default radial ring count is `ceil(segments/2)` for such spherical joins and one otherwise. `patchRings` explicitly overrides it with an integer from 1 to 64.

If a projected junction has no valid centroid fan, it is triangulated with robust ear clipping and recorded in `triangulatedJoins`; rounded vertex bevels can need this path. No invalid fan is returned as a successful patch. `join="cutoff"` retains one boundary polygon per junction, whose piecewise-linear interpretation uses the mesh's usual triangulation. These are documented package patch/cutoff policies, not a claim of identical topology for every Blender miter/intersection option.

Exact coincident profile samples belonging to the same original vertex are welded, preserving separate face-corner data. Collinear samples are inserted into facing junction chords before filling, so even multi-segment linear profiles remain conforming. Open chains at original boundary vertices remain open and are recorded in `openJoins`. A closed source must remain closed or the operation fails. Branching junctions, crossed faces, degenerate faces and invalid fans reject.

Spherical patches are polygonal approximations at the selected resolution. Increasing segments also refines their default radial subdivision; no requested geometric error tolerance is implied. Local polygon and topology checks do not certify absence of intersections between separate surface regions. Global intersection diagnostics/repair remain part of the modeling completion tracker.

## Materials and attributes

Surviving face IDs retain their materials and face channels. Offset points in a source face use barycentric correspondence in its triangulation. Points on original edges interpolate the endpoints, including skin weights and groups. Profile samples interpolate their two rail correspondences by profile parameter; this is positive attribute interpolation and need not equal the curved sample's geometric coordinates. Junction centers/rings blend boundary correspondences. Exact coincident vertex samples blend their source references; side-specific corner data remains separate.

Intrinsic UV/color/custom corner fields and typed corner channels interpolate independently in source faces and across generated strips. Original UV seams therefore remain separate on their source rails. Generated bevel strips blend the two adjacent face channels; categorical channels follow their declared interpolation rule. Strip material follows the nearer adjacent face. Junction faces blend incident source face channels and use the first source face's material. `material` overrides the material of generated strips and junctions only.

Remaining source-edge segments and longitudinal strip rails inherit the source edge's channels. New profile/junction/radial edges use defaults. All sparse schemas survive. Normals are recalculated after geometry; apply `Normals.recalculate` or another custom-normal edit afterward when a particular shading policy is required. Copied sharp-edge attributes remain part of that policy. The operator does not infer a new UV unwrap or promise texture-density preservation.

## Modifier selection and reports

`Modifiers.bevel(mesh, width, options)` selects edges by default. Without an explicit `selection`, it chooses two-face edges whose normal angle exceeds `angle` (radians, default zero), with a `1e-8` cosine tolerance that excludes coplanar edges. `affect="vertices"` instead selects all vertices. An explicit `selection` overrides automatic selection. `weightAttribute` may name a numeric edge/vertex channel matching the affected domain; its values must lie in `[0,1]` and multiply selected weights. Other options pass through to the edit operation.

Reports include shared edit allocation/correspondence/validation fields plus `strips[edgeKey]`, `joins[vertexId]`, `joinLoops`, `cornerPaths`, `mergedVertices`, `sphericalJoins`, `triangulatedJoins`, `patchRings`, `openJoins`, `maximumMiter`, profile diagnostics, `mode` and geometric-search `work`. Allocation lists include temporarily created samples subsequently merged; use `mergedVertices` and final mesh membership when resolving those IDs.

Shared limits are `maxVertices=500000`, `maxFaces=500000`, `maxElements=2000000`, `maxFaceVertices=2000` and `maxFaceWork=5000000`. Bevel's `maxWork=5000000` bounds geometric searches, candidate comparisons and topology-building visits; allocation limits separately bound profile/patch creation. `checkpoint` can yield or throw. Failure leaves the source unchanged and creates no native instances. High segment/ring counts can exhaust the limits well before the nominal 64-segment maximum on a large mesh.

Verification covers analytic wedge/tetrahedron/truncated-cube volumes, polygonal circular profiles, convergence toward rounded-box volume, linear/custom profiles, partial and weighted selections, open surfaces, reentrant solids, reflex terminations, higher-valence junctions, all typed domains, UV seams, varying skin/groups, cancellation/budgets, width collapse, arbitrary rotations, scale/translation and native EditableMesh roundtrips. The `BeveledHousing` example combines a recessed region, angle-selected edge bevel and weighted normals.

Use `Intersections.mesh(result)` for a bounded exact-classification audit of the resulting triangulated geometry; see [INTERSECTIONS.md](INTERSECTIONS.md). Bevel construction does not run that potentially expensive scan automatically.
