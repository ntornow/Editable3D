# Deformation workflows and surface controls

## Local frames, masks and reports

`Deform.simple`, `shear`, `cast`, `warp`, `taperProfile`, `curve` and `masked` return `mesh, report`, own a fresh mesh, retain vertex/face IDs and polygon connectivity, and preserve typed channels on all four domains, materials, intrinsic UVs, groups and skin weights. The source remains unchanged on success, cancellation or error. Existing `Deform.twist`, `bend`, `taper` and other earlier entry points retain their earlier signatures and contracts; `masked` composes them with the common options.

These functions share an `options` table. `frame=CFrame.identity` converts source positions into local deformation coordinates; results return to the original mesh space. Axes use uppercase `X`, `Y`, `Z`. The transverse `(u,v)` bases are `(Y,Z)` for X, `(Z,X)` for Y and `(X,Y)` for Z, so `u × v` points along the axis. `lockAxes={X=true}` restores selected local components after deformation.

`strength=1` is a finite signed scalar; values outside [0,1] extrapolate. The per-vertex influence is the product of `mask`, `group` and `attribute`, followed by optional `invertMask`, then multiplied by `maskField(worldPosition, vertexId)` and strength. Here “world” means the mesh's original coordinate space, not an automatically applied Model transform. `mask` is a dictionary keyed by existing vertex IDs; omitted entries are zero. `group` names an existing vertex group. `attribute` names an existing number/boolean vertex channel, including its sparse default. Mask numbers must be in [0,1]; booleans map to zero/one. Omitted mask sources contribute one. Inversion applies to the combined dictionary/group/channel value before the field, even when none of those three is supplied. `maskField` is evaluated for every source vertex during preparation. Zero final influence skips the deformation/profile callback and preserves that vertex's original position.

`recalculateNormals=false` retains original corner normals; otherwise normals are recalculated with optional `normalAngle`. Other stored directions, such as custom vectors and tangent channels, are preserved as data rather than automatically transformed; regenerate them when needed. Defaults are `maxVertices=200000` and `maxWork=2000000`. Work charges vertex preparation, deformation and explicit profile/frame/query operations. `cancelled()` and `checkpoint({stage,work,vertices,modifiedVertices})` run at entry, finish, and periodically during work. Throwing cancels; callbacks may yield. Limits do not bound time spent inside a user callback or mesh validation/normal recomputation.

Reports contain `complete`, `validation`, `vertices`, `modifiedVertices`, `maskedVertices` (zero final influence), `maximumDisplacement` and `work`. Invalid source geometry, nonfinite values, missing masks, numerical nonconvergence and exhausted budgets reject. A collapsed output rejects unless `allowInvalid=true`, which returns it with `complete=false`. `complete` checks the mesh validator's local topology/geometry rules; it does not certify absence of global intersections, folds, negative volume, excessive distortion or collisions. Extreme factors, signed scales and large absolute coordinates need caller review.

## Composing older operations with masks

```luau
local result, report = E.Deform.masked(mesh, function(localMesh)
    return E.Deform.lattice(localMesh, lo, hi, displacementControls)
end, {
    group = "editable",
    attribute = "deformation_weight",
    maskField = function(position, id) return 0.5 end,
    strength = 0.8,
    lockAxes = { X = true },
})
```

`Deform.masked(mesh, operation, options?)` supplies the shared dictionary/group/channel/field masks, signed strength, local frame, axis locks, validation and reports to an existing topology-preserving operation or callback pipeline. It covers the original twist/taper/bend, lattice, shrinkwrap, contact and RBF entry points, surface-attachment evaluation, sculpt operations and custom positional edits. The earlier APIs retain their signatures and formulas. A callback can compose several operations before its final positions are blended.

The source and options are copied. `operation(localMesh)` receives an independent mesh whose vertex positions and recalculated geometric normals are expressed in `options.frame` coordinates. Other source channels, groups and weights are copied as data; arbitrary stored vector channels are not automatically transformed. The operation returns an authoring mesh and optionally a report table. Its vertex IDs, face IDs and ordered face connectivity must match the source exactly. Topology builders, reordered polygons and transforms that reverse winding reject. Every returned position must be finite, including positions with zero final influence whenever the operation runs.

If any vertex has nonzero combined influence, the operation runs once on the whole local mesh. This allows lattice, neighbor smoothing and attachment algorithms to see their full original neighborhood. The wrapper then blends each original local position toward its returned position by the combined influence, applies local axis locks, and restores the output frame. If every influence is zero, it skips the operation entirely. `maskField` still runs during preparation, as it does for other common deformation APIs.

Only positions are taken from the operation result. Output connectivity, typed channels, intrinsic UV/color data, material slots, groups and skin weights come from the original source. Callback edits to those fields are isolated and discarded. Normal retention/recalculation follows the outer options. A geometrically collapsed full candidate can still be useful at partial influence; the final blended geometry receives the common validator. `allowInvalid=true` can return a geometrically invalid blend with `complete=false`.

An optional operation report with `complete=false` or `success=false` always rejects, including with `allowInvalid=true`; a failed numerical operation is not silently treated as a successful candidate. Accepted reports appear in `report.operationReport`. `report.operatorInvoked` records whether the callback ran. Other report fields retain the common definitions above. Callback exceptions, malformed outputs and cancelled work leave the caller's source unchanged.

The common work budget charges preparation, result-position/connectivity checks and final blending. It does not bound code inside `operation`, source cloning, validation or normal recomputation. Pass suitable budgets/cancellation options into operations that perform their own expensive solves. The outer `checkpoint` also receives `stage="operator"` before the callback; entry/periodic/finish cancellation behavior remains unchanged.

Nineteen tests cover analytic legacy formulas, combined masks and sparse defaults, local frames and locks, attachment and smoothing, callback/source/options isolation, all data domains, topology rejection, incomplete reports, native precision, invalid output, budgets/cancellation and native normals/UVs. `Examples.MaskedLattice` applies a typed radial influence field to the original lattice deformation.

## Simple deformation and shear

```lua
local bent, report = E.Deform.simple(mesh, "bend", math.pi / 2, {
    axis = "X", radialAxis = "Y", range = Vector2.new(0, 4), pivot = 0,
})
local sheared = E.Deform.shear(mesh, 0.25, {axis="X", direction="Y"})
```

`simple(mesh, mode, amount, options)` supports `twist`, `bend`, `taper`, `stretch`. Its default axis is Y. `range=Vector2(lo,hi)` must increase; otherwise the local source extent is used and must be nonzero. `pivot=0` is a local longitudinal coordinate. Let `h=hi-lo`, `s=clamp(p.axis,lo,hi)-pivot`. The full-influence transforms are:

- Twist: rotate transverse `(u,v)` right-handed by `amount*s/h` radians.
- Taper: multiply both transverse coordinates by `1+amount*s/h`.
- Stretch: multiply transverse coordinates by `1-amount+4*amount*(s/h)^2`; map the axis to `pivot+(p.axis-pivot)*(1+amount)`. This is the package's parabolic stretch convention; it does not guarantee volume preservation.
- Bend: let `k=amount/h`, `a=k*s`, `r=p.radialAxis`, and `d=p.axis-clamp(p.axis,lo,hi)`. Set radial coordinate to `r*cos(a)+(cos(a)-1)/k-d*sin(a)` and axis coordinate to `pivot+sin(a)/k+r*sin(a)+d*cos(a)`. The remaining coordinate is unchanged. Zero amount is exactly identity; a stable half-angle expression computes `cos(a)-1`. Outside the range, the centerline extends along the endpoint tangent. `radialAxis` defaults to X, or Y when the longitudinal axis is X, and must differ from it.

Each result linearly blends the original and full transform by the combined influence. Twist and taper clamp their transform amount outside the range; stretch clamps its transverse factor but continues its axial scaling. The formulas and pivot are explicit package conventions, not a claim of Blender's exact modifier evaluation.

`shear(mesh, factor, options)` adds `factor*(p.direction-pivot)` to `p.axis`, blended by influence. The target axis defaults to X; the driver defaults to Y (Z when the target is Y). They must differ. Optional `range` clamps the driver coordinate. A uniform, unrestricted shear preserves volume analytically; spatially varying masks and limits do not have that guarantee.

## Casts and frame warp

`cast(mesh, "sphere"|"cylinder"|"cuboid", options)` projects rays from the local origin onto an analytic shape. `size=1` is a positive radius/half-extent, or a positive Vector3 for ellipsoids, elliptical cylinders and boxes. For scaled coordinates `q=p/size`, sphere/cylinder divide the affected original components by `|q|`; cylinder first zeros its longitudinal scaled component and retains the original longitudinal coordinate. Cuboid uses `max(abs(q.X),abs(q.Y),abs(q.Z))`. Cylinder `axis` defaults to Y. `axes={X=true,Z=true}` restricts the components written; omitted `axes` enables all eligible components. Restrictions can prevent the final point from lying on the full shape. The origin and cylinder centerline remain unchanged and increment `singularVertices`.

`radius=0` means unlimited influence. A positive radius excludes vertices farther from the local origin, counted in `radiusExcluded`; points exactly on that radius remain eligible. Optional `falloff` attenuates influence by distance/radius. With no falloff, the cast uses constant influence inside the radius. Size and influence radius are independent.

`warp(mesh, fromCFrame, toCFrame, options)` uses frames in the mesh's original coordinate space. At full influence it maps `from:PointToObjectSpace(p)` through `to`. By default it interpolates frame translation and quaternion rotation before mapping the point, preserving the radius of an individual point under a pure rotation at partial influence. `preserveRotation=false` linearly blends the original and fully transformed points. Spatially varying influence has no volume guarantee. `radius=0` is unlimited; a positive radius measures distance from `from.Position`, excludes points at or beyond the radius and uses `falloff="smooth"` by default.

Falloffs accept a function of normalized distance returning a mask in [0,1], or one of: `constant` (1), `linear` (1-t), `smooth` (cubic smoothstep of 1-t), `smoother` (quintic smoothstep of 1-t), `sharp` ((1-t)²), `sharper` ((1-t)⁴), `root` (sqrt(1-t)), `sphere` (sqrt(1-t²)), `inverseSquare` (1-t²). These names have the exact formulas shown. A falloff callback runs only for influenced vertices inside the finite radius; unlimited influence does not call it.

## Taper and radius profiles

`taperProfile(mesh, profile, options)` scales transverse components without moving the longitudinal coordinate. Axis defaults to Y; `range` follows the simple-deform convention. The profile receives normalized position within that range. `outside="clamp"` is the default; `"error"` rejects influenced vertices outside it. A profile can be:

- A finite number for uniform transverse scale, or Vector2 for separate `(u,v)` scales.
- A callback of fraction returning either of those values.
- An increasing array of Vector2(fraction, scalarScale) knots, starting at 0 and ending at 1, with linear interpolation.
- A nonperiodic rational curve or Bezier descriptor used as an X/Y graph: normalized X determines position and Y supplies scalar scale. Controls must be nondecreasing in X with positive total X extent. Z is ignored. The implementation solves for X, so nonuniform rational parameters do not distort the profile's horizontal placement.

Graph inversion uses normalized `profileTolerance=1e-6` and `maxProfileIterations=48` (maximum 64). That tolerance bounds horizontal graph residual, not scale error when the graph is steep. A graph that cannot meet it rejects. Negative scales are accepted; output validation still applies. `curve` uses the same profile forms for `radiusProfile` along path distance.

## Distance-driven curve following

```lua
local path = E.Surfaces.arc(CFrame.identity, 3, 0, math.pi / 2)
local curved, report = E.Deform.curve(mesh, path, {
    axis = "X", fit = true, up = Vector3.zAxis,
    radiusProfile = {Vector2.new(0,1), Vector2.new(1,0.7)},
    roll = function(fraction) return fraction * math.pi / 4 end,
    tolerance = 0.001,
})
```

Paths can be NURBS curves, Bezier descriptors, cyclic descriptors, or arrays of Vector3 polyline points. The path is copied. `pathFrame=CFrame.identity` transforms its controls into the output mesh space independently of the source `frame`. Axis defaults to X and accepts all six signs (`X`, `-X`, etc.). With no fit, signed local axis position is physical distance along the path. `fit=true` maps the source's local axis extent onto the full path length; explicit `sourceRange=Vector2(lo,hi)` supplies that range and enables fit. Negative axes reverse it. Then `distance=distance*lengthScale+offset`, where positive `lengthScale` defaults to 1 and `offset` defaults to 0 in distance units.

Open paths default to `outside="extend"`, continuing the endpoint tangent. `"clamp"` pins the centerline to an endpoint; `"error"` rejects excess distance. Closed paths default to `"wrap"`. Wrapping requires a closed path. Cyclic descriptors and closed Bezier descriptors imply closure; `closed` can explicitly override it. Closed seams require coincident endpoints within tolerance and matching tangent directions. A zero-length path, ambiguous near-180-degree tangent reversal, or nonconverged sampling/length inversion rejects.

`up` is a nonzero direction in output mesh space, defaulting to the source frame's transverse u direction. It is projected onto the initial tangent plane. If parallel, the least-aligned canonical axis supplies a deterministic fallback, reported as `upFallback=true`. Discrete parallel transport propagates the normal along adaptive tangent samples; a query transports from its preceding sample to its exact tangent. Stationary sample derivatives use the nearest distinct forward chord, or the backward chord at an endpoint, and increment `stationarySamples`. Sharp polyline corners use this discrete orientation convention. Closed paths distribute residual frame rotation by normalized curve parameter to close the seam. This is a sampled frame construction, not a certified continuous rotation-minimizing frame solution.

With unit tangent T, transported normal N, and B=T×N, the final position is `pathPosition + T*endpointExtension + N*(p.u*radius.X) + B*(p.v*axisSign*radius.Y)`. Flipping the second transverse coordinate for a negative axis keeps orientation consistent. `roll=0`, or a callback of distance fraction, rotates N and B in radians around T. Radius and roll use the clamped/wrapped path fraction; repeated fractions share cached evaluations. Final output is blended by the common vertex influence. Curvature, thickness and radius changes can still make cross sections overlap.

Curve defaults are `tolerance=1e-4`, `maxAngle=math.rad(5)`, `maxCurveNodes=10000`, `maxCurveDepth=24`, `maxFrameSamples=8192`, `maxCurveQueries=10000`. `arcLength={...}` passes options to `ArcLength.prepare`; omitted tolerance/node/depth limits inherit the corresponding outer settings. All required samplers and inverse distance queries must converge. `report.curve` contains length and its bounds, frame sample count, sampler chord/tangent bounds, stationary/fallback counts, closure and seam twist, distinct query count and maximum inverse distance error. These bound the corresponding path queries, not total deformed geometry error or the accumulated frame orientation error. See [SPLINE_QUERIES.md](SPLINE_QUERIES.md).

`DeformWorkflowTests` checks independent analytic shear, cast, warp, bend and profile coordinates; rational distance mapping, all signed axes, seam wrapping, endpoint extension, frame covariance, masks, callbacks, transactional rejection, metadata and native mesh conversion. `Examples.CurvedDuct` combines a piecewise taper with an exact rational arc. The headless workflows address operations described by the [Blender cast modifier](https://docs.blender.org/manual/id/5.0/modeling/modifiers/deform/cast.html), [warp modifier](https://docs.blender.org/manual/nl/5.0/modeling/modifiers/deform/warp.html), and [curve geometry/taper controls](https://docs.blender.org/manual/id/5.0/modeling/curves/properties/geometry.html); the package contracts above define the implemented behavior.

Version 0.5 adds original Luau implementations for controlling detailed meshes with simpler geometry. These APIs operate on pure authoring meshes and do not create instances or upload assets.

## Surface attachment

```lua
local binding, report = E.SurfaceDeform.bind(detailedMesh, controlMesh, {
    maxDistance = 2,
    mask = vertexWeights,
})
local result, movement = binding:evaluate(posedControlMesh)
```

Binding stores each source vertex's closest triangle, barycentric coordinates, and a full residual in that triangle's orthonormal frame. Evaluation transports the residual with the triangle, retaining off-surface thickness and points beyond triangle boundaries. Both inputs use the same coordinate space. The source and target are copied/indexed at bind time; repeated evaluations always start from the original source. Changes to the control vertex IDs, face IDs or polygon connectivity require rebinding. A collapsed bound triangle rejects explicitly. Control vertex positions must remain finite.

`bind` options: `mask` (clamped vertex weights, omitted means one), `maxDistance` (unbounded by default), `maxVertices` (100,000 source vertices by default), and `checkpoint(progress)` every 256 vertices. The report distinguishes bound, distance-excluded and zero-mask vertices. Excluded vertices remain unchanged. The callback can yield or throw to cancel.

`evaluate` options: `mode="RIGID"` (default) transports tangential residuals without stretching them; `mode="AFFINE"` stretches/shears those residuals with the two triangle edges. Both preserve the signed normal distance, rather than scaling thickness. `influence` multiplies the bound weights, in [0,1]. `recalculateNormals=false` retains original corner normals, for callers managing shading separately. The default recalculates them. UV seams, material slots, weights, groups and all other corner data remain intact.

This is a nearest-triangle attachment, not Blender's multi-face falloff algorithm. Large deformation across control triangle boundaries can show derivative discontinuities. It has no self-collision handling, topology-changing remapping or volume guarantee. Use a sufficiently sampled control mesh close to the detailed surface.

## Harmonic and biharmonic displacement

```lua
local binding = E.Laplacian.bind(controlMesh, { weights = "UNIFORM" })
local posed, report = binding:solve({
    [fixedVertexId] = controlMesh.vertices[fixedVertexId],
    [handleVertexId] = desiredPosition,
}, { order = 2, maxIterations = 512 })
```

The binding constructs a symmetric sparse graph Laplacian `L`. `order=1` minimizes displacement Dirichlet energy; `order=2` (default) minimizes `||L d||²`. Anchors prescribe exact absolute positions, using stable vertex IDs. The solve eliminates anchor variables, then runs Jacobi-preconditioned conjugate gradients separately on each coordinate. Only displacement is interpolated, so unchanged source details are added back to the result. A fully unconstrained connected component, including isolated vertices, stays fixed. An empty anchor dictionary returns the unchanged mesh.

`weights="UNIFORM"` uses polygon edges. `weights="COTANGENT"` triangulates polygons and accumulates half-cotangent edge conductances. Negative/zero conductances are clamped to 1e-8; this gives a positive graph operator on obtuse meshes but differs from an unclamped finite-element Laplacian. Degenerate triangles reject. `maxVertices` defaults to 100,000. The binding owns a copy of the mesh and is reusable.

Solve options include `tolerance=1e-7` (relative residual, with a 1e-10 absolute floor), `maxIterations=512`, `checkpoint(progress)` every 16 iterations and `recalculateNormals=false`. The report gives exact-anchor count, free/inactive vertex counts, and true residual, relative residual, iteration count and convergence for every axis. By default a failed solve raises an error. Set `requireConvergence=false` only when explicitly accepting an approximate result. No silent success is reported. Cancellation or failure leaves the source intact.

This is linear displacement editing. It does not estimate local rotations or implement Blender's complete Laplacian Deform or collision prevention. Large rotations can distort details; use small photo-fitting adjustments or the `ARAP` operator below. Biharmonic conditioning worsens on dense meshes: solve a coarse control mesh and transfer through `SurfaceDeform`.

## Rotation-preserving surface editing

Version 0.6 adds a local/global edge-spoke ARAP solver and weighted point registration. Both are pure Luau and preserve the caller's source data.

```lua
local binding = E.ARAP.bind(controlMesh, {weights = "COTANGENT"})
local posed, report = binding:solve(absoluteAnchors, {
    initial = harmonicInitialMesh,
    maxIterations = 60,
    tolerance = 1e-5,
    requireConvergence = true,
})
```

`ARAP.bind` owns a copy of the mesh. `weights="UNIFORM"` (default) and `"COTANGENT"` use the positive graph conventions described above. `maxVertices` defaults to 5,000. Each local step fits a proper rotation to every vertex's rest/current edges; each global step solves the symmetric graph system with averaged endpoint rotations and exact hard anchors. The energy is half the sum over directed edge spokes of weighted squared rotation residuals. An unconstrained component remains exactly unchanged. Anchors are absolute Vector3 positions keyed by stable vertex IDs. `initial`, when supplied, must retain all vertex/face IDs and polygon connectivity. UVs, materials, skin weights and groups survive the solve.

Options: `maxIterations=30`, `tolerance=1e-5` (absolute maximum vertex step), `linearIterations=512`, `linearTolerance=1e-8` (relative PCG residual with a 1e-10 absolute floor), `checkpoint(progress)` after each outer iteration, and `recalculateNormals=false` to retain existing corner normals. The numerical solve uses a local origin to reduce world-offset cancellation. Anchors and inactive vertices are assigned from their original absolute values afterward.

The report includes `converged`, `linearConverged`, `iterations`, `maximumStep`, `energy`, `energyHistory` (initial energy plus every completed step), the last three coordinate `linearReports`, and anchor/free/inactive vertex counts. Linear nonconvergence raises unless `requireLinearConvergence=false`. Reaching the outer iteration budget returns `converged=false`; set `requireConvergence=true` to make that an error. A callback can yield or throw to cancel. Failure never changes the source mesh. Inspect both convergence flags when accepting an approximate result.

This solver minimizes a surface edge energy. It is not a volumetric solver and does not certify collision avoidance, positive volume, injectivity, a global optimum, or Blender modifier equivalence. Positive cotangent clamping changes the energy on obtuse triangles. Coarse controls plus `SurfaceDeform` are preferable to solving every vertex of a dense sculpt. Float32 Vector3 arithmetic limits attainable accuracy, especially at large absolute coordinates.

## Weighted point registration

```lua
local fit = E.Registration.fit(sourcePoints, targetPoints, {
    weights = confidenceWeights,
    scale = true,
})
local alignedPoint = fit.frame:PointToWorldSpace(sourcePoint * fit.scale)
```

Inputs are equal-length, nonempty arrays of finite Vector3 values. Optional weights must be finite and nonnegative with a finite positive sum. Weights and covariance are normalized internally so changing confidence units does not change the fitted rotation. `fit` computes weighted centroids and a proper rotation; `scale=true` also fits a positive uniform scale and rejects coincident sources or nonpositive scale. Default scale is one. It returns `frame`, `scale`, weighted `rms`, `maximumError` over positive-weight points, `rotationAmbiguous` and `totalWeight`. Zero-weight points do not affect the fit or error metrics. Reflections are never returned.

`Registration.rotation(sourceVectors, targetVectors, options)` fits vectors without centering and returns a rotation-only CFrame and an ambiguity report. Both functions accept `reference=CFrame.identity` to choose the closest reference rotation when the optimal quaternion eigenspace is ambiguous. A symmetric 4x4 quaternion eigensolve handles rank deficiency and half-turns without relying on an identity-started power iteration. There is no robust outlier rejection or correspondence search: callers provide matching points and confidence weights.

`ARAPTests` covers rigid and similarity fits, half-turns, ambiguity, reflection exclusion, exact anchors, bending-energy reduction, cancellation, sparse IDs, inactive components, explicit iteration failures and invariance under moderate world translation. `Examples.RotationPreservingEdit` bends a rippled strip from a harmonic initial guess. Algorithms follow [Sorkine and Alexa, As-Rigid-As-Possible Surface Modeling (2007)](https://igl.ethz.ch/projects/ARAP/) and [Horn, Closed-form solution of absolute orientation using unit quaternions (1987)](https://people.csail.mit.edu/bkph/papers/Absolute_Orientation_Scanned.pdf); implementation is original Luau.

## Connected planar strokes

`Curves.stroke2D(points, width, options)` returns a connected planar ribbon in XY with a +Z face normal. Points are finite Vector2 values without consecutive duplicates. Options are `closed=false`, `cap="BUTT"|"SQUARE"`, `miterLimit=4` and `material`. Closed paths omit a duplicate final point. UV U follows arc length; closed paths retain the wrap seam in corner UVs. Adjacent segments share their miter vertices, allowing `Modifiers.solidify` to make a closed solid without separate overlapping segment boxes.

Reversals and miters exceeding the limit reject instead of creating unbounded spikes. This operator does not resolve global self-intersection, narrow inner corners, or overlapping strokes in branched glyphs. Keep widths small relative to segment lengths. It is not a text/font shaping engine.

`Modifiers.solidify` now duplicates skin weights and vertex groups onto both shells and retains the source boundary face's material/corner attributes on each rim. Rim UVs inherit boundary coordinates; apply an explicit side UV layout when a separate rim texture is needed.

`Mesh:faceNormal` now centers coordinates at a face vertex before accumulating cross products. This prevents cancellation of tiny valid faces at large world offsets in Roblox's float32 Vector3 arithmetic. The regression test includes a small translated triangle near Y=140.

## Verification and provenance

`DeformationTests` checks analytic linear harmonic displacement, constant biharmonic translation, exact sparse-ID anchors, unchanged disconnected components, explicit nonconvergence, cancellation, rigid and affine surface transport, masks, distance exclusions, topology rejection, attributes, connected strokes, positive volume and solidify metadata. `Examples.SurfaceControl` transfers a coarse harmonic edit onto a detailed ripple sheet.

The surface-control use case is described in the [Blender Surface Deform manual](https://docs.blender.org/manual/id/5.0/modeling/modifiers/deform/surface_deform.html). Differential surface editing is discussed by [Sorkine et al., Laplacian Surface Editing, 2004](https://igl.ethz.ch/projects/Laplacian-mesh-processing/Laplacian-mesh-editing/). Those sources explain the broader methods; this package implements the narrower algorithms stated above. No Blender code or external model geometry is incorporated.

## View-projected relief

`Deform.envelope(mesh, view, step)` rasterizes a mesh's triangles, seen along `view.LookVector`, into a grid of frontmost depths (cell size `step` studs). View coordinates are `(x, y)` in the view plane plus depth along the look direction. It works on any tessellation, soups included.
- `envelope:sample(Vector2)` interpolates bilinearly and returns nil outside the silhouette.
- `envelope:blurred(radius)` is a Gaussian low-pass normalized over visible cells, so silhouettes don't bleed. Use it as the smooth base when replacing relief.

`Deform.relief(mesh, view, target, options)` moves the visible front layer along the view direction onto `target(point, envelopeDepth) -> depth?`. A vertex `b` studs below the envelope goes to `target + alpha * b`, so existing folds are compressed and the target imposed.

Options:
- `alpha`: default 0.2.
- `depth` and `fade`: vertices deeper than `depth` (default 2.5), fading over `fade` (default 1.5), keep their place.
- `minFacing`: vertices must face the view by at least this much (default 0.15), so sides and back stay put.
- `envelope`: pass a precomputed envelope.
- `normals = false`: keeps corner normals. Use it for meshes read back from Roblox, then `Normals.unify`.

A typical use transfers relief measured from a photograph onto a sculpt seen from the same direction: `target = smooth:sample(q) + scale * photoHighPass(q)`, where `smooth = envelope:blurred(r)` removes the sculpt's own detail below the wavelength `r`.

### Recipes

The view coordinates in `target(q, front)` are relative to the view frame: `q.Y` is height minus the view's height, and `q.X` runs along `view.RightVector`.

- **Symmetrize a scanned or photo-derived surface.** Sample the envelope at the mirrored point: `target = front + (env:sample(mirroredQ) - front) * w`. Pass `alpha = 1` so fold-unders keep their depth. Blend `w` in over a band of about 0.8 studs from the midline, and return nil where `|mirror - front|` jumps (the mirrored point fell off the other side's silhouette).
- **Band-pass sharpen.** Enhance the features without amplifying noise: `target = front + k * (env:blurred(fine):sample(q) - env:blurred(coarse):sample(q))`, for example `k = 0.5`, `fine = 0.1`, `coarse = 0.45` studs on a face about 7 studs tall.
- **Large-scale smoothing of a dense mesh.** `Sculpt.smooth` diffuses only about edge length × √iterations, so on fine meshes it barely moves features wider than a few edges. Replace the region with `blurred(r):sample(q) + keep * (front - blurred)` instead.
- **Cloth layer edges and swags traced in a photograph.** Trace the line in the photo's own pixels and pass the photo's solved `Camera` as the view to `Deform.edge` or `Deform.edgeField`. The upper layer is on the left of the polyline's direction.
  - The default `profile = "lip"` gives an overlapping hem: a rounded lip of `height` over `width` above the line, and a drop below.
  - `profile = "roll"` with `radius` R gives a rolled fold whose lower edge is the line. The surface rises in a quarter circle to `height` at R and eases back over about 1.2 R. Use it for a swag or a rolled hem that stands well proud of the cloth beneath.
  - Downward-facing estimated normals (n.y < -0.2 in the camera frame) mark hem undersides in a photo, which helps find the lines.

