# Mesh attributes and creased subdivision

These are authoring APIs. `Attributes` operators return independent mesh copies. Mesh instance methods, including normal recalculation and removal, mutate their receiver. No call here creates native objects, publishes assets, or changes the scene.

## Typed channels

`Attributes.create(mesh, name, domain, dataType, default, interpolation?)` adds a named sparse channel. Names are unique across domains. Supported domains and element keys:

| Domain | Key |
| --- | --- |
| `vertex` | Existing numeric vertex ID |
| `edge` | Existing undirected edge as `minVertexId .. ":" .. maxVertexId` |
| `face` | Existing numeric face ID |
| `corner` | Existing face ID and one-based corner index as `faceId .. ":" .. index` |

Types are `number`, `boolean`, `string`, `Vector2`, `Vector3`, and `Color3`. Numeric components must be finite. An omitted value resolves to the supplied, correctly typed default; `false` is a value, not an absent entry. Channels live in `mesh.attributes[name]` with fields `domain`, `dataType`, `default`, `interpolation`, and `values`.

- `Attributes.set(mesh, name, values)` overlays an element-key/value dictionary. Assign the default to reset a value. Invalid types or missing elements reject the complete operation.
- `Attributes.get(mesh, name, key)` reads a value or its default and rejects nonexistent elements. This convenience call constructs domain membership; inspect a channel's sparse values directly when processing large loops, resolving absent entries to its default.
- `Attributes.names(mesh, domain?)` returns sorted names.
- `Attributes.remove(mesh, name)` removes one channel from a copy.
- `Attributes.transfer(source, target, maps?)` replaces the target copy's channels with the source schemas and values transferred by explicit element correspondence. Existing target channels are not merged by this public operation.

Interpolation is `linear`, `nearest`, `max`, or `min`. Numeric/vector/color channels default to `linear`; booleans and strings default to `nearest`. Linear interpolation computes a normalized weighted blend; it does not normalize direction vectors. `nearest` chooses the largest positive weight, with the first supplied reference winning a tie. Min/max support numbers and booleans, where max is OR and min is AND. They consider references with positive weight. Negative, nonfinite, and all-zero weights reject.

```lua
local m = E.Attributes.create(mesh, "uv_seam", "edge", "boolean", false, "max")
m = E.Attributes.set(m, "uv_seam", {["1:2"] = true})
local split, newId = E.Topology.splitEdge(m, 1, 2, 0.25)
-- Both child edges retain the seam. The obsolete parent entry is removed.
```

A correspondence is `maps[domain][newKey] = {{oldKey, weight}, ...}`. Weight defaults to one. Unmapped surviving IDs use identity unless `maps.identity[domain] = false`. All other new elements use the channel default. Disable identity whenever IDs have been rebuilt and may accidentally overlap source IDs. References cannot cross domains. There is no implicit nearest-position projection.

## Editing contracts

| Operation | Attribute behavior |
| --- | --- |
| Clone and position-only edits | Own and preserve channel data |
| Triangulate | Child faces inherit the source face; corners retain their original correspondence; existing perimeter edges retain values and new diagonals use defaults |
| Join | Remaps all four domains; unions channel names; same-name domain/type/default/interpolation conflicts reject |
| Extract, removeFace, removeUnused | Prunes missing domain elements; isolated vertices survive removeFace until removeUnused is called |
| Reverse | Reorders corner channels; also reverses built-in normal and tangent handedness |
| Split edge | Blends endpoint vertex values and each incident face's own corner values; copies the edge value to both child edges; interpolates skin weights and groups |
| Weld | Equal-weight blends collapsed vertex/edge values under each channel's rule; retains surviving face-corner provenance; legacy skin weights use the representative vertex and groups use maximum |
| Region extrude | Copies duplicated vertex data, cap edge values, source face material/channel values and side-corner correspondence; new connecting edges default |
| Individual face inset | Blends inner vertex/corner data with the face average by the inset fraction; preserves perimeter values; inner perimeter edges inherit their source edges and radial edges default |
| Dissolve coplanar edge | Blends the two face channel values; takes each surviving corner from its contributing boundary face |
| Fill and bridge | Existing data survives; new face/corner/edge values use defaults |
| Catmull-Clark and multires | Child edges inherit parent data, radial edges default, child faces inherit their source face; corner data defaults to face-local transfer, with six optional per-channel face-varying modes and persistent data identities |
| Boolean BSP and arrangement | Both operands contribute all four domains through explicit correspondence; missing schemas use defaults and conflicting schemas reject; see [BOOLEANS.md](BOOLEANS.md) |
| Adaptive split/collapse/flip and Simplify | Local correspondence preserves all four domains, groups and skin weights; conservative seam protection and chart-local corner interpolation are described below |
| Solidify | Duplicates vertex and source-edge data on both skins; inner faces reverse corner order and tangent handedness; rims inherit their boundary face/corners and connecting edges default |
| Plane clip and convex bevel | Retained source polygons interpolate vertex and face-local corner values; surviving edge pieces inherit their source edge; generated cap face/corner values and cut edges default |
| UV splitTiles | Interpolates vertex and face-local corner data and groups/skin, retains source-face channels and perimeter edge pieces, defaults generated cut edges; intrinsic UVs and material slots become tile-local |
| Roblox partition | Each chunk mesh retains all four domains, groups, weights and intrinsic corners; triangulation diagonals default and sourceVertices maps each chunk vertex back to its source |
| Attributes.project and voxel Remesh | Bounded nearest-surface, connected-chart corner and nearest-edge projection across different topology; retains schemas, groups, normalized skin and intrinsic data with domain masks and explicit unmatched reports |

Subdivision's generic vertex data uses varying interpolation: old vertex children retain values, edge points blend endpoints, and face points average face vertices. This is separate from the positional subdivision mask. Corner data defaults to face-local interpolation. `faceVarying` enables smooth per-channel charts with corner/junction/concave/boundary constraints and explicit seams; [SUBDIVISION.md](SUBDIVISION.md) documents the rules, persistent identity attributes, limits and multires behavior. Domain conversion is documented below.

Custom channel preservation is integrated into the operations listed above and the polygon edits described below. [DATA_TRANSFER.md](DATA_TRANSFER.md) documents `Attributes.project` and voxel source projection, including chart restrictions, masks and unmatched results. Native EditableMesh and OBJ/glTF interchange do not represent these arbitrary channels; authoring chunks and typed JSON snapshots do. Retain the JSON when exporting native geometry.

`IO.toTable` writes mesh schema version 2 when custom channels exist, using typed defaults and key/value lists. `IO.fromTable` reads versions 1 and 2, rejecting malformed channels. Attribute-free meshes retain version 1 output. `IO.encode/decode` preserve all supported native value types. Keep this JSON if further authoring or crease edits must remain possible after publishing native geometry.

## Creases

`Subdivision.crease(mesh, edgeSharpness?, vertexSharpness?)` overlays sparse sharpness dictionaries. Values range from 0 to 10: zero is smooth, values below 10 are finite sharpness, and 10 remains sharp indefinitely. This is an explicit subdivision sharpness scale, **not a claim that Blender's normalized crease slider has the same numeric mapping**.

The channels are `subdivision_edge_sharpness` and `subdivision_vertex_sharpness`, with their corresponding domains, numeric type, zero default, and max interpolation. Conflicting schemas reject. A zero assignment clears a crease's effect.

```lua
local m = E.Subdivision.crease(mesh, {["1:2"] = 2.5}, {[1] = 0.4})
local refined = E.Subdivision.catmullClark(m, 3, {
    creasing = "uniform",       -- or "chaikin"
    boundary = "edge",          -- or "edgeAndCorner", "fixed"
    maxVertices = 250000,
    maxFaces = 250000,
})
local levels = E.Subdivision.multires(m, 3, {creasing = "chaikin"})
```

The implementation uses Catmull-Clark smooth masks, midpoint sharp-edge masks, a 3/4 center plus 1/8 of each crease neighbour vertex mask, and fixed corner masks. A dart with only one sharp edge retains the smooth vertex mask. Fractional transitions blend the parent and child masks using the average of the sharpness values that become smooth at that refinement step. This matters at intersections of unequal creases.

Uniform sharpness decreases by one per level until zero; ten remains ten. Chaikin propagation uses 3/4 of the edge's sharpness plus 1/4 of the average of the other finite sharp edges at that endpoint, followed by the decrement. Thus the two children of an edge may have different sharpness. Infinite edges are excluded from that finite average. Geometry uses effective boundary creases, but implicit boundary constraints are not baked into the authored channels.

These rules follow the published [OpenSubdiv subdivision model](https://opensubdiv.org/docs/subdivision_surfaces.html) and its [crease algorithm reference](https://opensubdiv.org/docs/doxy_html/a00860_source.html). This package contains an independent Luau implementation. It returns refined polygon cages; it does not yet evaluate subdivision limit patches or guarantee bit-for-bit OpenSubdiv results.

Boundary `edge` uses a cubic boundary crease; `edgeAndCorner` additionally fixes boundary vertices incident to one face; `fixed` fixes all boundary vertices. There is no boundary-hole mode. Inputs must have consistently wound manifold edges and connected vertex fans; invalid fans reject. These checks do not detect arbitrary geometric self-intersections. Levels are integers from 0 through 16, with per-level allocation limits enforced before output construction. Optional `checkpoint(progress)` runs before each level and may throw to cancel. Multires forwards these rules to its refinement and coarse-commit operations; it still requires unchanged topology when committing edits.

## Sharp normals

`mesh:recalculateNormals(angle?, sharpEdges?)` accepts an explicit boolean edge selection. If omitted, a boolean edge channel named `sharp_edge` is used when present. Face-corner averages stay within the connected fan reachable across unmarked edges, with the existing face-angle eligibility filter. An explicit empty selection overrides the named channel. The angle is in radians from zero through pi.

Permanently sharp subdivision edges also split the output's corner normals. Finite creases retain smooth normals on the refined cage. This is a polygon normal approximation, not a subdivision limit normal evaluation. A `sharp_edge` channel controls shading without changing geometry; subdivision sharpness controls geometry.

## Domain conversion

`Attributes.convertDomain` and `Selection.convertDomain` convert vertex, edge, face and corner data through explicit mesh incidences. They support typed reductions, sparse defaults, weights, budgets and cancellation. See [CONNECTIVITY.md](CONNECTIVITY.md) for the complete incidence table and mask contracts.

## Polygon edit transfer

`MeshEdit` preserves typed channels through explicit vertex/edge/face/corner correspondence for region inset, individual extrusion, loop cuts, poke and triangle pairing. Slides retain attached data. `MeshRepair` prunes deleted elements and remaps flipped corners. See [MESH_EDITING.md](MESH_EDITING.md) for seam, interpolation and new-edge defaults. Other builder integration gaps remain as stated above.

## Local remesh and simplification data

`Adaptive.refine` copies each replaced triangle's face data, interpolates midpoint vertex/corner channels and skin/groups, and inherits both child edges from the split edge. New interior edges use defaults. Repeated edits remove obsolete face, corner and edge entries.

`Adaptive.remesh` and `Simplify.decimate` protect vertices at material, intrinsic corner, typed corner and typed face discontinuities by default. Normal and tangent vectors are excluded from this data comparison because these operators recalculate shading. UV matching uses `uvTolerance` (default `1e-6`); other numeric/vector/color data uses `attributeTolerance` (default zero). Boolean/string data compares exactly. Positive numeric or true boolean edge channels `sharp_edge`, `uv_seam`, `subdivision_edge_sharpness`, and names supplied in `seamAttributes` lock both edge endpoints. `preserveSeams=false` explicitly disables this protection. Boundary, sharp-angle and region constraints still follow their own options.

Collapse vertex channels, skin weights and groups interpolate at the selected endpoint/midpoint parameter. Surviving face values remain attached. Each surviving corner interpolates only through an adjacent removed triangle whose corner agrees with its own chart at that endpoint; if no chart matches, its own value remains. This avoids averaging unrelated UV or categorical charts. Duplicate remapped edges blend endpoint contributions with the same parameter; an edge with one source inherits that source. Collapsed faces/corners/edges are pruned. Adaptive edge flips blend the two face values equally, retain the contributing outer corners and use defaults on the new diagonal. Channel interpolation policies apply throughout.

Relaxation and reference projection change positions while keeping attached fields. They do not reevaluate a scalar field at the new spatial location. Use `Attributes.project` for explicit source-surface resampling. These local operations protect topology and orientation but do not certify freedom from global intersections; simplification can stop short of its requested face count.

## Shells, clipping and export preparation

`Modifiers.solidify(mesh, thickness, options?)` defaults to area-weighted averaged vertex normals. Positive finite `thickness` and `offset` in `[-1,1]` place the two skins at `thickness*(offset+1)/2` and `thickness*(offset-1)/2`; default zero centers the shell. Offsets `-1` and `1` place the thickness on one side. Boundary rims close open sheets. The result remains a single mesh with recalculated normals. The default normal-offset mode has no uniform face-distance or global intersection guarantee. `join="miter"` adds measured corner-plane joins. The new `Modifiers.shell` API returns a diagnostic report and defaults to miter joins plus intersection audits; see [SHELLS.md](SHELLS.md). Defaults: `maxVertices=500000`, `maxFaces=500000`, `maxWork=2000000`; `checkpoint(progress)` and `cancelled()` may abort without changing the source.

`Modifiers.clipPlane(mesh, point, normal, cap?, options?)` retains the negative plane half-space and returns one mesh. Capping defaults to true and requires valid closed source topology; concave, disconnected and holed cross sections use `MeshEdit.bisect`. Uncapped clipping supports open sheets. Options follow bisect except that `keep` and `cap` are set by this convenience function. Default tolerance is `max(largestBoundsExtent*1e-6, 1e-7)`; supply an explicit tolerance when that displacement is unsuitable. Use `MeshEdit.bisect` directly for its provenance, diagnostics or both halves. `bevelConvex` continues to require a closed convex source and keeps intermediate caps polygonal so repeated chamfer cuts do not accumulate triangulation slivers. Generated caps use default channel values.

`UV.splitTiles(mesh, columns, rows, options?)` requires intrinsic UVs within `[0,1]`. Each tile interpolates all authoring channels, but only built-in `corner.uv` is rescaled into the tile; a separately named UV channel retains its authored interpolated values. Face materials become one-based tile indices; save original material labels in a face channel when needed. Clip decisions retain double-precision UV parameters until native vectors are constructed. Invalid resulting topology rejects rather than returning collapsed edges. Defaults: `maxTiles=4096`, `maxVertices=500000`, `maxFaces=500000`, `maxWork=2000000`, counted across the complete call; `checkpoint` and `cancelled` are transactional. Empty tiles are omitted.

`Roblox.partition(mesh, maxTriangles?)` returns independent authoring chunks grouped by material, with a default 18000 and maximum 20000 triangles per chunk. Each chunk's `mesh` remains channel-complete; exporting that chunk to native EditableMesh retains supported UVs, normals, colors and skin data only. Neither tiling nor partitioning modifies the source. `Examples.AttributedPanel` demonstrates refinement, an offset shell, a capped cut, retained scalar groups and partitioned output.
