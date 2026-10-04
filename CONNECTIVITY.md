# Mesh connectivity, paths and domains

`E.Connectivity` builds a detached directed-corner index. `index(mesh, options)` returns `vertices`, `edges`, `faces`, `corners`, `boundary`, `duplicateFaces` and `elements`. Vertex/face keys retain source IDs. Edge keys are `"minVertex:maxVertex"`; corner keys are `"faceId:cornerIndex"`. Each corner records `vertex`, `to`, `face`, `index`, `edge`, `next` and `previous`. `twin` exists only for a consistently opposed two-face edge. Vertex entries include sorted incident edges, incident corners and connected face fans. Returned tables do not alias mesh tables.

`analyze(mesh, options)` reports counts, Euler characteristic, connected surface components, boundary loops, vertex/edge nonmanifoldness, inconsistent winding, duplicate faces, loose vertices and coincident edge endpoints. Component genus is supplied only when manifoldness, winding and boundary checks make the usual orientable-surface formula applicable. Surface components connect through edges; two sheets touching at one vertex remain distinct components and produce a nonmanifold vertex. Loose vertices count toward the global Euler characteristic but are not surface components. `valid` is a connectivity diagnosis: it does not test face area or geometric self-intersection. `Mesh:validate()` combines these checks with its geometry and attribute checks.

`boundaries(mesh, options)` returns `(loops, report)`. Each closed loop contains ordered `vertices`, `edges` and `corners`, preserving the incident face winding. Multiple incoming or outgoing boundary edges at a vertex make the boundary ambiguous; the call returns no loops and `report.complete=false`, with `ambiguousVertices`. Malformed face indices, repeated face vertices and nonfinite positions throw. `maxElements` defaults to 2,000,000 vertices + faces + corners and is checked before building the index. `checkpoint(progress)` supports cancellation by throwing.

## Selection graph queries

```lua
local path = E.Selection.shortestPath(mesh, startVertex, endVertex)
assert(path.complete and path.found)
local faces, linked = E.Selection.linked(mesh, {[startFace]=true}, {
    domain = "face", blockedEdges = seamEdges,
})
local ring = E.Selection.edgeRing(mesh, "1:2")
local loop = E.Selection.edgeLoop(mesh, "1:2")
local boundaryEdges, loops, boundaryReport = E.Selection.regionBoundary(mesh, selectedFaces)
```

`shortestPath` and `linked` use a bounded Dijkstra heap. `domain` is `vertex` (default), `edge` or `face`. Vertex adjacency follows mesh edges; edge adjacency shares endpoints; face adjacency shares edges. With `faceStepping=true`, vertices may step across a face, edges cross opposite sides of quads, and faces may move within a connected vertex fan. Face fan traversal respects `blockedEdges`; a vertex diagonal is not blocked merely because an unrelated edge of its face is blocked. `blocked` excludes domain elements; `blockedEdges` excludes edge-domain nodes, direct vertex transitions, and face transitions across the named edges. Selection/seed values are booleans or positive numbers.

The default metric measures Euclidean distances between vertex positions, edge midpoints or polygon vertex-mean centers. `metric="hops"` uses unit costs. `cost(fromKey, toKey, defaultCost)` may return a finite nonnegative directed cost. Equal tentative distances retain the first predecessor in deterministic key order. `radius` restricts accumulated path cost. `maxVisited` defaults to 250,000 settled nodes; `maxWork` defaults to 5,000,000 traversal steps, in addition to the connectivity allocation budget.

The report includes `complete`, `found`, `visited`, `work`, finalized `distances`, `predecessors`, ordered `path` and `selection`. A path result selects only its path; an unreachable or budget-exhausted target selects nothing. Unreachable targets return `complete=true, found=false, reason="unreachable"`; exhausted work returns `complete=false` and a budget reason. A linked query returns the reached selection and report. Its selection may be partial when incomplete. Unknown IDs, invalid costs and cancellation throw. Callbacks are never swallowed as budget failures.

`geodesic(mesh, seeds, radius, options)` returns a smooth vertex mask, finalized edge-path distances and report. Radius must be positive and finite. The mask is `smoothstep(1-distance/radius)`. A budget failure throws so callers cannot unknowingly use an incomplete brush mask.

`edgeLoop` follows the opposite edge at regular four-valence quad vertices; boundary seeds follow the boundary. `edgeRing` traverses opposite quad edges and returns its ordered face strip. `faceLoop` uses the ring but selects faces. Results include `edges`, `vertices`, `faces`, `selection`, `edgeSelection`, `vertexSelection`, `faceSelection`, `closed`, `complete`, `ends` and `simple`. Boundary ends, regular poles and non-quad endpoints are valid stopping points. Nonmanifold/winding issues, revisits and exhausted `maxSteps` return `complete=false` with their stopping reasons. `maxSteps` defaults to 250,000. A closed ring has one face per edge; an open ring has one fewer face than edges. `regionBoundary` removes internal selected edges and preserves holes and source corner IDs.

## Attribute and mask domain conversion

`Attributes.convertDomain(mesh, name, targetDomain, options)` returns `(newMesh, report)`. It replaces the named channel or writes a distinct unused `options.name`. Type, default and interpolation mode are preserved unless `options.interpolation` overrides the mode. Linear/min/max/nearest reduction follows ATTRIBUTES.md. Nearest ties use sorted source keys. The input remains unchanged.

| Source → target | Contributions to each target |
| --- | --- |
| Vertex → edge / face / corner | Endpoints / polygon vertices / corner vertex |
| Edge → vertex / face / corner | Incident edges / polygon edges / the two edges touching that face corner |
| Face → vertex / edge / corner | Distinct incident faces / incident faces / owning face |
| Corner → vertex / edge / face | Corners at that vertex / both endpoint corners from every incident face / owning face corners |

The same-domain conversion copies each value. Every distinct incidence receives equal weight by default; no implicit area or angle weighting occurs. `weight(sourceKey, targetKey)` can return a finite nonnegative weight. Zero-weight contributions are ignored. Targets with no positive contribution, such as loose vertices, receive the channel default. Corner-to-vertex/edge conversion intentionally reduces seam values; retain the original channel under a separate name when discontinuities matter. `maxReferences` defaults to 2,000,000 contributions and `maxElements` bounds the connectivity index. `checkpoint` can cancel atomically. Reports count `elements`, `references` and `defaulted` targets.

`Selection.convertDomain(mesh, mask, sourceDomain, targetDomain, options)` uses the same incidence rules. It accepts booleans or finite weights in `[0,1]`, with omitted elements equal to zero. `mode="all"` (default) takes the minimum, `"any"` takes the maximum and `"mean"` averages. The returned sparse numeric mask omits zeros; the second result is the conversion report. It supports the same weights and budgets.

Verification includes disk/annulus/torus Euler characteristics, directed-corner invariants, sparse IDs, touching fans, reversed duplicate faces, path barriers and zero costs, quad loops/rings, all twelve cross-domain conversions, seam reductions, native typed values, persistence, immutability, cancellation and explicit budget failure. These tests do not certify arbitrary-input geometry.
