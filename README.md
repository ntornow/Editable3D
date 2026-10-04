# Editable3D

A headless Luau library for building and editing meshes, textures, rigs and simulations in Roblox, on top of `EditableMesh` and `EditableImage`. Think of it as a scriptable modeling toolkit: primitives, mesh editing, subdivision, sculpting, UV unwrapping, Booleans, NURBS surfaces, texture filters and baking, skinning and animation, with a transactional path for publishing results as assets.

Requiring the library has no side effects: it creates no UI, touches nothing in the scene and makes no network requests until you call something that explicitly does.

> **Status: 0.x, pre-1.0.** The API may still change between minor versions. Editable3D covers a large, documented subset of Blender-style modeling and texturing. It is **not** complete Blender feature parity or a drop-in `bpy` replacement. Each guide states its algorithmic, precision and resource limits. [MODELING_PARITY.md](MODELING_PARITY.md) tracks what is and isn't covered.

## Quick start

### 1. Get the package

Download the `editable3d-validation` artifact from the latest successful [GitHub Actions run](../../actions). It contains the built packages in `dist/`. Or build them yourself with Python 3.10+ and Rojo:

```sh
python3 tools/package.py --profile production   # dist/production/Editable3D.rbxmx (runtime only)
python3 tools/package.py                        # dist/Editable3D.rbxmx (adds tests and examples)
# or: rojo build production.project.json -o Editable3D.rbxm
```

To build and run every check that CI runs, use `python3 tools/validate.py --bootstrap`. It downloads pinned, checksum-verified tools.

### 2. Add it to your place

Insert `dist/production/Editable3D.rbxmx` into `ReplicatedStorage`, then require it:

```lua
local E = require(game.ReplicatedStorage.Editable3D)
print(E.Version)
```

The production profile contains only runtime modules. The development profile (`dist/Editable3D.rbxmx`) adds the tests, fixtures and callable examples. Keep it in `ServerStorage` and out of shipped places. The package does not depend on any scene content, asset IDs, HTTP services or Python at runtime.

Creating native editable objects and publishing assets need the corresponding Roblox API access, which differs between Studio and live servers. Most authoring workflows run in Studio's Edit context.

### 3. Make something

```lua
local E = require(game.ReplicatedStorage.Editable3D)

-- Build and shape a mesh. Operators return new meshes and leave their inputs unchanged.
local mesh = E.Primitives.box(Vector3.new(4, 4, 4))
mesh = E.Subdivision.catmullClark(mesh, 2)
mesh = E.UV.spherical(mesh)

-- Show it in the scene as a MeshPart with a generated texture.
local bundle = E.Roblox.toModel(mesh, { name = "Blob", parent = workspace, cframe = CFrame.new(0, 6, 0) })
E.Roblox.applyMaterial(bundle, { ColorMap = E.Texture.noise(256, 256, 8, 4, 1) })
```

The next section shows a longer example, and the guides below cover each area in depth.

## Documentation map

| Area | Guides |
| --- | --- |
| Full function reference | [API.md](API.md) (generated) |
| Mesh data, selection, editing | [GEOMETRY.md](GEOMETRY.md), [ATTRIBUTES.md](ATTRIBUTES.md), [CONNECTIVITY.md](CONNECTIVITY.md), [MESH_EDITING.md](MESH_EDITING.md), [KNIFE_NETWORKS.md](KNIFE_NETWORKS.md), [BEVELS.md](BEVELS.md), [SHELLS.md](SHELLS.md), [NORMALS.md](NORMALS.md) |
| Booleans, intersections, repair | [BOOLEANS.md](BOOLEANS.md), [INTERSECTIONS.md](INTERSECTIONS.md), [INTERSECTION_REPAIR.md](INTERSECTION_REPAIR.md), [PREDICATES.md](PREDICATES.md) |
| Subdivision, simplification, retopology | [SUBDIVISION.md](SUBDIVISION.md), [SIMPLIFICATION.md](SIMPLIFICATION.md), [RETOPOLOGY.md](RETOPOLOGY.md), [DATA_TRANSFER.md](DATA_TRANSFER.md) |
| Sculpting and deformation | [SCULPT.md](SCULPT.md), [DEFORMATION.md](DEFORMATION.md) |
| UVs, textures, shading | [UV_MODELING.md](UV_MODELING.md), [SHADING.md](SHADING.md) |
| Curves and surfaces | [NURBS.md](NURBS.md), [CYCLIC.md](CYCLIC.md), [SPLINE_FITTING.md](SPLINE_FITTING.md), [CURVE_EDITING.md](CURVE_EDITING.md), [SURFACES.md](SURFACES.md), [SURFACE_EDITING.md](SURFACE_EDITING.md), [SPLINE_QUERIES.md](SPLINE_QUERIES.md), [TRIMMING.md](TRIMMING.md) |
| Rigs, animation, simulation | [CONSTRAINTS.md](CONSTRAINTS.md), [MOTION.md](MOTION.md), [DYNAMICS.md](DYNAMICS.md) |
| Import/export | [GLTF.md](GLTF.md) |
| Limits, typing, publishing | [PRODUCTION.md](PRODUCTION.md) |
| Coverage vs. Blender | [MODELING_PARITY.md](MODELING_PARITY.md) |
| Contributing and releases | [MAINTAINING.md](MAINTAINING.md), [CHANGELOG.md](CHANGELOG.md) |

## License

[MIT](LICENSE)

## A longer example

```lua
local E = require(game.ReplicatedStorage.Editable3D)

local mesh = E.Primitives.box(Vector3.new(4, 5, 3))
mesh = E.Subdivision.catmullClark(mesh, 3)
local mask = E.Selection.sphere(mesh, Vector3.new(0, 2, -1), 2)
mesh = E.Sculpt.move(mesh, mask, Vector3.new(0, 0.6, -0.4))
mesh = E.UV.spherical(mesh)

local bundle = E.Roblox.toModel(mesh, {
    name = "AuthoredMesh",
    parent = workspace,
    cframe = CFrame.new(0, 5, 0),
})
E.Roblox.applyMaterial(bundle, {
    ColorMap = E.Texture.noise(256, 256, 8, 4, 1),
    RoughnessMap = E.Texture.new(16, 16, Color3.new(0.7, 0.7, 0.7), 1),
})

-- Only when finished with the scene model and its native editables:
-- E.Roblox.destroy(bundle)
```

Mesh operators normally return a new mesh, leaving the input unchanged. Methods on `Mesh`, `Rig`, `Simulation`, `RigidBody`, `Dynamics`, `Fluid`, `Particles`, `Graph`, `History`, native handles, and `Texture:set` mutate their receiver. `Texture:paint`, filters and `Texture:map` return new images. Explicit `Roblox` calls create native objects. Pass a parent only when the result should enter the scene.

## Implemented capabilities

| API family | Implemented behavior |
| --- | --- |
| Mesh / Topology / MeshEdit / MeshRepair / Attributes / Connectivity | Quad grid filling, welded profile spin/screw, conforming plane bisect with concave/holed caps, finite face-local knife paths and crossing/overlapping networks with free interior endpoints, region inset, individual extrusion, quad loop cuts, slides, poke, triangle pairing, cleanup, winding repair, source-sheet intersection splitting and audited winding-boundary repair with exact rational classification for native precision failures and opt-in bounded source-vertex, vertex-to-edge/face and interior edge-pair regularization; Domain conversion, directed-corner incidence, topology diagnostics, paths/loops/rings, stable vertex/face IDs, typed sparse vertex/edge/face/corner channels and explicit transfer, concave polygon ear clipping, region extrusion, per-face inset, edge split and coplanar dissolve, loop bridge, fill, weld, extraction, connected components, orientation, normals, bounds, signed volume and manifold checks |
| Normals | Connected smooth fans, area/angle weighting and face priorities, explicit custom corner values, directional/radial/rotation/flip edits, masked blends, sharp metadata, tangent reprojection and UV derivative frames; see [NORMALS.md](NORMALS.md) |
| Subdivision / Sculpt | Catmull-Clark with uniform/Chaikin creases, boundary rules, per-channel face-varying smoothing and persistent seams; bounded geometric limit queries, regular and one-sided boundary/crease derivatives, supported characteristic normals, exact fixed/crease rule equivalence, proved fixed two-face Jordan normals, optional exact constrained-sector jets, complete bounded annular normal decisions and degenerate bicubic normal decisions with exact local refinement histories and explicit availability; multiresolution coarse-to-fine edits with transported detail residuals; weighted move, inflate, flatten, crease, displacement, Taubin smoothing and nearest mirrored-vertex symmetry; constrained harmonic/biharmonic fairing; pressure-aware ordered dabs, falloffs, mirror/radial/tiled symmetry, masks/pins/locks, detail-base and multires composition, and native endpoint geometry audits; see [SCULPT.md](SCULPT.md) |
| Selection / Deform | Sphere/box/boundary/geodesic masks; set operations; local-frame twist/bend/taper/stretch, shear, analytic casts, frame warp, graph taper profiles, distance-driven curve following; lattice, RBF handles, shrinkwrap and scalar-field projection |
| SurfaceDeform / Laplacian | Nearest-triangle surface binding with transported offsets; sparse harmonic/biharmonic displacement interpolation with exact anchors and explicit convergence reports |
| Registration / ARAP | Weighted proper-rotation, rigid and similarity fitting; local/global surface editing with per-vertex rotations, exact anchors, sparse solves and explicit energy/convergence reports |
| Modifiers / Simplify | Selected edge/vertex bevels with circular/linear/custom profiles, conforming partial selections and patch/cutoff joins, angle/channel selection, modifier composition, arrays, mirror, offset shells and concave/holed plane clipping; bounded fixed-reference quadric collapse with exact pins/masks, atomic reflection symmetry and outward surface-distance bounds, plus planar reduction and whole-component or local quad-grid coarsening with conforming transition polygons, outward error bounds and typed seam protection; see [SIMPLIFICATION.md](SIMPLIFICATION.md); see [BEVELS.md](BEVELS.md) and [ATTRIBUTES.md](ATTRIBUTES.md) |
| Boolean / Adaptive | Typed-channel-preserving BSP and audited winding-region arrangement union/intersection/subtraction; conforming local edge refinement; bounded split/collapse/flip/relax/project remeshing |
| Fields / Remesh | Sphere, box, capsule, torus and plane fields; smooth union, union/intersection/difference, shell and offset; closed-mesh winding signed distance; marching tetrahedra and voxel booleans; feature-guided all-quad retopology with density/shape targets, protected seams, whole-surface displacement bounds and transactional endpoint audits; see [RETOPOLOGY.md](RETOPOLOGY.md) |
| Curves / Bezier / ArcLength / Geometry / Stroke | Editable cubic handle chains, shape-preserving splits, reusable arc-length inversion and distance sampling; Bezier, uniform Catmull-Rom and rational B-spline curves; arc-length resampling; Bezier patches, sweeps, lofts and lathes; parametric surfaces, seeded area scatter, instancing, material slots, groups and colors |
| NURBS / SplineFit / Cyclic / Surfaces / SplineQuery / SurfaceAdaptive | Positive-weight rational curves and tensor-product surfaces, derivatives/curvature, insertion/split/reverse/isocurves, degree elevation, conservative knot removal, Bezier spans, basis weights, fixed-weight interpolation and bounded joint nonlinear curve/surface fitting, unclamped/cyclic domains, rational primitives/extrusion/revolution/lofts, rational Coons patches with bounded native reconstruction, constrained fixed-weight C0/C1/C2 patch joins with pins and whole-border residual reports, length/closest-point queries, interval-certified isolated curve/surface roots and ordered surface/surface local arcs with whole-chord error bounds, certified parameter component partitions, validated global open/closed traversal, exact affine boundary/corner/overlap cells, exact ruled/plane tangencies, crossing branches and coplanar bands with full periodic seam fiber identification, exact tensor/plane, ruled/ruled and common-affine-projection graph/graph singular contacts with complete parameter components and two-direction periodic identification, bounded exact arbitrary tensor/tensor contact components with all periodic parameter quotients, exact rational boundary identity, periodic endpoint quotient and explicit unresolved covers, prepared evaluators, bounded adaptive curve sampling and surface tessellation with seam/pole handling |
| Predicates / Intersections / Planar / SurfaceTrim | Filtered exact native-coordinate predicate signs, exact spatial segment/triangle classification and bounded BVH mesh scans, segment/polygon queries, bounded intersection diagnostics, validated triangulation with holes and constrained segment arrangements, UV trim domains and union/decomposition of disconnected/wrapped polygonal region sets, conforming uniform subdivision and bounded adaptive trim meshes with periodic seams/poles |
| UV / Unwrap / Conformal | Projection, automatic disk-chart seams and harmonic/LSCM/angle-based charts; exact corner-continuity islands, whole-island affine edits and texel-density equalization, rectangle packing with native margin audits, singular stretch and exact flip/overlap diagnostics, pinned angular or symmetric-Dirichlet UV relaxation, seam extraction and texture tile cuts; see [UV_MODELING.md](UV_MODELING.md) |
| Texture / Bake | Linear float RGBA, bilinear sampling, resize, alpha compositing, Gaussian blur, brush painting, noise, height normals, sRGB conversion and tiles; UV rasterization, nearest-surface normal baking, ray-traced AO, camera projection and dilation |
| Rig / Animation / Timeline / Morph | Bone hierarchy, FK, nearest-segment weights, normalized linear and dual-quaternion skinning, FABRIK positions and local-pose IK, fixed-topology blend shapes; step/linear/smooth tracks, typed Hermite channels, quaternion interpolation, looping, layers, sparse corner-aware morphs, nearest-surface delta transfer and frame baking |
| Constraints | Ordered CFrame copy/limit/track/path/child-of operators, local/world spaces, dependency cycle rejection and a rig pose bridge |
| Simulation | XPBD distance and tetrahedral-volume constraints, pinned particles, field collisions, cloth stretch/shear and opposite-vertex bend springs; sphere rigid-body impulses/friction/angular motion; convex hulls, SAT manifolds and full-inertia convex dynamics; particles and a small SPH fluid solver |
| Graph / History / Jobs | Acyclic procedural evaluation, cycle rejection, mesh undo/redo with validation, cooperative asynchronous work, cancellation and progress |
| Camera / Render / PathTrace | Pinhole projection, inverse rays, landmark residuals and camera fitting; CPU diffuse/shadow previews, silhouettes and IoU comparison; Monte Carlo diffuse/ideal-metal/dielectric path tracing |
| BSDF / Lighting / Integrator | GGX reflection and visible-normal sampling, Fresnel, textured material mixtures, area/point/directional/environment light sampling, CPU path tracing with MIS, HDR output and tone mapping |
| GLTF | In-memory glTF 2.0 JSON/GLB geometry, hierarchy, material/image payloads, skin weights, affine transforms, CPU skin evaluation and rig bridge; morph targets and TRS/weight animation import, evaluation and export |
| Roblox / IO | Native mesh/image conversion, attributes, bones/weights, scene placement, partitioned meshes with common source normals, PBR materials, tiled mesh/texture export, explicit asset publishing; JSON source snapshots and OBJ geometry |

`API.md` lists every public function signature. [GEOMETRY.md](GEOMETRY.md), [GLTF.md](GLTF.md), and [SHADING.md](SHADING.md), [MOTION.md](MOTION.md), and [DYNAMICS.md](DYNAMICS.md), and [CONSTRAINTS.md](CONSTRAINTS.md) document the additional algorithms and contracts. [DEFORMATION.md](DEFORMATION.md) describes surface controls, differential editing and connected planar strokes. [NURBS.md](NURBS.md) documents rational curve/surface control and refinement. [SPLINE_FITTING.md](SPLINE_FITTING.md) covers linear interpolation and nonlinear rational control/weight/parameter fitting. [CYCLIC.md](CYCLIC.md) covers periodic control nets; [SURFACES.md](SURFACES.md) covers exact construction and mesh seams. [SPLINE_QUERIES.md](SPLINE_QUERIES.md) documents geometric queries and adaptive approximation bounds. [PREDICATES.md](PREDICATES.md) covers exact sign decisions and polygon domains; [INTERSECTIONS.md](INTERSECTIONS.md) covers spatial contacts, overlaps and mesh audits; [TRIMMING.md](TRIMMING.md) covers trimmed surfaces and current restrictions. [MESH_EDITING.md](MESH_EDITING.md) covers polygon edits and repair; [KNIFE_NETWORKS.md](KNIFE_NETWORKS.md) covers constrained triangulation and crossing knife networks. [CURVE_EDITING.md](CURVE_EDITING.md) covers editable handles and distance/tangent-controlled sampling. [MODELING_PARITY.md](MODELING_PARITY.md) records the completed modeling/surface scope, implementation evidence and documented exclusions. `E.Capabilities` provides a runtime description and limitations.

## Important contracts

- Typed custom channels, topology transfer, JSON schema and crease rules are documented in [ATTRIBUTES.md](ATTRIBUTES.md) and [CONNECTIVITY.md](CONNECTIVITY.md). [DATA_TRANSFER.md](DATA_TRANSFER.md) covers masked projection across different topology and voxel reconstruction. Native/file interchange does not retain arbitrary custom channels.
- [DEFORMATION.md](DEFORMATION.md) covers shared deformation masks, local coordinates, signed curve axes, graph profiles, endpoint behavior and bounded numerical queries. Output validation does not certify global injectivity or collision avoidance.
- [SHELLS.md](SHELLS.md) covers sharp miter shells, measured face-offset error, orientation checks, intersection audits, incomplete output and the single-result `solidify` compatibility API.
- [SURFACE_EDITING.md](SURFACE_EDITING.md) covers `SurfaceEdit`: weighted control-grid edits, border extrusion, subgrids, splits/deletions, cyclic toggling and rational spin. Structural grid edits rebuild the changed basis; use knot refinement for shape-preserving subdivision.
- [SUBDIVISION.md](SUBDIVISION.md) covers smooth per-channel UV/color/scalar interpolation, six data rules, explicit seams and persistent corner identities across refinement and multires commits.
- Authoring meshes use polygon faces. IDs are stable dictionary keys, not dense array indices. Corner attributes are `{uv: Vector2?, normal: Vector3?, color: Color3?, alpha: number?}`. Weights map each vertex ID to a bone-ID/weight dictionary; groups map names to scalar vertex masks.
- The coordinate system is Roblox's right-handed world convention; cameras look along local negative Z. Primitive sizes are arbitrary authoring units. Angles are radians except `Camera.fov`, which is vertical degrees. All operators preserve the caller's chosen scale.
- `Mesh:validate()` detects invalid references, degenerate faces, edge nonmanifoldness, winding errors, disconnected vertex fans, duplicate faces, zero-length edges and boundaries. It does **not** certify that a mesh has no self-intersections or that it matches a photograph. Signed volume is meaningful for consistently oriented closed surfaces.
- Polygon triangulation expects simple, approximately planar faces. `Modifiers.clipPlane(..., cap=true)` requires a closed source and supports concave, disconnected and holed caps through bisect. `bevelConvex` requires a convex closed source. `Topology.bridge` needs equally sampled, correctly ordered loops. Extrusion takes a face-ID set.
- Most geometry-changing operators recalculate normals. Apply `mesh:recalculateNormals(creaseAngle)` after editing when a particular hard-edge policy is required. Explicit corner normals survive native partitioning and texture tiling.
- `Boolean` offers polygon BSP and audited winding-region arrangement methods. Both preserve typed channels, corner data, materials, weights and groups. Arrangement supports nested/intersecting source sheets, independently classified operands and mandatory final geometric audits. BSP expects valid closed oriented inputs and offers optional intersection checks. Near-degenerate construction can reject. See [BOOLEANS.md](BOOLEANS.md) for completion, precision and budget contracts.
- `Adaptive.refine` splits selected long edges without moving existing vertices. `Adaptive.remesh` also collapses short edges, improves valence and relaxes/projects vertices. All typed domains and skin/groups follow local correspondence; boundaries, intrinsic/typed data seams and sharp edges are protected by default. It does not certify freedom from self-intersection. `Remesh.quads` provides separate feature-guided quad construction, sampled density and shape targets, whole-surface bounds and endpoint intersection audits; see [RETOPOLOGY.md](RETOPOLOGY.md).
- Voxel remeshing and booleans are resolution-dependent approximations with source-data projection enabled by default; `transfer=false` requests geometry alone. Reports distinguish geometry validation, projection completion and unmatched samples. Bounds are padded for mesh sources; explicit analytic-field bounds can produce an open isosurface. `maxCells` defaults to 250,000 and `maxSourceTriangleSamples` to 10,000,000. See [DATA_TRANSFER.md](DATA_TRANSFER.md) for nearest-chart semantics, masks, budgets and precision limits.
- Simplification can stop before its requested face count to preserve topology, features, symmetry or a deviation limit. Inspect `complete` and `reason`. Decimation uses fixed-reference quadric scores with segment placement, typed data transfer, endpoint intersection audits and a separately certified surface-distance bound; see [SIMPLIFICATION.md](SIMPLIFICATION.md).
- Multiresolution edits must keep level topology and IDs fixed. `select(level)` and `get()` return copies; submit changes with `commit(mesh)`. Details propagate upward, not downward. After a coarse edit, fine displacements are transported through local surface frames.
- Harmonic and LSCM unwrap require disk charts: one boundary loop per connected chart. Supply seams via `Unwrap.unwrap(mesh, seamEdgeSet)`; edge keys are `"smallerId:largerId"`. `Unwrap.sharpSeams` is useful for boxes and hard-surface forms. `Unwrap.autoSeams` constructs geometry-guided disk cuts for closed or holed surfaces, with explicit feature barriers and chart-size/normal-cone controls; inspect the resulting unwrap quality. Use `{method="lscm"}` for conformal charts or `Conformal.lscm(mesh, options)` for explicit boundary pins. Inspect convergence and distortion reports. The harmonic/LSCM unwrap call packs a regular grid; use `UV.equalizeDensity` or `UV.packIslands` for whole-island density and atlas control. `Unwrap.angleBased(mesh, options)` optimizes a single disk chart with two optional boundary pins; `{method="angle"}` on `Unwrap.unwrap` optimizes cut charts, rectangle-packs them and audits the final native atlas transactionally. `UV.relax` improves existing islands with angular or symmetric-Dirichlet energy, boundary/corner pins and partial selections; native orientation and optional global overlaps are checked. See [UV_MODELING.md](UV_MODELING.md) for convergence, overlap and packing contracts.
- Texture data is linear floating-point RGBA. UV/image origin is upper-left. Encode color maps as sRGB; normal, roughness and metalness maps stay linear. `Roblox.material` handles this distinction. Normal maps use tangent-space RGB with +Z outward. Baking is nearest-surface transfer, not a production cage-baking workflow.
- `Texture:sample(uv, wrap?, wrapV?)` uses texel centers `(x+0.5)/width, (y+0.5)/height`; UV 0 and 1 are image boundaries. The default clamps to edge texels. `wrap=true` repeats with bilinear interpolation across tile edges; optional `wrapV` overrides vertical addressing independently. Coordinates must be finite. `resize` uses this convention and returns an independent, byte-exact copy at unchanged dimensions. Downsampling is bilinear, without an area/antialias filter.
- Stored RGB is straight alpha. `paint` and `blend` use source-over compositing, retain hidden destination RGB when the source contributes nothing, and preserve small nonzero alpha. Sampling and blur interpolate RGBA channels independently so they also operate on data maps; premultiply/unpremultiply explicitly when alpha-aware color filtering is needed. A corrected sampler can change material or projection results that previously depended on the old endpoint-center convention.
- `Roblox.toTexturedModel` expects UVs inside `[0,1]` and PBR images with matching dimensions. It clips geometry and creates new tile material slots; original material slot assignments are replaced. It interpolates native weights and corner normals along the cut. Tiled parts use **Box** collision by default because flat UV pieces can fail Roblox convex hull generation; set collision fidelity explicitly when needed.
- Native meshes are partitioned by material and triangle budget (18,000 by default). A handle retains native objects and source-ID mappings. With `options.rig`, `createPart` also constructs the named Bone hierarchy; use `Roblox.applyPose(handle, localPose)` to drive native Bone transforms. `Roblox.update` permits position/corner changes only; it rejects topology changes. Changing native skin weights requires rebuilding the handle. `refreshCollision` explicitly refreshes collision geometry.
- `Roblox.fromEditable` returns `(mesh, sourceToAuthoringVertexMap, rig)` in the editable object's local coordinates. Native bone weights can be quantized; imported weights are normalized. Ordinary bones/weights are supported; FACS poses, virtual-bone semantics and full avatar setup are not yet preserved by this adapter.
- Cloth bending uses opposite-vertex distance springs and field collisions; it has no self-collision. `RigidBody` supports spheres and scalar-field colliders. `Dynamics` adds convex polyhedron contacts, angular inertia and friction through SAT and discrete sequential impulses; it has no CCD, joints or concave-body decomposition. SPH uses all-pairs neighbors and explicit integration: use small timesteps and a suitable density/particle spacing. These are usable numerical building blocks, not production solver parity.
- `PathTrace` retains its simple diffuse/ideal-metal/dielectric implementation. The additional `Integrator` uses GGX BSDFs, direct-light importance sampling and MIS for CPU previews. It has no denoiser, GPU backend or participating media; see `SHADING.md` for its transport model and limitations. Use small previews and explicit sample budgets.
- `GLTF` operates on caller-supplied bytes and never fetches URIs. It preserves supported geometry, hierarchy, materials, encoded image bytes and skin data. TRS/weight animations and core morph attributes are supported. Compression and required extensions reject explicitly. Optional extensions warn and are not fully lossless. See `GLTF.md`.
- Native editable allocation and asset creation require the relevant Roblox API access. Studio authoring and game-runtime permissions differ. `Roblox.publish` calls `CreateAssetAsync` only when explicitly invoked; it does not happen on require or when creating a mesh. Failed uploads return a failure report with any IDs already created. Published assets are independently reloaded and compared before replacing scene references. Commit failures attempt reverse rollback and report rollback/cleanup errors. Reuse a caller-owned resume ledger to avoid repeating known successful uploads. Source meshes and native authoring objects remain available. See [PRODUCTION.md](PRODUCTION.md) for exact verification, retry and failure contracts.

## Recovery and publishing

Keep the authoring source, not just a live native object:

```lua
local json = E.IO.encode(mesh)
local restored = E.IO.decode(json)
local objText = E.IO.toOBJ(mesh)

-- Run only in a context permitted to publish assets:
local report = E.Roblox.publish(bundle, {
    Name = "Authored Mesh",
    CreatorId = YOUR_USER_ID,
    CreatorType = Enum.AssetCreatorType.User,
})
assert(report.success, report.error)
```

The package's `.rbxmx` contains source scripts, not ephemeral editable references. Copying it to another place is sufficient to reuse the APIs. JSON/OBJ functions read or return strings; they never fetch models from the internet.

## Tests and examples

The regression suite (about 1,850 tests in 104 suites) runs headless outside Studio, apart from 68 tests that need native `EditableMesh`/asset APIs and one that depends on engine value semantics; those run in Studio. CI runs the fast tier (88 suites) on every push and the full suite weekly, on version tags and on demand; `python3 tools/validate.py` runs all of it locally. Local CI instructions are in [MAINTAINING.md](MAINTAINING.md).

To run everything in Studio, including the native tests, use the development profile. Insert that artifact as `ServerStorage.Editable3DDevelopment`; the live production profile omits tests and examples.

```lua
local root = game.ServerStorage.Editable3DDevelopment
local E = require(root)
local report = require(root.RunAllTests)(E) -- all suites and native adapter tests included
assert(report.success, game:GetService("HttpService"):JSONEncode(report))
local benchmarks = require(root.Benchmarks)(E)

-- Nothing runs automatically. These are callable ModuleScripts:
local bundle = require(root.Examples.SculptAndMaterial)(workspace)
local clothMesh, state = require(root.Examples.Cloth)()
local assembly, graph = require(root.Examples.ProceduralAssembly)()
local camera, fit = require(root.Examples.ReferenceFit)()
local tiled = require(root.Examples.TiledMaterial)(workspace)
local geometry = require(root.Examples.SurfaceAuthoring)()
local roundtrip = require(root.Examples.GLTFRoundtrip)(E)
local hdr, display, renderReport = require(root.Examples.PBRPreview)({width=48, height=24, samples=8})
local motion = require(root.Examples.AnimatedMorph)(E)
local dynamics = require(root.Examples.ConvexStack)()
local constrained = require(root.Examples.ConstrainedRig)(E)
local surfaceControl = require(root.Examples.SurfaceControl)(E)
local rotationEdit = require(root.Examples.RotationPreservingEdit)(E)
local rationalSurface = require(root.Examples.RationalSurface)(E)
local fittedSurface = require(root.Examples.FittedSurface)(E)
local creased = require(root.Examples.CreasedModel)(E)
local regions = require(root.Examples.MeshRegions)(E)
local curveStudy = require(root.Examples.BezierDistanceStudy)(E)
local panel = require(root.Examples.ModeledPanel)(E)
local section = require(root.Examples.CutVessel)(E)
local tensorContacts = require(root.Examples.TensorPlaneContacts)(E)
local shading = require(root.Examples.WeightedNormals)(E)
local housing = require(root.Examples.BeveledHousing)(E)
local cutPanel = require(root.Examples.KnifePanel)(E)
local trimmedShell = require(root.Examples.TrimmedShell)(E)
local audited = require(root.Examples.IntersectionAudit)(E)
local repaired = require(root.Examples.RepairedSolid)(E)
local cut = require(root.Examples.BooleanChannels)(E)
local projected = require(root.Examples.ProjectedRemesh)(E)
local duct = require(root.Examples.CurvedDuct)(E)
local editedSurface = require(root.Examples.EditedPeriodicSurface)(E)
local channel = require(root.Examples.MiterChannel)(E)
local controlPanel = require(root.Examples.ControlNetPanel)(E)
local rationalFit = require(root.Examples.RationalFitStudy)(E)
local uvPanel = require(root.Examples.SmoothUVPanel)(E)
```

Tests cover geometric invariants, manifoldness, exact handle interpolation, mask protection, native attribute/weight conversion, placement, pixel round-trips, texture tiling, solver constraints, graph cycles, camera residuals and deterministic results. They are not a proof of arbitrary-input robustness. `dist/verification.json` records the actual Studio run and package verification. Performance measurements are machine-specific authoring benchmarks.

Static analysis uses Roblox globals declared in `.luaurc`; the standalone CLI's `UnknownType` lint is disabled because it does not load Roblox's engine type definitions. This is not a claim of strict static typing. StyLua formatting is AST-verified.

See [INTERSECTION_REPAIR.md](INTERSECTION_REPAIR.md) for intersection cuts and repair; [BOOLEANS.md](BOOLEANS.md) covers both Boolean methods, winding rules, typed-channel correspondence and unresolved output contracts.

## Remaining Blender parity

Unrestricted tolerance regularization for degenerate intersections, globally optimal quad layouts, optimal atlas packing, a complete Geometry Nodes catalog, the complete constraint/animation system, concave rigid-body contacts, continuous collision detection and physics joints, cloth self-collision, production fluid/volume solvers, FBX/USD, complete glTF extension support, video compositing, and Cycles/Eevee parity remain outside this version. They are documented omissions; there are no success-returning placeholder implementations for them.

## References and implementation provenance

All library code was authored for this package. No downloaded model data or Blender source code was incorporated. Algorithm and engine references:

- [Blender BMesh API](https://docs.blender.org/api/5.0/bmesh.html) — topology concepts and separation from editor UI.
- [Roblox EditableMesh](https://create.roblox.com/docs/reference/engine/classes/EditableMesh) and [EditableImage](https://create.roblox.com/docs/reference/engine/classes/EditableImage) — native adapters.
- [Roblox AssetService](https://create.roblox.com/docs/reference/engine/classes/AssetService/CreateEditableMesh) — native creation and asset persistence.
- [XPBD paper](https://matthias-research.github.io/pages/publications/XPBD.pdf) — compliant position constraints.
- [Particle-Based Fluid Simulation for Interactive Applications](https://matthias-research.github.io/pages/publications/sca03.pdf) — SPH density, pressure and viscosity kernels.
