# Editable3D changes

## 0.88.0 — unreleased

- **`Deform.envelope(mesh, view, step, fill)`:** an optional `fill` count of hole-filling passes. Empty cells with filled neighbours on both sides along a row or column get their average, so interior gaps close without growing the silhouette. `Deform.relief` now builds its own envelope with 3 passes. A step finer than the mesh's spacing had left gaps, and vertices over a gap were skipped while their neighbours moved, which crinkled the surface.

## 0.87.0 — 2026-10-04

- **`MeshRepair.audit(mesh, {weld, crack, fold, overlap, stride, limit})`:** a one-call health check that works on soups (corners are welded by position first). It reports:
  - boundary and non-manifold edges;
  - crack edges (boundary edges with a near-coincident partner, i.e. hairline cracks);
  - degenerate and duplicate faces;
  - folded edges (crumpled or flipped triangles);
  - isolated faces (no shared edge: interleaved chunks or an unwelded soup);
  - co-facing self-overlap (sampled);
  - signed volume, with `insideOut` for closed meshes.

  `samples` lists face ids for each problem.
- **`MeshRepair.unfold(mesh, {fold, iterations, rings, step})`:** untangles crumpled triangles by relaxing the vertices around folded edges until no fold remains, keeping boundaries fixed. Returns the welded mesh and before/after fold counts.

Tests: a box and its reverse (inside-out), a cracked soup, a folded quad, a duplicate face, and a grid with one vertex dragged across its neighbours (unfolded to zero folds).

## 0.86.0 — 2026-10-04

Helpers promoted from scene work:

- **`Registration.translation(source, target, {quantum, limit})`:** finds the exact offset between two copies of the same geometry (for example, a mesh rebuilt from its published asset against a trimmed or moved copy). Matching triangle edge vectors vote, so it works on soups.
- **`Registration.icp(source, target, {initial, iterations, maxDistance, rigid, sample})`:** iterative closest point onto a Mesh or a Spatial index. Translation only by default; `rigid = true` also solves the rotation.
- **`Geometry.principalAxes(mesh)`:** area-weighted principal axes (exact triangle second moments, Jacobi). Returns the centre, sorted axes, variances and a frame whose Z is a flat object's normal.
- **`Planar.outlineContains`, `outlineDistance`, `offsetOutline`:** helpers for simple Vector2 outlines in either winding. `offsetOutline` grows the outline for positive distances and limits the miter.
- **`Roblox.rebake(parts, shader, {size, padding, srgb})`:** re-textures existing parts from a world-space shader as a preview, keeping their meshes and other maps. Call `:publish(metadata, options)` to upload only the colour maps, or `:revert()` to undo.
- **`Roblox.fillTerrain(terrain, outline, options)`:** fills terrain to a polygon outline: land up to `ground`, an `edge` band, an `inset` for a wall mesh, and water to `seaLevel` around it, written in strips.

Tests: the translation vote is exact on a trimmed, shifted copy; ICP recovers translation and a small rotation; principal axes of a box; outline helpers in both windings. Native tests: rebake preview and revert, and the terrain fill (run in a remote region and restored).

## 0.85.0 — 2026-10-04

- **`Primitives.prism(polygon, y0, y1, {bottomScale})`:** an outward-facing prism over any simple polygon in the XZ plane, convex or concave, in either winding. Side faces are flat-shaded and caps are single polygons (concave caps triangulate by ear clipping). `bottomScale` widens the base for battered walls. A loft of two rings is inside-out or right depending on winding, which isn't obvious until it renders inside-out.
- **`Primitives.stairs(width, depth, height, steps)`:** a solid flight of stacked step blocks climbing toward +Z.
- **`Primitives.tree({height, trunkRadius, crownRadius, lobes, branches, seed, detail})`:** a broadleaf tree standing on y = 0. The tapered trunk and branches are material 1, and the crown of noise-displaced lobes is material 2, so `toModel` gives bark and foliage separate parts and textures. It is deterministic per seed.

Tests: an L-shaped prism in both windings has positive volume and outward side faces; a battered frustum and a stair flight have the expected volumes; trees are deterministic, stand on the ground and split into two material chunks.

## 0.84.0 — 2026-10-04

- **`Topology.snap(meshes, tolerance)`:** closes hairline cracks across a set of meshes. Vertices join the nearest cluster seed within `tolerance`, so no vertex moves further than that (chained clustering had dragged some corners 0.47 studs at a 0.045 tolerance). Each vertex then moves to its cluster's average. Corners and UVs are kept, so baked textures still fit, and faces that collapse are removed. Returns `(meshes, moved, removed)`. On a six-chunk sculpt whose shared corners had drifted 0.04 apart, a tolerance of 0.05 cut open edges from 221k to 8.7k.
- **`Deform.relief` no longer cracks soups.** The facing weight was gathered per vertex id. In a triangle soup (meshes read back from Roblox), coincident corners have their own ids and normals, so they moved by different amounts and the surface cracked open. Facing is now gathered per position.

Tests: snap closes a drifted edge, removes a collapsed sliver and bounds each move; relief moves coincident soup corners together (this failed before).

## 0.83.1 — 2026-10-04

- **`Roblox.partition` (and `toModel`) makes spatially compact chunks.** Triangles were cut into chunks in face order. After triangulation, every quad's second triangle has a later face id, so a large quad mesh split into a chunk of all first halves and a chunk of all second halves. These checkerboards interleave across the whole surface, and with one texture bake per chunk they render as a fine speckle of two textures. Chunks now come from recursive splits along the longest axis of the triangle centroids. Every chunk except the last is full, and triangle order within a chunk is preserved.
- **Coincidence tests need interior projection.** `Spatial.coincident`, `coincidentPairs` and `trimCoincident` count a point only when it projects inside a triangle of the other surface. Before, being within `tolerance` of a triangle edge was enough, so a fine tessellation's gaps (for example, the missing halves of a checkerboard chunk) counted as covered, and `trimCoincident` removed the faces filling them.

Tests: interleaved face order gives compact chunks (it failed before), and complementary checkerboard halves are not coincident.

## 0.83.0 — 2026-10-04

Coincident-surface tools, from tracking down speckled, flickering patches on a multi-part sculpt. Two chunk sets were near-duplicates, a cloth layer lay exactly on the layer beneath it, and plates of a held slab overlapped.

- **`Spatial.coincident(a, b, {tolerance, angle, stride})`:** how much of mesh `a`'s area lies on `b` (a Mesh or an Index), split into co-facing area (`same`, which z-fights) and back-to-back area (`opposite`).
- **`Spatial.coincidentPairs(meshes, options)`:** audits a set of meshes. It returns every ordered pair whose co-facing overlap is at least `minFraction` of the first mesh, largest first. Bounding boxes are prefiltered.
- **`Spatial.trimCoincident(mesh, keepers, options)`:** removes the faces of `mesh` that lie on any keeper and face the same way, so the keepers alone render there. Returns the trimmed mesh and the removed face count.

Tests: offset, flipped, distant and half-overlapping sheets.

## 0.82.0 — 2026-10-04

- **`Texture:guided(guide, radius, eps)`:** guided filter (He, Sun and Tang 2013). It is edge-preserving smoothing of a texture's RGB, steered by another image's luminance: edges in the guide stay sharp and flat guide areas are smoothed. Use it to snap soft depth or height fields to the crisp edges of a photograph, or to clean baked maps. Summed-area tables keep the cost independent of the radius.

- **Published bundles are protected.** A committed `Roblox.publish` sets `bundle.published`, and `Roblox.destroy` then refuses that bundle unless passed `{ force = true }`, because its model is live scene content. A stale reference to a published bundle had silently deleted a published model.
- **`Roblox.release(bundle)`** frees only the editables and images, which is what to call after publishing. `destroy` also tolerates handles whose editable was already freed.

Tests: a step edge is sharpened and noise removed, the guide size is checked, and destroy/release behave correctly on published bundles.

## 0.81.0 — 2026-10-04

- **`Roblox.publishImages(images, metadata, options)`** publishes standalone EditableImages (skyboxes, decals) with readback verification and the resume ledger, and returns `report.imageIds`. Publish bundles accept an optional `images` list.
- **`UV.box(mesh, frame, {tile = studs})`** produces world-aligned, unpacked UVs (projected studs ÷ tile) for shared tileable materials on large architectural meshes.

Tests: standalone image publishing (IDs, resume, mismatch) and tiled box UVs.

## 0.80.0 — 2026-10-04

- **`Deform.envelope(mesh, view, step)`:** rasterized front-depth grid of a mesh seen along a view, with `sample` and `blurred(radius)`.
- **`Deform.relief(mesh, view, target, options)`:** moves the visible front layer onto a target depth function, compressing existing relief below the envelope by `alpha`. The back, sides and deep geometry are left alone. This came from replacing a sculpt's drapery folds with relief measured from a photograph's depth map.

Three new tests in `AuthoringTests`.

## 0.79.0 — 2026-10-04

Authoring helpers for complex objects, from re-posing and re-texturing a held object with its arm and sleeve:

- **`Curves.sweep` profile functions:** `profile(fraction, frame)` returns each ring in a transported frame, for variable cross-sections (tapering, sagging cloth).
- **Sweep and loft options:** both take `closed` and `triangles`. Open lofts produce sheets; triangle lofts drop zero-area triangles from pinched rings.
- **`UV.box(mesh, frame?, {margin})`:** box projection into up to six rectangular charts at one shared scale, shelf-packed. It needs no welding or manifold geometry, so it works on meshes read back from Roblox, where island packing (`UV.packIslands`) refuses the input.
- **`Bake.rasterize`** skips faces that cannot be triangulated (zero area, degenerate polygons) instead of aborting, and reports them as `skippedFaces`. Before, one collapsed triangle from welding a read-back mesh stopped the whole bake.

New `AuthoringTests` suite (7 tests).

## 0.78.1 — 2026-10-04

- **`Pattern.streaks` redesign.** In 0.78.0, streaks were contour lines of 3D noise. They meandered like wood grain instead of running straight. Each run now comes from a source with a random top, length and strength, and fades downward. `width` is now a half-width in studs (default 0.05), not a fraction. New `projection` option:
  - `"world"` (default): vertical curtains from a horizontal source grid.
  - `"cylindrical"` (`frame`, `radius`) and `"planar"`: ignore depth, so runs follow flaring and folded surfaces instead of breaking into dashes.
- **`Normals.unify(meshes, {tolerance, angle})`** recalculates normals over several meshes as one welded surface. Each mesh keeps its own faces, UVs and materials. This fixes shading breaks between the parts of a split surface, and the faceting of meshes read back from Roblox (one vertex per triangle corner).
- **`Roblox.fromPart`** now reads parts whose mesh content is an EditableMesh (unpublished) in place. 0.78.0 failed on those with "Invalid id".

Tests: streak shape, continuation on a flaring cone, the planar depth invariance, and `Normals.unify` against a whole-surface reference.

## 0.78.0 — 2026-10-04

Adds tools for re-texturing complex published models.

- **`Pattern`** (new strict namespace): deterministic procedural building blocks for bake shaders, all in world space and studs. `hash` gives uniform per-cell values. `smoothstep` and `fbm` cover thresholds and fractal noise. `panels` is a cylindrical or planar sheet-panel grid with a whole number of columns per ring, per-row jitter, per-panel ids and the physical distance to the nearest seam. `streaks` makes rain or drip runs elongated along `up`, strongest on vertical surfaces and absent on up- and down-facing ones. Guide: PATTERNS.md.
- **`Roblox.fromPart(part, {space})`** reads a MeshPart back as an authoring mesh in world space.
- **`Deform.transform(mesh, frame, scale, {normals = "transform"})`** keeps authored corner normals and tangents and maps them by the inverse transpose, including under mirroring. The default still recalculates normals; that path made published meshes (one vertex per triangle corner) flat-shaded.
- **`UV.cylindrical(mesh, center, height, options)`** takes `axis`, `seamAngle` and `normalize`/`margin`. Without options the behavior is unchanged.
- **`Roblox.publishMaterials(parts, metadata, options)`** publishes only the editable texture maps of parts whose meshes are already published. The publishing pipeline accepts `materialsOnly` handles. Previously, re-texturing a published part meant re-uploading its mesh.

New `PatternTests` suite (10 tests) and three materials-only publish tests.

## 0.77.2 — 2026-10-04

Completes the real-upload fix. With per-corner comparison in place, the second real publish still failed: Roblox also quantizes uploaded normals (maximum observed error 8.4e-4 on an 18,000-triangle mesh) while positions, UVs, colors and alpha return bit-exact. Mesh snapshots are now an exact canonical part plus normals in canonical order, and `NativeContent.equivalent` accepts normals within `NORMAL_TOLERANCE` (2e-3). The publishing pipeline takes an optional backend `equivalent(kind, a, b)` for readback, resume and final source checks, and keeps `==` otherwise. Ledger fingerprints from 0.77.0 are not comparable with this format, so resume refuses them ("Resume source changed") rather than trusting them.

## 0.77.1 — 2026-10-04

Fixes `Roblox.publish` verification against real Roblox uploads. The first real publish (a statue mesh) failed readback with "Published Mesh content mismatch" even though every position, UV and normal was unchanged: Roblox's asset pipeline stores one vertex per triangle corner (an 18,000-triangle mesh returns 54,000 vertices), and the verifier compared vertex welding. Native verification now compares each triangle corner's exact position, skin weights, UV, normal, color and alpha in winding order, plus bones, and ignores vertex sharing and unreferenced vertices. New tests cover welded vs split vs orphan-carrying meshes and still detect changed corners, missing and duplicated triangles. Earlier automated tests could not catch this because they used in-memory content that is never re-welded.

## 0.77.0 — 2026-10-04

Every public namespace is now strict: 76 strict modules, up from 5 in 0.76.0 (55 namespaces were promoted after the first 21). Callers get typed signatures and exported types across the API, including GLTF scenes and nodes, NURBS/Cyclic/Bezier descriptors, Convex/Dynamics/RigidBody/Simulation/Fluid/Particles bodies, Rig/Timeline/Animation/Morph/Constraints, BSDF/Lighting/Integrator/PathTrace/Camera/Render, Boolean/Topology/MeshRepair/Remesh, SplineQuery/Surfaces/SurfaceTrim/SurfaceAdaptive/ArcLength, and Spatial/Connectivity/Planar/Predicates/Deform/ARAP/Laplacian/Registration/SurfaceDeform/Conformal/Fields/Geometry/Modifiers. Values that pass through to internal modules that are not strict yet remain open tables or `any`. `tools/type_erased_diff.py` lists the functions a typing change actually altered after erasing types.

Runs the full regression suite in CI. `tools/headless.luau` mirrors the package tree under Lune with deterministic stand-ins for HttpService JSON, Random and the look-at CFrame constructors; `tools/run_headless.py` runs all 104 suites in parallel and enforces `tests/headless-baseline.json`. Every push now runs 88 suites (about 1,470 tests; previously 78 tests), and a sharded full-suite workflow runs all 1,784 weekly, on version tags and on demand; 68 tests that need native editable or asset APIs and one that relies on engine Vector3 key semantics are tracked explicitly and still run in the Studio release gate.

Type checking now uses luau-lsp with pinned Roblox API definitions and a Rojo sourcemap across all sources, tests, examples and Studio scripts, with zero errors required. Twenty-one modules are strict, up from five, including the core authoring API (Mesh, Primitives, Selection, Normals, Sculpt, IO, Simplify, Unwrap, MeshEdit, UV, Subdivision, Texture, Bake, Roblox). The root lists namespaces explicitly so callers receive their types; `Types.API` with its `any` fallback is removed and the root exports `API`. Contract fixtures reject 18 invalid usages. `.luaurc` no longer declares engine globals as untyped, which had made `Vector3`-typed contracts accept any value. API.md now shows typed signatures where available.

Behavior is unchanged: the edits are annotations, casts and equivalent local rewrites, verified by the full headless suite and a type-erased syntax comparison of every changed function.

## 0.76.0 — 2026-10-03

Adds shared texture/bake work, allocation and time budgets with cooperative cancellation; strict public boundary types and a service-independent publishing pipeline with full-content readback, bounded read retries, caller-owned resume ledgers, scene guards, reverse rollback and cleanup reports. Native engine adapters are separated from transaction logic and covered by local-content integration tests.

Adds pinned/checksummed tool installation, a reproducible local/GitHub Actions validation command, strict positive/negative type fixtures, real Luau VM coverage gates for the four pure core modules, resource/timing benchmarks, and development/runtime-only portable profiles. Production and maintenance guides document architecture, ownership, recovery, release procedure and remaining limitations. Runtime artifacts omit tests and examples; generated artifacts/tools are excluded from version control.

Final verification: 1,864 tests across 104 suites and 80 examples pass (63 new tests).

## 0.75.1 — 2026-10-03

Corrects repeated bilinear sampling, texel-center resampling and straight-alpha painting. Same-size resizing returns an independent byte-exact copy. Shared source-over compositing preserves zero-contribution destination data and small nonzero alpha. Sampling rejects nonfinite UVs and accepts an optional independent vertical wrap flag; environment lighting now repeats longitude while clamping latitude. The coordinate convention and filtering limits are documented.

All 1,801 Studio tests and 80 examples pass, including 21 new texture regressions that fail 19 cases on 0.75.0. All three correctness defects found in review are closed. Static analysis covers all 538 Luau files, changed-file formatting is AST-verified, and both portable builds decode with matching sources. Full Blender feature parity remains incomplete.

## 0.75.0 — 2026-10-03

Adds complete bounded limiting-normal decisions over exact positive-spectrum germs when sufficient annular Bernstein certificates cannot decide. Common algebraic spectra, full Jordan expansions and Thom sign cells cover shrinking parameter regions. Adds `exactPolynomialNormals` for singular analytic patches, with original-control replay and explicit one-sided quadrant coverage. Exact existence remains separate from native unit-vector accuracy. SingularPatchNormal demonstrates a corner with a vanishing partial and a uniform normal. All 1,780 Studio tests and 80 examples pass, including 21 new normal-germ cases. The 20 new nonnative cases, 30 annular/history regressions, and a focused 21-case Studio pass also succeed. Exact root and sparse-polynomial sorting now permit yielding work callbacks; the regression suite checks that contract. Static analysis and formatting of 21 changed files pass. Both portable builds decode with 537 matching modules and 536 public functions in 68 namespaces. The documented modeling and surface requirements are complete through item 68; explicit resource, native precision, quality and out-of-scope limitations still apply. A development full-spectrum four-sector stress run reached its billion-work cap; the production query for that source continues to pass through its verified faster cone proof.

## 0.74.0 — 2026-10-03

Extends exact constrained-normal proofs through locally refined histories. Original controls and finite sharpness are replayed with rational arithmetic across polygon conversion, explicit corner patches and cropped refinement paths. Exact mask classification and deterministic incidence checks guard the proof. Adds independent Fraction references and RefinedConstrainedNormals.

All 1,759 Studio tests and 79 examples pass, including 11 new history cases. All 10 new nonnative cases and the 20 annular-normal regressions pass. Static analysis and 10 changed-file formatting checks pass. Both portable formats decode with 525 matching ModuleScript sources; 536 public functions span 68 namespaces. Remaining degenerate parameter-boundary normal decisions stay open in MODELING_PARITY.md.

## 0.73.0 — 2026-10-03

Adds optional exact annular normal proofs for stationary constrained sectors. Full-state recurrence identities and algebraic Bernstein certificates handle divergent chart derivatives, lower-order boundary modes and proved geometric nonexistence. Exact arithmetic fast paths, bounded modular reconstruction and real-spectrum isolation reduce proof cost. Work checkpoints permit yielding and cancellation. ConstrainedNormals demonstrates a higher crease.

All 1,748 Studio tests and 78 examples pass, including 21 new cases. All 20 new nonnative cases, static analysis and 27 changed-file formatting checks pass. Both portable formats decode with 520 matching ModuleScript sources; 536 public functions span 68 namespaces. Remaining degenerate-boundary decisions and uncertain refinement histories stay open in MODELING_PARITY.md.

## 0.72.0 — 2026-10-03

Restores finite derivatives at smooth four-face quad vertices when a neighboring feature prevents whole-face tensor evaluation. The local affine eigenstencils preserve parameter orientation, refinement scale and native error bounds, including dyadic queries near fixed boundaries.

All 1,727 Studio tests and 77 examples pass. Eleven added cases cover analytic quadratic tensor slopes, nearby convergence, parameter orientation, outer pins, degeneracy, extreme scales, dyadic fixed-boundary queries, snapshots, budgets and native conversion. All ten added nonnative cases and 116 focused Studio checks pass. Static analysis and four changed-file formatting checks pass. Both portable formats decode with 497 matching ModuleScript sources; 536 public functions span 68 namespaces. Higher-sector normals with divergent or degenerate finite derivatives remain open.

## 0.71.0 — 2026-10-03

Adds optional exact constrained-sector chart derivatives. A source-specific rational Krylov recurrence and exact Schur stability test prove convergence; the complete annular halo proves that the resulting affine jets apply to the surface. Nondegenerate jets supply normals, and explicit proof budgets, snapshots and native error bounds remain separate. ConstrainedJets demonstrates the query.

All 1,716 Studio tests and 77 examples pass. Twenty added cases cover 4,500 independent full-annular matrix entries, 25 exact vector recurrences, 96 known-root Schur decisions, convergence, parameter mappings, transforms, limits and native conversion. All 19 added nonnative cases and 105 focused Studio checks pass; six fixed-boundary vertex queries and 30 shrinking position slopes also pass. Static analysis and eight changed-file formatting checks pass. Both portable formats decode with 496 matching ModuleScript sources; 536 public functions span 68 namespaces. Higher-sector normals with divergent or degenerate finite derivatives remain open.

## 0.70.0 — 2026-10-03

Adds proved limiting normals for ordinary three-face crease sectors and fixed three-face sectors with an exact midpoint boundary identity. A complete annular operator and positive characteristic Jacobians establish the normal. Exact annihilation of the growing transverse mode yields finite rank-one face-chart derivatives. ThreeFaceCrease demonstrates the query.

All 1,696 Studio tests and 76 examples pass. Fifteen added cases cover 882 independent complete-annular matrix coefficients and 324 exact characteristic Jacobian coefficients, analytic convergence, transforms, fixed-midpoint identity checks, hard junctions, limits and native conversion. All 14 added nonnative cases and 42 related nonnative regression cases pass. Static analysis and nine changed-file formatting checks pass. Both portable formats decode with 491 matching ModuleScript sources; 536 public functions span 68 namespaces. Higher constrained sectors and remaining degenerate normal cases remain open.

## 0.69.0 — 2026-10-03

Adds optional `edgePairs=true` to feature regularization. Exact closest points on nonparallel edges and midpoint representatives of parallel overlap intervals create conforming shared native anchors with separate source-sheet identities. Original-reference movement bounds, triangle-motion checks and original attribute maps remain in force. EdgeContactSheets demonstrates the operation.

All 1,681 Studio tests and 75 examples pass. Sixteen added cases cover 160 independent exact closest-pair witnesses and reversed operands, separate-sheet refinement, original attributes, exact-radius and native-rounding boundaries, snapshots, limits and native anchor identity. All 81 affected nonnative cases pass. Static analysis and 8 changed-file formatting checks pass. Both portable formats decode with 488 matching ModuleScript sources; 536 public functions span 68 namespaces. Higher extraordinary constrained-sector derivatives remain open.

## 0.68.0 — 2026-10-03

Adds `regularization={method="features",distance=d}` for unmatched source vertices near edge or face interiors. Exact closest-feature choices, conforming refinement, original-reference movement bounds and whole-triangle orientation checks precede winding classification. Final maps compose back to original source attributes and Boolean operands. FeatureRepairedLayers demonstrates the operation.

All 1,665 Studio tests and 74 examples pass. Twenty-five added cases include 144 independent exact closest-feature witnesses, 216 triangle-motion coefficients and 648 determinant samples, plus native conversion, Booleans, original attribute correspondence and transactional limits. All 24 added nonnative cases and 42 existing vertex-regularization and rational-winding cases pass. Static analysis and 12 changed-file formatting checks pass. Both portable formats decode with 485 matching ModuleScript sources; 536 public functions span 68 namespaces. Interior edge/edge proximity regularization and higher extraordinary constrained-sector derivatives remain open.

## 0.67.0 — 2026-10-03

Extends `exactTensorPair` to periodic inputs and exact seam quotients across all four parameter axes. Homogeneous boundary identities, connected seam-cell images and algebraic anchor formulas certify complete quotient components and existing-anchor equivalence. Exact Bernstein zero-face reduction makes boundary-only contacts practical. PeriodicTensorContacts demonstrates a biquadratic seam curve and a separate curved component.

All 1,640 Studio tests and 73 examples pass. Seventeen added cases cover 3,888 independent Bernstein contact coefficients across 48 weighted tensor pairs, periodic curves, overlap, four-axis corners, exact seam rejection, anchor equivalence, limits, snapshots and native UV conversion. All 41 affected nonnative tests pass. Static analysis and 11 changed-file formatting checks pass. Both portable formats decode with 478 matching ModuleScript sources; 536 public functions span 68 namespaces. Unmatched vertex/edge/face regularization and higher extraordinary constrained-sector derivatives remain open.

## 0.66.0 — 2026-10-03

Adds `SplineQuery.intersectSurfaces(...,{method="exactTensorPair"})` for arbitrary ordinary positive rational tensor surfaces. A bounded four-parameter algebraic decomposition retains exact contact components and dimensions through tangencies, nonlinear loops, weighted overlap, original knot boundaries and collapsed surfaces. Finite projection, algebraic sign and closure evidence accompany independently bounded native anchors. GeneralTensorContacts demonstrates a nonlinear loop.

All 1,623 Studio tests and 72 examples pass. Twenty-six added cases cover 51 independent principal subresultant minors, 81 GCD identities, 157 Sturm–Tarski signs and 2,304 original homogeneous span evaluations, plus analytic contacts, full/guarded projection, limits, snapshots, cancellation and native conversion. All 79 affected nonnative tests pass. Static analysis and 28 changed-file formatting checks pass. Both portable formats decode with 471 matching ModuleScript sources; 536 public functions span 68 namespaces. General periodic tensor quotients, unmatched vertex/edge/face regularization and higher extraordinary constrained-sector derivatives remain open.

## 0.65.0 — 2026-10-03

Adds `SplineQuery.intersectSurfaces(...,{method="exactGraphPair"})` for two curved tensor surfaces with a common exact affine planar projection. A global decomposition over original knot-span pairs preserves tangent points, singular curves, closed loops, boundary contacts and curved overlap with complete parameter components. GraphSurfaceContacts demonstrates a closed contact loop.

All 1,597 Studio tests and 71 examples pass. Twenty-five added cases cover 752 independent weighted tensor evaluations, exact affine projection identities, original and raw unclamped knot domains, singular and tangent contacts, curved overlap, finite reports, limits, snapshots and native anchor/UV conversion. All 54 affected nonnative tests pass. Static analysis and changed-file formatting pass. Both portable formats decode with 443 matching ModuleScript sources; 536 public functions span 68 namespaces. General tensor pairs without the affine-projection property, unmatched vertex/edge/face regularization and higher extraordinary constrained-sector derivatives remain open.

## 0.64.0 — 2026-10-03

Adds opt-in `regularization={method="vertexClusters",distance=d}` to intersection repair and arrangement Booleans. Source positions move before construction and winding classification, with exact nearest-representative decisions, certified triangle-motion orientation and a bound on source-surface displacement. Stable source maps retain attributes. RegularizedLayers demonstrates closing a narrow gap.

All 1,572 Studio tests and 70 examples pass. Eighteen added cases cover 1,728 independent Fraction nearest-representative references, narrow gaps and overlaps, winding and Boolean operations, attributes, oblique transforms, snapshots, limits and native conversion. All 42 affected nonnative tests pass. Static analysis and changed-file formatting pass. Both portable formats decode with 436 matching ModuleScript sources; 536 public functions span 68 namespaces. General tensor/tensor contacts, unmatched vertex/edge/face regularization and higher extraordinary constrained-sector derivatives remain open.

## 0.63.0 — 2026-10-03

Fixed two-face corners now return an oriented limiting normal when their two hard boundary directions are provably noncollinear, or exactly opposed and collinear with a nondegenerate transverse mode. The full 15-control annular operator establishes uniform normal convergence through its exact Jordan decomposition. The transverse chart derivative grows logarithmically, so finite derivative availability remains false. Existing exact-midpoint jets and unresolved collinear cases retain their distinct contracts. FixedCornerNormals demonstrates the query.

All 1,554 Studio tests and 69 examples pass. Thirteen added cases cover the exact 225 matrix coefficients and spectral identities, the full annular halo, approach directions, collinear boundary guards, transforms, scales and native normal/UV conversion. All 42 affected nonnative tests pass. Static analysis and changed-file formatting pass. Both portable formats decode with 432 matching ModuleScript sources; 536 public functions span 68 namespaces. General tensor/tensor contacts, broader near-coincident regularization and higher extraordinary constrained-sector derivatives remain open.

## 0.62.0 — 2026-10-03

Adds `SplineQuery.intersectSurfaces(..., {method="exactRuledPair"})` for two positive rational ruled surfaces. Exact Boolean projection of compact convex ruling fibers retains curved loops, isolated tangencies, overlaps, collapsed parameter fibers, original knots and periodic profile seams in both operands. Finite guarded Cramer certificates establish coverage, dimensions and connected parameter components; native accuracy and full cell topology remain separate. RuledPairContacts demonstrates two curved cylinders and self-overlap.

All 1,541 Studio tests and 68 examples pass. Twenty-eight added cases include 1,024 independently classified polynomial fibers, 384 weighted original-knot fibers and 508 exact extreme vertices, plus curved loops, tangencies, rank changes, both profile-knot and periodic directions, snapshots, limits and native conversion. All 27 new nonnative tests and all 30 existing tensor/plane nonnative tests pass. Static analysis and changed-file formatting pass. Both portable formats decode with 429 matching ModuleScript sources; 536 public functions span 68 namespaces. General tensor/tensor contacts, broader near-coincident regularization and extraordinary constrained-sector derivatives remain open.

## 0.61.0 — 2026-10-02

Adds `SplineQuery.intersectSurfaces(..., {method="exactTensorPlane"})` for general positive rational tensor first surfaces against rank-two affine patches. Exact bivariate decomposition retains singular contacts, closed loops, isolated tangencies and curved coplanar regions. Original knot tiles and full periodic seam contacts are identified in both directions, including two-axis corners. The finite symbolic certificate keeps parameter components and native accuracy separate. TensorPlaneContacts demonstrates use.

All 1,513 Studio tests and 67 examples pass. Fifty-three added tests include 32 independent full-coefficient resultants, 28 certified common factors, 40 Fraction-clipped line arrangements and 576 tensor de Boor evaluations, plus analytic singular contacts, both knot and periodic directions, false native seam coincidences, precision, snapshots, hard limits and native conversion. All 52 new nonnative tests pass. Static analysis and formatting pass. Both portable formats decode with 415 matching ModuleScript sources; 536 public functions span 68 namespaces. General curved/curved classification, broader near-coincident regularization and extraordinary constrained-sector derivatives remain open.

## 0.60.0 — 2026-10-02

Exact ruled-surface intersections now identify complete periodic profile contact fibers with `identifyPeriodicSeams` or `requireQuotient`. Whole seam-contained tangent rulings, corners, branch attachments and coplanar bands have exact continuous seam joins, certified quotient components and native anchor equivalence classes that retain both source UV representatives. Exact homogeneous identity rejects unequal stored seams even when native evaluations coincide. SPLINE_QUERIES.md documents cell-quotient certificates, accuracy and resource limits; PeriodicRuledContacts demonstrates a tangent ruling.

Also fixes exact curve/plane overlap classification at closed domain endpoints. Near-endpoint root isolators can no longer replace the endpoint or supply an invalid interval sample; strict rational gaps retain arbitrarily short overlaps within the proof budgets.

All 1,460 Studio tests and 66 examples pass. Eighteen periodic cell-quotient cases and two endpoint-overlap regressions cover singular seam intervals, corners, bands, exact unequal-seam witnesses, precision, snapshots, resource limits and native UV conversion. All 80 affected nonnative tests also pass. Static analysis and all changed-file formatting pass. Both portable formats decode with 394 matching ModuleScript sources; 536 public functions span 68 namespaces. General tensor-curved and multi-axis seam intersections, broader near-coincident regularization and extraordinary constrained-sector derivatives remain open.

## 0.59.0 — 2026-10-02

Adds `SplineQuery.intersectSurfaces(..., {method="exactRuled"})` for positive rational ruled surfaces against rank-two affine patches. Exact linear-fiber decomposition retains curved graphs, tangent or exceptional rulings, crossing branches, isolated closed corners and coplanar two-dimensional parameter regions. Exact algebraic bounds and closure incidences certify coverage, cell dimensions and parameter components separately from native anchor accuracy. Shared original knots have one owner; spatial coincidences and periodic endpoint representatives remain distinct. SPLINE_QUERIES.md documents symbolic cell output and resource limits; RuledContacts demonstrates use.

All 1,440 Studio tests and 65 examples pass. Thirty-four added cases include 384 independent quadratic-field comparisons and 576 Fraction-clipped fibers across 64 weighted surfaces, native conversion, snapshots and hard limits. Static analysis and changed-file formatting pass. Both portable formats decode with 390 matching ModuleScript sources; 536 public functions span 68 namespaces. General tensor-curved surface intersections, broader near-coincident regularization and extraordinary constrained-sector derivatives remain open.

## 0.58.0 — 2026-10-02

Adds `SplineQuery.intersectCurveSurface(..., {method="exactPlane"})` for positive rational curves against rank-two affine patches. Exact raw-knot powers and square-free Sturm isolation retain tangencies, per-span multiplicities, closed patch corners/edges and shared knot contacts. Exact polynomial signs produce coplanar overlap arcs and isolated exterior boundary touches, with certified parameter components and separate native endpoint error bounds. SPLINE_QUERIES.md documents symbolic arc output, resource limits and remaining curved-surface work; PlaneContacts demonstrates use.

All 1,406 Studio tests and 64 examples pass. Thirty-five added cases include 128 independent polynomial references (270 roots), 64 weighted curve/plane configurations (57 contacts), 320 Fraction de Boor samples, native conversion, snapshots and hard limits. Static analysis and changed-file formatting pass. Both portable formats decode with 378 matching ModuleScript sources; 536 public functions span 68 namespaces. General curved surface intersections, broader near-coincident regularization and extraordinary constrained-sector derivatives remain open.

## 0.57.0 — 2026-10-02

Geometric limit queries now return finite one-sided derivatives for fixed two-face sectors whose original center is exactly the midpoint of the hard boundary neighbors. An exact identity proves that the fixed and crease rules agree at every refinement, allowing the established crease jet without changing subdivision rules. FixedBoundaryPanel demonstrates shared-seam tessellation with the evaluated normals.

All 1,371 Studio tests and 63 examples pass. Sixteen added cases include 48 independent rational mask recurrences, nearby analytic-patch convergence, full-cage refinement, parameter rotations, hard-edge junctions, exact-identity rejection, degenerate tangents, native precision, snapshots, limits and native normal/UV conversion. Static analysis and changed-file formatting pass. Both portable formats decode with 368 matching ModuleScript sources; 536 public functions span 68 namespaces. General curved surface contacts, broader near-coincident regularization and other extraordinary constrained-sector derivatives remain open.

## 0.56.0 — 2026-10-02

Solid repair and arrangement Booleans now retry native winding precision failures with exact rational side samples. Homogeneous integer predicates and exact line-clearance bounds preserve narrow gaps and classify rounded nearly coincident layers; forced native/exact modes, shared work limits, arithmetic caps and bounded snapshots have explicit contracts. Native reconstruction and final audits still determine repair completion. PreciseRepair demonstrates the recovered transformed-overlap case.

All 1,355 Studio tests and 62 examples pass. Twenty-six added cases include 54 independent rational crossing references, 64 homogeneous-coordinate references, sub-resolution gaps, coplanar sampling lines, transformed overlaps, attributes, snapshots, limits/cancellation and a native EditableMesh round trip. Static analysis and changed-file formatting pass. Both portable formats decode with 365 matching ModuleScript sources; 536 public functions span 68 namespaces. General curved surface contacts, broader near-coincident regularization and extraordinary constrained-sector derivatives remain open.

## 0.55.0 — 2026-10-02

Adds `method="exactAffine"` to SplineQuery.intersectSurfaces for exact single-patch boundary, corner and overlap classification. Complete rational parameter polytopes preserve degenerate fibers separately from their spatial point, segment or polygon images. Ordered boundaries, polygon fan indices and outward whole-cell native error bounds have an explicit contract in SPLINE_QUERIES.md; AffineOverlap demonstrates use.

All 1,329 Studio tests and 61 examples pass. Twenty-seven added cases include 72 independent Cramer/minor configurations (185 exact vertices), 85 rational enclosure cases, degenerate parameterizations, native precision, extreme scales, snapshots, limits/cancellation and an EditableMesh round trip. Static analysis and changed-file formatting pass. Both portable formats decode with 358 matching ModuleScript sources; 536 public functions span 68 namespaces. General curved surface contacts, near-coincident regularization and extraordinary constrained-sector derivatives remain open.

## 0.54.0 — 2026-10-02

Periodic surface-intersection quotients now fall back to exact rational boundary-curve identity when structural seam proofs fail. Bounded integer limbs preserve stored float64 values; normalized span-polynomial cross products distinguish actual closure from native evaluation coincidence. Reports include exact equality or unequal-coefficient witnesses, and shared work/cancellation and integer-bit limits apply. SPLINE_QUERIES.md documents the proof and remaining contact-topology limits.

All 1,302 Studio tests and 60 examples pass. Seventeen added cases include 320 independent Fraction operations, 96 stored-bit inputs, 32 pointwise de Boor references, exact projective boundary identities, false native coincidences, extreme scales, snapshots, limits/cancellation and native conversion. Static analysis and changed-file formatting pass. Both portable formats decode with 351 matching ModuleScript sources; 536 public functions span 68 namespaces. General surface contacts, near-coincident regularization and extraordinary constrained-sector derivatives remain open.

## 0.53.0 — 2026-10-02

Adds Remesh.quads with protected boundary/feature samples, optional certified coarsening, conforming variable-density refinement and shape-ranked all-quad construction. Integer and rational patch correspondences certify whole-surface displacement; default endpoint intersection audits reject unsafe output transactionally. Typed data, materials, skin/groups, pins, quality targets and shared hard/soft limits have documented contracts in RETOPOLOGY.md. QuadRetopologyPanel demonstrates use.

All 1,285 Studio tests and 60 examples pass. Thirty-six added cases include 96 independent rational overlay configurations and 64 high-precision barycentric references, analytic geometry, density/shape targets, data and feature preservation, holes/periodic topology, snapshots, precision, limits/cancellation, introduced intersections and native conversion. Static analysis and changed-file formatting pass. Both portable formats decode with 346 matching ModuleScript sources; 536 public functions span 68 namespaces. General surface intersections, near-coincident regularization and extraordinary constrained-sector derivatives remain open.

## 0.52.0 — 2026-09-28

Adds SurfaceTrim.regions for union and decomposition of disconnected and explicitly unwrapped polygonal trim domains. Exact clipping with native midpoint rounding supports periodic seam/corner crossings, holes and nested islands. Uniform and adaptive tessellation accept region sets; adaptive sampling joins their periodic pieces with shared geometry and separate corner UVs. TRIMMING.md documents construction, approximation and precision limits.

All 1,249 Studio tests and 59 examples pass. Twenty-four new cases include 160 independent Fraction/400-digit clipping references, exact native midpoint ties, analytic union areas and quotient topology, tiny seam precision rejection, snapshots, limits/cancellation and native export. Static analysis and changed-file formatting pass. Both portable formats decode with 335 matching ModuleScript sources; 535 public functions span 68 namespaces. The full modeling/surface goal remains active.

## 0.51.0 — 2026-09-28

Adds opt-in local quad-grid coarsening through Simplify.unsubdivide transitions. Fine/coarse frontiers, pinned edge samples and typed edge changes remain in conforming transition polygons. Exact rational overlays and boundary-triangle bounds certify polygon-surface displacement; iterative frontier checks, topology/data constraints and endpoint audits gate completion. SIMPLIFICATION.md documents local and multi-level limits, and TransitionPanel demonstrates use. Source staging now checks Studio’s per-script source limit before transfer.

All 1,225 Studio tests and 58 examples pass. Twenty-two new cases cover all sixteen frontier patterns, analytic and cumulative deviation bounds, constraints/data, holes/periodic grids, precision, transactional failures and native conversion, including 240 independent rational/high-precision overlay configurations. Static analysis and changed-file formatting pass. Both portable formats decode with 329 matching ModuleScript sources; 534 public functions span 68 namespaces. The full modeling/surface goal remains active.

## 0.50.0 — 2026-09-27

Upgrades Simplify.decimate with bounded fixed-reference quadric scoring, segment placement, ratio targets, exact pins and weighted selections, typed features, and atomic reflection symmetry. Checked surface correspondence provides an outward two-sided distance bound independent of the quadric score. Topology/normal/data checks, source snapshots and endpoint intersection audits distinguish valid partial progress from transactional rejection. SIMPLIFICATION.md defines the contract and ReducedPanel demonstrates use.

All 1,203 Studio tests and 57 examples pass. Thirty new cases include an analytic quadric, 64 independent high-precision distance references, sampled surface coverage, every symmetry orbit, constraints and data, topology, scale/translation/sparse IDs, budgets/cancellation, collision rollback and native EditableMesh conversion. Static analysis and changed-file formatting pass. Both portable formats decode with 322 matching ModuleScript sources; 534 public functions span 68 namespaces. The full modeling/surface goal remains active.

## 0.49.0 — 2026-09-27

Adds Sculpt.brush and Sculpt.stroke for pressure-aware ordered dabs, distance spacing and dose, seven geometric brush fields, named/custom falloffs and mirror/radial/tiled symmetry. Masks, exact pins, locks, feathered overlaps and same-topology detail-base displacements compose with endpoint geometry/intersection audits. Coarse brush edits also compose with multires residual transport. SCULPT.md documents the formulas and SymmetricStroke demonstrates the workflow. `tools/studio_install.luau` now retains the two newest prior versions after a verified install.

All 1,173 Studio tests and 56 examples pass. Twenty-eight new brush cases cover analytic fields and falloffs, pressure and spacing, symmetry and feathering, detail transport, masks and data, native precision, endpoint failures, budgets and cancellation. Static analysis and changed-file formatting pass. Both portable formats decode with 313 matching ModuleScript sources; 534 public functions span 68 namespaces. The full modeling/surface goal remains active.

## 0.48.0 — 2026-09-27

Adds Sculpt.fair for constrained harmonic and biharmonic positional smoothing with uniform or signed cotangent weights. Exact pins, selections, feature boundaries and axis locks compose with shared work budgets, final native residual checks and geometry/intersection audits. Reports distinguish converged results, valid partial progress and transactional rejection. SCULPT.md defines the contract and FairPatch demonstrates the workflow. Explicit minimumFaceArea controls support tiny positive surfaces in mesh validation and normal editing while retaining default thresholds.

All 1,145 Studio tests and 55 examples pass. Twenty-eight new cases include eight independent dense references, analytic patches, signed cotangent precision, constraints and source data, scale/translation/sparse IDs, partial/native/overflow failures, collision rollback, budgets/cancellation, multires detail transport and native EditableMesh conversion. Static analysis and changed-file formatting pass. Both portable formats decode with 306 matching ModuleScript sources; 532 public functions span 68 namespaces. The full modeling/surface goal remains active.

## 0.47.0 — 2026-09-27

Adds UV.relax for improving existing layouts with angular or symmetric-Dirichlet distortion energies. Shared corner nodes preserve seams, pins and unselected UVs; boundary controls support holed and mirrored charts. Bounded L-BFGS accepts only decreasing energies measured after native rounding and retains exact triangle orientations. A final global overlap audit rolls back colliding candidates. Reports distinguish converged solutions, valid partial progress and rejected layouts. UV_MODELING.md defines the contract and RelaxedUVPanel demonstrates a curved panel.

All 1,117 Studio tests and 54 examples pass. Twenty-four new cases cover analytic optima, eight independent SciPy BFGS references, analytic-gradient checks in both windings, texture metrics, seams/holes/pins/selections, data preservation, sparse IDs/extreme scales, snapshots, bounded and native-precision failures, collision rollback and native UV/normal conversion. Static analysis and changed-file formatting pass. Both portable formats decode with 299 matching ModuleScript sources; 531 public functions span 68 namespaces. The full modeling/surface goal remains active.

## 0.46.0 — 2026-09-27

Adds Unwrap.angleBased and the angle method for multi-chart Unwrap.unwrap. Relative-angle optimization enforces triangle, interior-vertex and normalized wheel constraints, then reconstructs pinned UVs independently. Separate convergence, native orientation, measured angle residual and exact overlap checks determine success. Multi-chart calls share budgets, preserve immutable source data, pack in the texture metric and recheck final float32 UVs before committing. UV_MODELING.md defines the numerical contract; AngleAtlas demonstrates a closed torus atlas.

All 1,093 Studio tests and 53 examples pass. Twenty-one new cases cover analytic fans, nine independent dense reference solutions, analytic-gradient checks, high-valence conditioning, non-square pins, global overlaps, native precision, source data/sparse IDs/snapshots, constrained failures, work/cancellation and native atlas conversion. Static analysis and changed-file formatting pass. Both portable formats decode with 292 matching ModuleScript sources; 530 public functions span 68 namespaces. Broader UV relaxation and the full modeling/surface goal remain active.

## 0.45.0 — 2026-09-27

Adds Unwrap.autoSeams for automatic geometry-guided disk charts. Scored face-adjacency forests obey feature cuts, material/optional UV boundaries, normal cones and chart sizes. Cycle recovery removes cuts only after checking the actual corner quotient for disk topology and representable protected seams. Reports expose cut reasons, topology counts, normal variation, recovery limits and work; source data and callback snapshots stay immutable. UV_MODELING.md defines the contract and AutomaticAtlas combines automatic torus cuts, conformal unwrap and density-aware packing.

All 1,072 Studio tests and 52 examples pass. Eighteen new cases cover independent topology counts, closed and holed surfaces, feature and delimiter controls, data preservation, transforms/sparse IDs, snapshots, limits/cancellation and native UV/normal conversion. Static analysis and changed-file formatting pass. Both portable formats decode with 282 matching ModuleScript sources; 529 public functions span 68 namespaces. Angle-based unwrap and broader relaxation remain open, and the full modeling/surface goal remains active.

## 0.44.0 — 2026-09-27

Adds exact UV island discovery, whole-island affine transforms and texel-density equalization, seam attribute extraction, numerical singular stretch and exact native flip/overlap diagnostics. Deterministic rectangle packing works in the texture metric, preserves pinned/unselected obstacles, optionally normalizes density, and verifies native margins and internal overlaps before returning a successful atlas. Immutable snapshots, all-domain preservation, tangent invalidation, budgets and explicit incomplete results accompany the APIs. UV_MODELING.md defines the contracts; UVAtlas demonstrates six conformal box charts on a non-square texture.

All 1,054 Studio tests and 51 examples pass. Twenty-one new cases include 1,280 independent Fraction-based overlap decisions, analytic differential measurements, dense rectangular layouts, pinned obstacles, all typed data domains, scale/translation/native precision, budgets/cancellation and native UV/normal conversion. Static analysis and changed-file formatting pass. Both portable formats decode with 278 matching ModuleScript sources; 528 public functions span 68 namespaces. Automatic chart seams and angle-based unwrap remain open, and the full modeling/surface goal remains active.

## 0.43.0 — 2026-09-27

Adds Simplify.unsubdivide for recognized whole-component quad grids. Two graph colorings identify corner, edge and center roles, including extraordinary old vertices and ambiguous periodic grids. Accepted phases retain current native samples, preserve data seams and pins, and use exact dyadic common-triangulation evaluation with outward arithmetic to bound the entire polygon-surface change across requested levels. Per-level correspondence, normal checks, intersection audits and explicit partial results accompany bounded work and immutable snapshots. SIMPLIFICATION.md documents the contract; CoarseCage demonstrates controlled coarsening.

All 1,033 Studio tests and 50 examples pass. Twenty-one new cases include 80 independent Fraction overlays and 1,280 overlap decisions, whole-component and mixed selections, periodic phase ambiguity, typed features and data, transforms and native precision, cancellation, budgets and native export. Static analysis and changed-file formatting pass. Both portable formats decode with 271 matching ModuleScript sources; 522 public functions span 68 namespaces. Local grid transitions and broader collapse controls remain open, and the full modeling/surface goal remains active.
## 0.42.0 — 2026-09-27

Adds Simplify.planar for bounded, deterministic region dissolving and optional conforming boundary simplification. Original-face normal references and original-chain checks prevent cumulative geometric drift; exact native coplanarity handles zero-angle requests. Hole/pinch rejection, typed seam preservation, face-area and edge-length transfer, immutable snapshots, soft-limit reports and default input/output intersection audits accompany explicit numerical limits. Output positions retain source samples, with flat corner normals. SIMPLIFICATION.md documents the contract; PlanarPanel demonstrates a reduced panel with a window.

All 1,012 Studio tests and 49 examples pass, including twenty planar reduction cases. Static analysis and changed-file formatting pass. Both portable artifacts decode with 264 matching ModuleScript sources. The installed release exposes 521 public functions across 68 namespaces, with 437 checked static exports and 32 documents. The previous 0.41.0 installation is archived. Modeling/surface completion remains in progress.

## 0.41.0 — 2026-09-27

Adds analytic one-sided limit patches along regular boundaries and infinite creases, finite fixed/rounded corner partials, supported characteristic normals, exact original-control collinearity handling and explicit normal availability. Reflected tensor controls reproduce the package's existing geometric rules. Source geometry and attributes remain untouched; face orientation and refinement Jacobians preserve derivative coordinates. Unsupported extraordinary constrained sectors retain positional results without assuming a regular tangent plane. SUBDIVISION.md documents the contract; CreaseLimitPanel demonstrates a shared crease with separate corner normals.

All 992 Studio tests and 48 examples pass, including sixteen feature tests. Static analysis and changed-file formatting pass. XML and Rojo artifacts decode with 259 matching ModuleScript sources; the installed release exposes 520 public functions in 68 namespaces, with 436 static exports checked and 31 documents installed. The previous 0.40.0 installation is archived. Modeling/surface scope remains open.

## 0.40.0 — 2026-09-27

Adds opt-in exact periodic seam quotient for ordered surface intersections. Verified C0 boundary identities, bounded seam-contact exclusion and root-uniqueness witnesses join parameter endpoints without merging coincident spatial branches. Quotient circles and intervals retain source sections and all parameter representatives, share native seam vertices and preserve whole-chord bounds after endpoint replacement. `requireQuotient` has a separate topology/approximation contract from the original closed-rectangle flags.

Twenty-two new cases cover rational and doubly periodic sources, nonuniform and repeated knots, independent winding and chord errors, disconnected and coincident branches, restricted ranges, transforms/weight gauges, snapshots, incomplete source coverage, budgets/cancellation and native mesh conversion. SPLINE_QUERIES.md and PeriodicIntersectionLoop document the workflow.

All 976 Studio tests and 47 examples pass. Static analysis and changed-file formatting pass. XML and Rojo artifacts decode locally with all 256 ModuleScript sources matching; 520 public functions span 68 namespaces. The doubly periodic benchmark certifies two quotient loops in 1.21 seconds with 2,094,846 counted visits.

Seam-contained/corner contacts, uncertified higher-degree seam geometry and general singular/overlap/boundary classification remain open. The full modeling/surface goal remains active.

## 0.39.0 — 2026-09-26

Adds opt-in validated global surface-intersection paths. Shared root identities, signed chart transitions, freshly certified bridge charts, relative graph neighborhoods and first-return seed checks assemble each certified regular parameter component as one circle or interval. Ordered polylines share sample indices at every join and close without duplicating the first vertex. Uncertain chart-transition parameters retain whole-chord error bounds. `requireOrdered` has a separate topology/approximation contract from the existing local-cover `requireComplete` flag.

Twenty-two new cases include independent winding and chord checks for nested quartic circles, open/rational/C0 curves, nonseparable weights, periodic parameter endpoints, transforms, precision floors, budgets/cancellation, snapshots and native mesh conversion. Verification reports now use bounded StringValue chunks so full results can grow beyond Studio's single-value limit. SPLINE_QUERIES.md and OrderedIntersectionLoop document the workflow.

All 954 Studio tests and 46 examples pass. Static analysis and changed-file formatting pass. XML and Rojo artifacts decode locally with all 251 ModuleScript sources matching; 520 public functions span 68 namespaces. The nested quartic benchmark certifies two ordered loops with 208 chords in 76.12 seconds and 167,763,480 counted visits.

Periodic seam quotient and general singular, overlap and difficult boundary classification remain open. The full modeling/surface goal remains active.

## 0.38.0 — 2026-09-26

Adds certified surface/surface parameter component partitions with shared-root witnesses, proved separation, explicit unresolved pairs and bounded connectivity work. `requireComponents` is independent of chord accuracy and `requireComplete`. Periodic endpoints and distinct parameters at coincident world positions remain distinct. `IntersectionComponents` demonstrates two certified branches. SPLINE_QUERIES.md specifies the proof and report contracts.

Search now uses closed midpoint children, proved covered-region cuts and an exact affine-partner specialization when the other control hull projects strictly inside its parameter domain. Tighter exact arithmetic identities retain flush-to-zero safeguards, and endpoint contraction continues when any dependent coordinate makes useful progress. Independent arithmetic fixtures cover 3,078 bit/enclosure checks. Nineteen new regression cases include exact nested quartic circles, independently sampled coverage and witness positions, nearby/coincident branches, transforms, seam distinction, precision and budget/cancellation behavior.

All 932 Studio tests and 45 examples pass. Static analysis and changed-file formatting pass. XML and Rojo artifacts decode locally with all 247 ModuleScript sources matching; 520 public functions span 68 namespaces.

Global arc ordering/deduplication, periodic seam quotient and general singular, overlap and boundary classification remain open. The full modeling/surface goal remains active.

## 0.37.0 — 2026-09-26

Adds SplineQuery.intersectSurfaces with interval-certified local graph curves, exhaustive root coverage and ordered native chord approximations. Parametric Krawczyk inclusion proves one dependent root for every free coordinate value; adaptive coordinate choice covers closed loops and disconnected branches. Validated graph expansion and interval-Newton-image padding preserve existence certificates. Implicit first-derivative bounds certify whole chords, including C0 knots, and include native endpoint error. SPLINE_QUERIES.md documents coverage, approximation, budgets and topology limits; SurfaceIntersectionArcs demonstrates ordered output.

All 913 Studio tests and 44 examples pass. Twenty-two new cases cover independent planes, parabolas and rational circles; a closed circle requiring multiple graph coordinates; disconnected lines, nonseparable rational weights, periodic seams, raw unclamped domains, free-axis changes, weight gauges, transforms, native precision, snapshots, cancellation, budgets and UV/normal conversion. Static analysis and changed-file formatting pass. Both portable formats decode with 243 identical ModuleScript sources; 520 public functions span 68 namespaces.

Local curves can overlap; their count is not a component count. Global component connectivity, duplicate/periodic ownership and general tangent, overlap and boundary classification remain open. Incomplete search or approximation returns explicit retained regions/graphs. The full modeling/surface goal remains active.

## 0.36.0 — 2026-09-26

Adds SplineQuery.intersectCurveSurface with whole-domain interval coverage, certified isolated roots and explicit unresolved parameter regions. Raw-knot homogeneous extraction, rational derivative enclosures and Krawczyk contraction preserve ordinary/unclamped/periodic source domains. Root existence, native position accuracy and global search completion are reported separately. The arithmetic kernel uses stored IEEE754 bits and conservative normal-range widening to handle Studio subnormal flush-to-zero behavior. SPLINE_QUERIES.md defines the certificate and limit contracts; IntersectionProbe demonstrates a crossing.

All 891 Studio tests and 43 examples pass. Twenty-three intersection cases and seven interval cases cover independent analytic crossings, multiple parameter branches, exact rational spline jets, 2,900 bit-level nextafter/Fraction arithmetic checks, raw/repeated/periodic knots, common weight gauges, transforms, native precision, snapshots, allocation/work/search limits, cancellation and UV/normal conversion. A four-span periodic curve against 16 surface patches found four certified intersections with complete coverage in approximately 0.451 seconds, using 1,214,737 counted visits and a largest native position error bound of 1.36e-14. Static analysis and changed-file formatting pass. Both portable builds decode locally with 239 matching ModuleScript sources; 519 public functions span 68 namespaces.

Surface/surface intersection curves and general tangential/multiple-root, overlap, boundary and periodic-seam classification remain open. Such curve/surface regions are retained as unresolved rather than incorrectly reported empty or complete. The full modeling/surface goal remains active.

## 0.35.0 — 2026-09-26

Adds Surfaces.join for constrained fixed-weight rational C0/C1/C2 border matching. Complete common-span Bernstein identities and pivoted row QR minimize weighted control displacement with exact pins, fixed reference patches, transverse scaling and reversed correspondence. Degrees, raw knots, positive weights and unique periodic controls remain intact. Native reconstruction bounds govern completion; incompatible constraints, displacement limits and precision failures reject or return explicit diagnostic reports. SURFACES.md defines the residual and regularity contract; JoinedPanels demonstrates a pinned rational continuation.

All 861 Studio tests and 42 examples pass. Twenty-two new cases cover independent polynomial control formulas, double rational derivative bounds, all borders, mixed/high degrees, nonuniform and unclamped domains, periodic closure, exact pins, stiffness, compatible and incompatible fixed references, transforms/scales, precision, snapshots, budgets/cancellation and native UV/normal conversion. An eight-span join with 88 controls and 160 equations completed in approximately 0.109 seconds using 1,375,088 counted visits. Static analysis and changed-file formatting pass; an AST-preserving formatting change in one test block was followed by a passing rerun of all 22 final-source join tests. Both portable builds decode locally with 228 matching ModuleScript sources; 518 public functions span 68 namespaces. Intersection queries and the remaining modeling/surface requirements remain active.

## 0.34.0 — 2026-09-26

Extends classical Coons construction to independently weighted positive rational boundaries with mixed degrees, nonuniform and unclamped knot domains. Double homogeneous extraction and common Bernstein denominators produce editable tensor-product surfaces; whole-patch reconstruction bounds distinguish complete output from native precision or conditioning failures. Ordinary NURBS representation and edits now support degrees through 17. SURFACES.md documents compatibility, budgets and error semantics; RationalCoonsPanel demonstrates four independent rational borders.

All 839 Studio tests and 41 examples pass. Twenty-one new construction cases and eight high-degree spline cases cover independent geometry, derivatives and bounds, exact circular borders, raw domains, orientation, extreme common weight scales, editing, immutability, native precision, cancellation and UV/normal conversion. The older degree-limit rejection test now checks degree 18. A nine-span degree-17-by-17 patch with 2,704 controls completed in approximately 0.053 seconds using 196,016 counted visits, with a reported construction error bound of 4.18e-7. Static analysis and changed-file formatting pass. Both portable builds decode locally with 222 matching ModuleScript sources; 517 public functions span 68 namespaces. Constrained joins, intersections and the remaining modeling/surface requirements remain active.

## 0.33.0 — 2026-09-26

Adds Deform.masked to compose older topology-preserving positional operations with shared dictionary/group/channel/field masks, signed strength, local frames and axis locks. The operation receives an independent full local mesh; exact identity/connectivity checks, complete-report enforcement and final geometry validation preserve source data and reject invalid composition. DEFORMATION.md specifies callback and budget semantics; MaskedLattice demonstrates a typed influence field.

All 810 Studio tests and 40 examples pass. Nineteen new cases cover independent legacy formulas, lattice/shrinkwrap/contact/RBF, attachment and sculpt smoothing, frames, sparse masks and IDs, all data domains, callback isolation, zero influence, topology/incomplete-output rejection, cancellation/budgets and native UV/normal conversion. A 10,201-vertex masked lattice used 70,603 counted visits in approximately 0.365 seconds; 441 prepared limit queries used 2,980,937 visits in approximately 0.440 seconds in this Studio session. Static analysis and changed-file formatting pass. Both portable builds decode locally with 216 matching ModuleScript sources; 517 public functions span 68 namespaces. Modeling and surface completion remains active.

## 0.32.0 — 2026-09-26

Adds Subdivision.prepareLimit and limit for geometric queries on quad faces and explicit polygon corner patches. Local refinement respects finite/infinite and Chaikin creases; regular bicubic masks provide analytic derivatives, stationary stars provide exact real-arithmetic position masks and characteristic smooth normals, and shrinking control hulls supply bounded fallback positions. Reports separate positional completion, native precision/depth failure and derivative/normal availability. SUBDIVISION.md documents limits; LimitPanel demonstrates direct surface sampling.

All 791 Studio tests and 39 examples pass. Twenty-five new cases verify independent cubic formulas, extraordinary masks and eigenmode normals, global refinement equivalence, local halo behavior, high valence, crease transitions, native precision, sparse IDs, transforms/scales, snapshots, cancellation/budgets and native UV/normal conversion. Static analysis and changed-file formatting pass. XML/Rojo builds decode locally with 213 matching ModuleScript sources; 516 public functions span 68 namespaces. One-sided sharp-feature derivatives and the remaining modeling/surface requirements stay active.

## 0.31.0 — 2026-09-26

Adds six per-channel face-varying Catmull-Clark modes for UV, color, alpha and numeric corner attributes. Explicit edge/channel cuts, connected chart fans, persistent identities and geometric crease precedence preserve discontinuities across repeated refinement, JSON storage and multires edits. New corners with unassigned identities form fresh charts. SUBDIVISION.md documents modes, identity channels, allocation/work bounds and cancellation; SmoothUVPanel demonstrates independent data smoothing.

All 766 Studio tests and 38 examples pass, including 26 new subdivision cases covering analytic masks, coincident seams, darts/junctions/concave fans, finite/Chaikin creases, extraordinary vertices, typed defaults, sparse IDs, transforms, other attributes, new-corner interoperability, atomic multires failure and native UV/normal conversion. Static analysis and changed-file formatting pass. Both portable builds decode locally with 210 matching ModuleScript sources; 514 public functions span 68 namespaces. Limit evaluation and the remaining modeling/surface requirements remain active.

## 0.30.0 — 2026-09-26

Adds SplineFit.refineCurve and refineSurface for bounded joint nonlinear control-position, positive log-weight and sample-parameter fitting. Ordinary and unique cyclic descriptors retain degrees, knots and seam relationships; exact pins, confidence weights, active bound constraints and native-coordinate objective acceptance use analytic Jacobians and damped Givens QR. Completion reports distinguish accuracy, constrained stationarity, iteration exhaustion and native precision stalls. SPLINE_FITTING.md documents initialization, local-solve limits and dense budgets; RationalFitStudy demonstrates nonseparable weight recovery.

All 740 Studio tests and 37 examples pass. Twenty-three new cases verify independent circle/polynomial geometry, analytic Jacobian differences, joint fits, nonseparable weights, seam crossing, exact pins, constrained weighted means, transforms/scales, bounds, precision failure, cancellation inside QR and native normals/UVs. Static analysis and changed-file formatting pass. XML and Rojo builds decode locally with 207 matching ModuleScript sources; 514 public functions span 68 namespaces. Modeling and surface completion remains active, including constrained joins/intersections, rational Coons, subdivision/retopology, UV and sculpt requirements.

## 0.29.0 — 2026-09-26

Adds SurfaceEdit with weighted control selection, transforms, rational weight edits, simultaneous periodic neighbor smoothing and a validated mesh-deformation bridge. Structural APIs cover complete-border extrusion, rectangular duplication, parameter transpose, cyclic authoring toggles, shared-border splits, row/segment deletion, control-border extraction and rational spin with unique full-turn controls. SURFACE_EDITING.md documents basis changes, masks, source correspondence, callback isolation and valid-surface remnant requirements; ControlNetPanel demonstrates composition.

All 717 Studio tests and 36 examples pass. Twenty-five new cases include independent rational geometry, nonuniform/unclamped bases, cyclic endpoint splits, sparse masks, common weight scaling, every extrusion border, callback rejection, exact circular spin, native closed UV seams, cancellation and budgets. Static analysis and changed-file formatting pass. Both portable builds decode locally with all 202 ModuleScript sources matching; 512 public functions span 68 namespaces. Modeling and surface completion remains active, including nonlinear fitting, constrained joins/intersections and the remaining mesh/UV/sculpt requirements.

## 0.28.0 — 2026-09-26

Adds Modifiers.shell with minimum-norm weighted miter joins, measured native corner-plane offset error, miter limits, planar-face checks, separate skin/component orientation checks and default intersection audits. It returns explicit correspondence and completion diagnostics; requireComplete=false permits inspection of unresolved output. The existing solidify API keeps its single-mesh return and normal-offset default, while accepting the new miter mode. Typed channels, UV seams, materials, groups and skin survive both skins and boundary rims. SHELLS.md specifies geometric limits; MiterChannel demonstrates the workflow.

All 692 Studio tests and 35 examples pass, including 16 new cases covering analytic positions/volumes, both fold directions, high-valence residuals, rank-deficient fans, triangulation and transform invariance, all attributes, native UV/skin conversion, inward/disconnected components, consumed inner shells, intersection failures, cancellation/budgets and large-coordinate precision loss. Static analysis and changed-file formatting pass. Both portable builds decode locally with 196 matching ModuleScript sources; 497 public functions span 67 namespaces. Modeling/surface scope remains active.

## 0.27.0 — 2026-09-26

Adds periodic curve/surface degree elevation and knot removal while retaining unique editable control nets. Degree and knot multiplicities increase together, preserving parameterization and represented continuity. A bounded homogeneous Bernstein coefficient solve recovers controls; reconstructed native controls are checked against a conservative whole-domain position bound. Surface edits share one tensor-product bound across rational control rows. Reports distinguish full elevation, accepted removal steps and numerical/tolerance rejection. Inputs remain unchanged, with explicit control/matrix/work limits and cancellation. CYCLIC.md documents contracts; EditedPeriodicSurface demonstrates the edit sequence.

All 676 Studio tests and 34 examples pass, including 17 new cases covering independent rational line segments, supported degrees, nonuniform/repeated knots, seam derivatives, insertion/removal, partial results, native rounding, transforms, weight scaling, dense solve limits, cancellation, nonseparable surface weights and native mesh conversion. Static analysis and changed-file formatting pass. Both portable packages decode locally with 193 matching ModuleScript sources; 496 public functions span 67 namespaces. The API reference generator now includes only namespaces exported by the library. Modeling/surface scope remains open.

## 0.26.0 — 2026-09-26

Adds six deformation APIs: local-frame simple modes, shear, analytic casts, frame warp, taper profiles and distance-driven curve following. Shared masks combine vertex dictionaries, groups, typed scalar channels and fields, with inversion, signed strength and axis locks. Profiles accept anisotropic values, callbacks, linear knots or bounded rational X/Y graph inversion. Curve following supports rational, Bezier, cyclic and polyline paths; all signed axes; range fitting; endpoint extension; distance inversion; adaptive transport frames; closed seam correction; radius and roll. Sources, connectivity and all typed domains remain intact. DEFORMATION.md specifies formulas, convergence limits and geometry restrictions; CurvedDuct demonstrates composition.

All 659 Studio tests and 33 examples pass. Twenty-five added cases check independent analytic coordinates, nonuniform rational parameters, masks, callback boundaries, all axes, endpoint and closed seam behavior, transforms, channel preservation, native conversion and transactional failures. Static analysis and changed-file formatting pass. Both portable packages decode locally with 190 matching ModuleScript sources and expose 492 public functions across 67 namespaces. Full modeling/surface completion remains open in MODELING_PARITY.md.

## 0.25.0 — 2026-09-26

Adds Attributes.project for bounded data transfer between different mesh topologies. Surface barycentrics, face samples, connected corner charts and nearest source edges transfer all typed domains, intrinsic corners, materials, groups and normalized skin weights. Source-face restrictions, per-domain masks, blend factors, schema checks, source-distance limits and explicit unmatched reports make partial results auditable. Equal-distance corner samples use connected-face distance from the target face's anchor, retaining both sides of a periodic seam within one connected source chart. Voxel remeshing and voxel Booleans project data by default, expose completion/provenance reports, and add signed-distance sampling, allocation and cancellation limits. DATA_TRANSFER.md documents approximate correspondence and precision restrictions; ProjectedRemesh provides an example.

All 634 Studio tests and 32 examples pass, including 21 new cases covering independent fields and nearest distances, masks, sparse IDs, categorical and periodic chart seams, source restrictions, transformations, unmatched samples, budgets, cancellation, voxel ownership and native UV/skin conversion. A 1,106-vertex/1,152-face projection completed in about 0.266 seconds with 6,770 queries and 1,861,452 work units in the verified Studio session. Static analysis and changed-file formatting pass. XML and Rojo packages decode locally with 184 exact matching ModuleScript sources; 486 public functions span 67 namespaces. One AST-preserving test formatting change was followed by a passing rerun of all 21 projection cases before installation.

The general data-transfer and voxel channel-preservation requirements are implemented. The complete modeling/surface goal remains active for subdivision limits, remaining deformation and decimation modes, sharp shell joins, retopology, nonlinear/cyclic surface and curve editing, rational joins/intersections, UV and sculpt workflows recorded in MODELING_PARITY.md.

## 0.24.0 — 2026-09-26

Preserves typed vertex/edge/face/corner channels, groups and skin weights through adaptive split/collapse/flip, conservative simplification, normal shells, plane clipping, convex bevels, UV tiling and native authoring partitions. Local reduction respects typed/intrinsic chart discontinuities and named feature edges, with chart-local corner transfer. Shell offset controls one-sided or centered thickness. Plane clipping uses conforming bisect for concave, disconnected and holed caps; convex chamfers retain polygonal intermediate caps. UV clipping keeps full numeric parameters until native construction, avoiding rounding-generated tile-corner slivers. ATTRIBUTES.md documents correspondence, defaults and remaining projection gaps; AttributedPanel composes the updated builders.

All 613 Studio tests and 31 examples pass, including 21 added cases for all domains, categorical seams, sparse false values, repeated edits, independent areas/volumes, skin/groups, UV tile precision, cancellation/budgets and a native skinned roundtrip. Static analysis and changed-file formatting pass. Both portable files decode locally with 180 exact matching ModuleScript sources; 485 public functions span 67 namespaces.

Modeling/surface completion remains active. Voxel source projection and general data transfer, smooth face-varying subdivision and limit evaluation, remaining deformation/decimation modes, sharp shell joins, retopology, nonlinear and cyclic surface/curve edits, rational joins/intersections, UV and sculpt requirements remain open in MODELING_PARITY.md.

## 0.23.0 — 2026-09-26

Adds an audited arrangement method to Boolean union/intersection/subtraction. Shared cuts retain independent nonzero/positive/odd winding regions for both operands, including nested and geometrically intersecting source sheets. Coplanar ownership, regularized volume contacts, cutter orientation and mandatory final geometric audits are explicit. Unresolved candidates reject by default or return incomplete reports when requested. Both Boolean methods now transfer typed vertex/edge/face/corner channels through explicit source correspondence, including BSP intersections and center fans, sparse source IDs, missing schemas and empty identities. BOOLEANS.md documents the methods and BooleanChannels demonstrates typed subtraction.

All 592 Studio tests and 30 examples pass. Nineteen new cases cover analytic spatial/coplanar and rotated-square volumes, cavities and operand winding, self-intersecting inputs, touching/nonmanifold cases, curved and deterministic oblique volume conservation, repeated concave cuts, every typed domain in both methods, seams/materials, sparse IDs, schema defaults/conflicts, native round trips, transforms, cancellation and incomplete final audits. XML/Rojo artifacts preserve 173 ModuleScripts, 485 public functions across 67 namespaces and 401 checked static exports.

The modeling/surface goal remains active. Arrangement construction is numerical with a declared tolerance and explicit precision failures; nearly coincident native layers can remain unresolved. The tracker retains remaining builder/modifier, subdivision, retopology, curve/surface, UV and sculpt requirements.

## 0.22.0 — 2026-09-26

Adds MeshRepair.splitIntersections for conforming cuts with separate source-sheet identities and MeshRepair.resolveIntersections for winding-defined solid boundaries. Repair supports nonzero, positive and odd occupancy; coplanar ownership, measured tolerance corrections and retained-boundary conformity preserve shared geometry. Source correspondence transfers all four typed attribute domains, UV seams, materials, groups and skin weights. Completion requires valid closed-or-empty topology and a complete exact native-coordinate intersection audit. Unresolved nonmanifold candidates report failure, while ambiguous construction/classification rejects transactionally. INTERSECTION_REPAIR.md documents the contracts and RepairedSolid demonstrates a triple overlap.

All 573 Studio tests and 29 examples pass. Twenty-four added cases cover analytic union, rotated-square and triple-overlap volumes, separate open/closed/coplanar sheets, nested/cancelling/inward components, a connected self-intersecting source, unresolved tangencies, all attribute domains, idempotence, scale/oblique transforms, cancellation/budgets, incomplete final audits and native round trips. XML/Rojo artifacts preserve 169 ModuleScripts, 485 public functions across 67 namespaces and 401 checked static exports.

The modeling/surface goal remains active. This is bounded numerical repair with an explicit tolerance, not exact algebraic Boolean construction. Near-coincident layers below native classification clearance can reject. Broader degeneracy regularization, rational-surface intersections and the remaining modifier, retopology, surface, UV and sculpt requirements remain tracked.

## 0.21.0 — 2026-09-26

Adds the Intersections namespace for exact native-coordinate segment/triangle and triangle/triangle classification, homogeneous intersection construction, ordered coplanar overlap boundaries and barycentric source data. Bounded BVH scans report self/cross-mesh crossings, overlaps and unwelded contacts while excluding only ordinary shared features. Native coordinate collapse is reported separately from exact intersection dimension. Optional strict Boolean input/output checks reject geometric defects and incomplete scans. INTERSECTIONS.md and the callable IntersectionAudit example document use.

All 549 Studio tests and 28 examples pass. Nineteen added cases include 216 independent Python Fraction fixtures under operand/winding permutations, exponent scales, near-coplanar separation, native construction collapse, exact construction after parameter cancellation, exhaustive BVH comparisons, shared-feature regressions, analytic Boolean volumes, limits/cancellation and native round trips. The existing predicate suite remains unchanged in behavior after sharing private expansion arithmetic. XML/Rojo artifacts preserve 163 ModuleScripts, 483 public functions across 67 namespaces and 399 checked static exports.

Modeling/surface completion remains active. Diagnostics do not perform intersection splitting/repair or make BSP construction exact; those requirements, rational-surface intersections and the remaining modifier/retopology/UV/sculpt rows remain tracked.

## 0.20.0 — 2026-09-26

Adds SurfaceTrim.adaptive with shared Bernstein patch bounds, conservative excluded-region pruning, constrained UV arrangements and edge-based region classification. Periodic seam contacts synchronize before welding, including unequal trim ranges; complete and partial boundary poles collapse with preserved corner UVs. Reports include per-face bounds, parameter rounding, trim-boundary displacement, seam-stitch error, limits and explicit nonconvergence. TRIMMING.md documents the numerical contracts and TrimmedShell demonstrates a spherical band with a window.

All 530 Studio tests and 27 examples pass. Eighteen new cases cover affine areas, curved holes, concavity, nonuniform patches, narrow strips, complete sphere/torus and partial pole topology, asymmetric seam contacts, arbitrary knot boundaries, measured triangle-interior error, scale/translation/weight invariance, cancellation/budgets and native EditableMesh round trips. Shared predicate broad-phase rejection and planar point-location bounds reduce needless exact arithmetic while retaining all existing predicate and knife regressions. XML/Rojo artifacts preserve 156 ModuleScripts, 479 public functions and 66 namespaces; 395 static exports are verified in Studio.

Modeling/surface completion remains active. Surface/mesh intersections and repair, constrained joins, rational Coons construction, nonlinear and cyclic edits, remaining builder transfer, advanced modifiers/subdivision, retopology, UV and sculpt work are still tracked. Approximation bounds describe the rational control-net model subject to floating-point roundoff, not interval arithmetic certificates or guarantees against surface folds.

## 0.19.0 — 2026-09-26

Adds constrained planar arrangements with holes, crossing and overlapping paths, closed/retraced strokes, free interior endpoints and full segment provenance. Convex diagonal exchanges recover constraints while preserving the arranged network. The new MeshEdit.knifeNetwork API shares boundary cuts across neighboring faces and transfers typed channels, corner/UV seams, materials, skin weights and groups. KNIFE_NETWORKS.md documents native-precision intersection construction and budgets; KnifePanel provides a callable closed-solid example. The existing polygon-preserving knife API remains available.

All 512 Studio tests and 26 examples pass, including 27 added cases for analytic areas/volumes, grids, holes, deterministic randomized/reversed networks, overlaps, pinched recovery regions, construction error limits, all attribute domains, transforms, cancellation and native EditableMesh round trips. XML/Rojo builds preserve 151 ModuleScripts and 478 public functions across 66 namespaces, with 394 static exports checked in Studio.

The modeling/surface goal remains active. Global 3D intersections/repair, remaining builder transfer, subdivision/deformation, retopology, nonlinear and trimmed surfaces, UV and sculpt requirements remain tracked in MODELING_PARITY.md.

## 0.18.0 — 2026-09-26

Adds selected weighted edge/vertex bevels with source-face offsets, shared source-edge cuts, multi-segment circular/linear/custom profiles, conforming partial selections and patch/cutoff junctions. Reentrant solids, reflex terminations, open boundaries and higher-valence junctions are supported. Compatible round junctions receive spherical radial refinement; other non-star-shaped junctions use robust triangulation. Modifier selection supports angles, explicit masks and typed weight channels. UV/corner seams, materials, typed channels, skin weights and groups follow explicit correspondence. BEVELS.md documents contracts and BeveledHousing combines a recess, bevel and weighted normals.

All 485 Studio tests and 25 examples pass, including 24 added cases with independent wedge/tetrahedron/truncated-cube volumes, circular-profile integration, rounded-box convergence, custom profiles, an eight-edge junction, varying attributes, cancellation/limits/collapse and native EditableMesh roundtrips. A rigid-transform regression exposed world-coordinate rounding in sphere matching; profile and sphere calculations now retain local vertex-relative coordinates. XML/Rojo artifacts decode with matching sources for 146 ModuleScripts, with 476 public functions in 66 namespaces and 392 static exports checked in Studio.

The broader modeling/surface goal remains active: general knife arrangements, global 3D intersection diagnostics/repair, remaining builder transfer, advanced subdivision/deformation, retopology, nonlinear and trimmed surface work, UV and sculpt requirements are still open. The documented bevel junction policies do not claim identical topology for every Blender miter option.

## 0.17.0 — 2026-09-26

Adds the Normals namespace for connected smoothing groups, uniform/area/angle/product weighting, face multipliers and priority ranks, explicit custom corner values, custom averaging, masked blends, directional/radial/rotation/flip edits and persistent sharp-edge metadata. Existing tangents are reprojected on edited normals; explicit UV tangent generation retains UV/normal/mirrored seams and reports degenerate frames. NORMALS.md documents contracts and the WeightedNormals example composes the APIs. Existing Mesh:recalculateNormals behavior remains available.

All 461 Studio tests and 24 examples pass. Twenty-two new cases verify independent anisotropic-box formulas, smooth cylinder sides, reflex polygon corners and triangulation equivalence, source-data preservation, masks and priorities, extreme finite vectors, invalid fans, cancellation/budgets, mirrored/folded/degenerate UVs, typed UV channels, tilted frames, scale/translation and native custom-normal round trips. Both portable artifacts decode with matching sources for 142 ModuleScripts. The API includes 473 public functions in 66 namespaces, with 389 static exports verified in Studio.

Modeling/surface completion remains active. General edge/vertex bevels, broader knife arrangements, remaining attribute-transfer integrations, nonlinear surface/curve work, retopology, UV and other tracker rows are still required.

## 0.16.0 — 2026-09-26

Adds quad grid filling with explicit corner partitions and curved/nonplanar boundary rails, profile spin/screw with welded seams and axis poles, conforming plane bisect with concave/disconnected/annular caps, and finite bent knife paths with shared neighboring-face edge intersections. Typed channels, intrinsic corner seams, weights and groups follow documented source correspondence. Generated cap channels use schema defaults. MESH_EDITING.md documents geometry, winding, UV choices, numerical limits and budgets; CutVessel composes spin, knife and a capped cross section.

All 439 Studio tests and 23 examples pass, including 34 new cases covering independent area/volume formulas, rectangular corner partitions, toroidal topology, signed pitch, concave retained pieces, cap holes, exact coplanar fragments, tangent cuts, all attribute domains, tilted/native round trips, scales, cancellation and budgets. XML and Rojo artifacts decode with identical sources for 137 ModuleScripts; the API has 464 public functions in 65 namespaces, with 380 static exports checked in Studio.

Knife paths currently run boundary-to-boundary within planar faces, one path per source face per call. Interior endpoints/crossing stroke arrangements, general edge/vertex bevels, advanced normals and the other modeling/surface tracker requirements remain active. Local validation is not a certificate against global 3D self-intersections.

## 0.15.0 — 2026-09-26

Adds region inset with holes and local nonplanar miters, individual face extrusion, ordered quad loop cuts with conforming non-quad endpoints, explicit adjacent-vertex slides, poke, delimited triangle-to-quad pairing, cleanup and component winding repair. Typed vertex/edge/face/corner channels, skin weights and groups follow explicit correspondence. Edited polygons undergo simplicity and triangulation checks; planar inset boundaries are checked for crossing, collapse and departure from the selected region. MESH_EDITING.md documents each operator's geometry, data rules, budgets and limits.

All 405 Studio tests and 22 examples pass, including 30 new cases covering independent area/volume formulas, UV and attribute seams, open/closed topology, holes, nonplanar patches, scale/translation, cancellation, budgets, invalid geometry and composed modeling through native EditableMesh conversion. XML and Rojo artifacts decode with identical sources for 131 ModuleScripts. Studio source parity and 375 static exports are verified; the API has 459 public functions in 65 namespaces. AST-verified formatting changed two source layouts after testing without changing their semantics.

General edge/vertex bevels, knife/bisect arrangements, grid fill, spin/screw, broader normal editing, builder-wide transfer and the other modeling/surface tracker rows remain in progress. Cleanup and winding repair explicitly report unresolved topology; these operations do not certify absence of 3D self-intersections.

## 0.14.0 — 2026-09-26

Adds editable cubic Bezier chains with free/aligned/vector/automatic handle pairs, anchor/handle editing, nonuniform segment durations, shape/parameter-preserving subdivision, closed seam reversal and NURBS conversion. ArcLength adds immutable prepared length intervals, bounded inverse distance/fraction queries and reusable uniform-distance sampling. SplineQuery sampling optionally bounds rational derivative directions using Bernstein forward cones. CURVE_EDITING.md and BezierDistanceStudy describe the numerical and editing contracts.

All 375 Studio tests and 21 examples pass. Twenty-one new cases cover independent polynomial/circle geometry, nonuniform rational speed, zero-length spans, handle transitions, seam edits, derivative-preserving splits, weight/scale/translation effects, budget failure, cancellation and an edited-curve sweep through native EditableMesh conversion. XML and Rojo artifacts decode locally with matching sources for all 125 modules; Studio source parity and 367 static exports are verified. The package has 451 public functions across 63 namespaces.

In the recorded Studio run, a radius-three circle length map prepared 937 segments in approximately 0.041 seconds and produced 128 distance samples in 0.014 seconds, with reported residual bounds below 0.0005. These measurements are machine-specific. Modeling and surface completion remains active; cyclic degree/removal edits, nonlinear fitting and the remaining mesh/surface/UV rows are still open.

## 0.13.0 — 2026-09-26

Adds detached directed-corner connectivity, vertex-fan/duplicate-face diagnostics, boundary loops and component Euler/genus reports. Selection now supports bounded heap geodesics, vertex/edge/face paths, seam barriers, linked regions, ordered quad loops/rings and region boundaries. Typed attributes and masks convert across all four mesh domains with explicit incidence, weighted reductions, sparse defaults, cancellation and allocation budgets. CONNECTIVITY.md and the MeshRegions example document use.

All 354 Studio tests and 20 examples pass, including 27 added cases. XML and Rojo artifacts deserialize in Lune with identical sources for 119 ModuleScripts; the Studio verification tree also matches those sources. The XML writer now emits the standard `<roblox>` prefix so format sniffing accepts it. This Studio session cannot load local assets through InsertService or localhost GetObjects, so portable-file decoding is verified locally and native behavior is verified through the matching installed ModuleScript tree. Modeling and surfaces remain in progress as recorded in MODELING_PARITY.md.

## 0.12.0 — 2026-09-26

Adds typed sparse vertex/edge/face/corner attributes with explicit weighted transfer, validated JSON persistence, core Topology and subdivision integration, named UV seams and sharp-normal channels. Split/inset now carry skin weights and selection groups; extrusion retains groups and source materials. Adds uniform and Chaikin edge/vertex creases, fractional transitions, boundary controls, allocation budgets and connected-fan validation, with sharp normals on infinite creases. See ATTRIBUTES.md for contracts and remaining integration gaps.

All 327 Studio tests pass, including 30 new cases. The source package includes 19 examples, 112 ModuleScripts and 428 public functions across 60 callable namespaces. Modeling and surfaces remain in progress: remaining builders, smooth face-varying modes, limit evaluation and the other tracker rows are still open.

## 0.11.1 — 2026-09-26

Core face triangulation now uses exact projected orientation signs, optional simplicity validation and explicit work budgets. Face normals use centered scalar arithmetic with exact projected-area fallback when cancellation erases the area vector. Signed volume uses scalar compensated accumulation and a local origin for closed meshes, while preserving shared-origin additivity for open pieces such as texture tiles.

All 297 Studio tests pass, including six new cases for extreme representable triangles, cancelled normals, translated concave faces, closed-volume translation invariance, collinear boundaries and validation budgets. The full regression suite verifies that UV tile volumes still add to the original solid. Modeling/surface completion remains active.

## 0.11.0 — 2026-09-26

Adds filtered exact native-coordinate predicates, segment/polygon classification and intersection construction; Planar provides bounded intersection diagnostics and validated polygon triangulation with disjoint holes. SurfaceTrim adds copied UV trim descriptors, classification/evaluation, sampled rational boundary curves and conforming uniform trimmed meshes with explicit resolution contracts.

All 291 Studio tests and 18 examples pass. XML and Rojo builds have matching sources for 106 ModuleScripts, with 421 public functions across 59 callable namespaces. Static analysis and AST-verified formatting pass.

Twenty-eight new tests include 227 independent exact-rational fixtures (24 expose naive determinant errors), native exponent limits, multiple concave holes, collinear boundaries, cancellation, allocation limits, curved and annular trim domains, area/topology checks and native EditableMesh round trips. PREDICATES.md and TRIMMING.md document the new APIs. BSP booleans remain tolerance-based; bounded adaptive trim meshes and the other modeling requirements remain unfinished.

## 0.10.0 — 2026-09-26

Adds prepared NURBS evaluators and rational Bezier patch extraction; SplineQuery provides bounded curve length, adaptive sampling, and closest curve/surface points with global hull bounds. SurfaceAdaptive constructs conforming triangle meshes using homogeneous Bernstein approximation bounds, including synchronized closed seams and collapsed boundary poles. Limit exhaustion returns explicit nonconvergence; invalid topology and allocation failures throw.

All 263 Studio tests and 17 examples pass. XML and Rojo builds have matching sources for 98 ModuleScripts, with 405 public functions across 56 callable namespaces. Static analysis and AST-verified formatting pass.

Twenty-one new cases verify exact circle lengths, geometric deviation between samples, multiple closest-point minima, independent primitive projections, triangle-interior approximation errors, scale/weight invariance, world translations, seams, cancellation and native EditableMesh round trips. The AdaptiveSurfaceStudy example and SPLINE_QUERIES.md document use and numerical limitations. Modeling/surface completion remains open.

## 0.9.0 — 2026-09-26

Adds unclamped NURBS domains and exact active-domain clamping; Cyclic stores unique periodic curve/surface controls and preserves seams through editing, insertion, reversal and seam rotation. Surfaces adds rational arcs and primitives, compatible sections, extrusion/revolution, ruled surfaces, homogeneous section lofts and polynomial Coons patches. NURBS tessellation now supports deliberate seam closure and boundary pole fans with per-corner UVs/normals.

All 242 Studio tests and 16 examples pass. Both portable builds contain the same 93 ModuleScript sources, with 396 public functions across 54 callable namespaces. Static analysis and AST-verified formatting pass.

Thirty-four new tests check independent geometry, rational parameters and weight scales, seam derivatives, section interpolation, primitive normal orientation, manifold topology and native EditableMesh round trips. Construction, Cyclic and NURBS guides describe numerical contracts and remaining restrictions. Full modeling/surface completion remains active in MODELING_PARITY.md.

## 0.8.0 — 2026-09-26

Adds shape-preserving NURBS degree elevation, conservative curve/surface knot removal, Bezier span extraction and rational basis weights. SplineFit adds fixed-weight rational curve/surface least-squares fitting and interpolation, exact control pins, observation confidence, explicit rank/budget/cancellation failures and residual reports. Nonseparable surface weights are solved as a coupled system. A FittedSurface example and 26 new tests cover independent polynomial/circle geometry, rational weight scales, preserved parameters, rejected edits and interpolation constraints.

Modeling/surface completion is active and tracked in MODELING_PARITY.md; periodic splines, trimming, adaptive tessellation and the other recorded requirements remain unfinished. This release is not a Blender parity claim.

## 0.7.0 — 2026-09-24

Adds fourteen `NURBS` functions for positive-weight clamped curves and tensor-product surfaces: evaluation, first/second derivatives, curvature, homogeneous knot insertion, splitting, reversal, isoparametric curves and tessellation. Descriptors retain editable controls and knots; operators preserve rational shapes under refinement. See NURBS.md for parameter conventions, numerical limits and omitted spline capabilities.

The package now has 358 public functions across 51 callable namespaces, 81 portable ModuleScripts and fourteen examples. All 182 Studio tests and fourteen examples pass. Fifteen new tests include exact circular arcs/cylinders, independent finite differences, unequal surface weight scales, native conversion, boundary derivatives and cancellation. All 81 sources match across the XML and Rojo builds; 274 static exports were verified. Standalone Luau analysis and AST-verified formatting pass. Embedded NURBS and GLTF guide StringValues use `_GUIDE` names to avoid collisions with their API ModuleScripts.

## 0.6.0 — 2026-09-24

Adds weighted proper-rotation, rigid and similarity registration plus local/global surface ARAP. The four additional public functions bring the package to 344 functions across 50 callable namespaces, 78 ModuleScripts and thirteen examples. Solves preserve exact anchors and inactive components, retain mesh attributes, expose energy and convergence reports, and support cancellation. Weighted quaternion fitting handles half-turns and ambiguous rank-deficient correspondences. A local solve origin reduces world-offset cancellation. See DEFORMATION.md for numerical budgets and limitations.

Eleven new regression cases cover rotation fitting, confidence scaling, energy reduction, exact anchors, disconnected and sparse-ID meshes, cancellation, explicit failure and world-translation equivalence.

Validation: all 167 Studio tests and thirteen examples pass. XML and Rojo binary builds contain matching sources for all 78 modules; 260 static exports were checked against the live API. Standalone Luau analysis and AST-verified formatting pass.

## 0.5.0 — 2026-09-24

Adds nearest-triangle surface binding, harmonic/biharmonic displacement editing and connected planar strokes. The package reached 340 functions across 48 callable namespaces, 74 ModuleScripts, twelve examples and 156 passing Studio tests. Solidify preserves shell/rim metadata, and face normals use local coordinates to reduce floating-point cancellation. See DEFORMATION.md for contracts.

## 0.4.0 — 2026-09-24

Adds `Constraints` with 15 rigid-transform APIs and `Rig:skinDualQuaternion`, reaching 335 public functions across 46 callable namespaces. Constraint stacks support copy/location/XYZ-rotation/distance limits, plane floors, three aiming modes, arc-length paths, child-of rest inverses, local/world spaces, cycle rejection, and bone-pose integration. Dual-quaternion skinning preserves rigid bind correction and corner normals and avoids the tested linear twist collapse.

Thirteen new constraint/skinning tests and a pure-data ConstrainedRig example bring the package to 140 tests, 70 ModuleScripts and eleven examples. CFrame-only constraints intentionally exclude scale/shear, drivers and the complete Blender catalog. See CONSTRAINTS.md for precise behavior.

## 0.3.0 — 2026-09-24

Adds 56 public callable functions, reaching 319 functions in 45 callable namespaces. The reusable package contains 67 ModuleScripts, ten callable examples, and embedded motion/dynamics documentation alongside the existing API guides.

- `Quaternion`: CFrame/axis-angle conversion, rotation vectors, shortest-arc SLERP, SQUAD and world/local angular integration.
- `Timeline`: typed STEP/LINEAR/CUBICSPLINE channels, per-second tangents, clips, looping/ping-pong and explicit override/additive layering.
- `Morph`: additive position and corner-attribute shape keys, fixed-topology delta construction, and BVH/barycentric position-delta transfer.
- `Stroke`: accelerated closest-polyline queries, arc sampling, compact ridge/crease/fold fields, masks and endpoint fades.
- `Convex` / `Dynamics`: convex point hulls, full inertia tensors, SAT face/edge contact manifolds, angular impulses, force/torque integration, restitution and friction. Existing sphere APIs remain available separately.
- `GLTF`: core TRS/morph-weight animation import/export/evaluation, morph corner seams, normalized integer animation output, default/node weights and morph-before-skin evaluation.

Validation: 127 Studio tests and ten examples pass. All 67 source modules match between the XML and Rojo binary builds; 239 exported static functions were checked against the live API. Standalone Luau analysis and AST-verified formatting pass. Complete Blender parity remains unfinished; the scope limits are explicit in `Capabilities` and the guides.

## 0.2.0 — 2026-09-24

Adds 50 public callable functions across seven namespaces, taking the package to 263 functions and 39 callable namespaces. The portable package contains 56 ModuleScripts, eight callable examples, and embedded API/geometry/interchange/shading documentation.

- `Boolean`: polygon BSP union, intersection and subtraction with cut-edge conformance, corner/skin/group interpolation, material offsets, bounded execution and topology validation. Convex fragments return explicit triangles. A deterministic 48-operation oblique-cut regression checks near-coincident seams and volume identities.
- `Adaptive`: local density refinement with incremental edge adjacency and a priority queue, plus bounded split/collapse/flip/relax/project remeshing with boundary/seam/sharp-edge protection.
- `Conformal`: pinned LSCM disk-chart parameterization and UV angle/orientation diagnostics. `Unwrap.unwrap` now accepts `{method="lscm"}`.
- `GLTF`: in-memory glTF JSON/GLB geometry and skin interchange, affine hierarchy evaluation, material/image payloads, sparse/strided/normalized accessors, and a rig bridge. Unsupported animation/morph/compression data rejects explicitly.
- `BSDF`, `Lighting`, `Integrator`: GGX reflection and visible-normal sampling, Fresnel/refraction, textured mixtures, area and environment importance sampling, direct illumination, MIS, HDR output and tone mapping.
- Adds `RunAllTests`, three new suites and three new examples. All 94 Studio tests and eight examples passed. XML loading and all 56 ModuleScript sources in the Rojo binary were verified. The static analyzer completed without diagnostics and formatting was AST-verified.

The dense local-refinement benchmark added 300 vertices to a 65,024-triangle sphere in approximately 0.55 seconds for the refinement call on the authoring machine. This is a measured example, not a runtime guarantee.

This release does not establish Blender feature parity. Remaining scope includes exact predicates, general bevels, production retopology and solvers, complete animation/constraint and Geometry Nodes catalogs, broader interchange formats, and production rendering features. See README and the module-specific documents for limits.

## 0.1.0

Initial reusable authoring package with 213 functions, 32 callable namespaces, 47 tests and five examples. Includes the polygon mesh core, edit/deformation tools, native EditableMesh/EditableImage adapters, source snapshots and explicit CreateAssetAsync publishing.
