# Sculpt brushes and constrained geometric fairing

`Sculpt.fair(mesh, selection, options)` returns a new mesh and a report. It solves for positions on fixed topology, with exact fixed vertices and optional world-axis locks. The source mesh, IDs, face loops, intrinsic UVs, typed attributes, skin weights, groups and materials survive unchanged. It creates no native instances. `Examples.FairPatch` demonstrates removing a bump while keeping the border and horizontal coordinates fixed.

```lua
local smooth, report = E.Sculpt.fair(mesh, selectedVertices, {
    order = 2,
    weights = "cotangent",
    pins = fixedVertices,
    lockAxes = {X = true, Y = true},
    requireComplete = true,
})
```

## Selection and constraints

The optional `selection` is a vertex dictionary of booleans or numbers equal to zero or one. Missing entries are unselected; omitting the dictionary selects all vertices. Fractional masks reject: a fairing constraint is either free or fixed. `Selection.convertDomain` can construct binary masks. Alternatively, `options.faces` is a face boolean set; a vertex is free only when **all** its incident faces are selected. Do not supply both forms.

`pins` is a vertex boolean set. Mesh boundary vertices are pinned unless `pinBoundary=false`. Default `preserveSeams=true` also protects UV, material and typed corner/face discontinuities and marked `sharp_edge`, `uv_seam` and positive `subdivision_edge_sharpness` edges. `seamAttributes` follows the shared typed seam controls. `preserveSeams=false` opts out of those data-feature constraints. Explicit pins, unselected vertices and enabled boundary constraints still apply. Loose vertices remain unchanged.

`lockAxes={X=true,Y=true,Z=true}` disables solves in those world coordinates. Each face-connected component with any free coordinate needs at least one fixed vertex. An unconstrained closed component returns unchanged with `reason="unanchoredSelection"`; no hidden anchor or centroid constraint is inserted. Empty selections, all-fixed components and all-axis locks are constrained identities.

## Discrete objective

Each connected component is translated to its minimum coordinate and normalized by its largest extent. This keeps disconnected tiny and large objects numerically independent. Faces use the existing geometric triangulation; concave faces must have simple valid projections. Nonplanar polygons use that fixed triangulated interpretation, with final polygon projection checks.

Let `K` be the symmetric stiffness matrix and `M` the diagonal mass matrix computed once from the source positions. `weights="cotangent"` (default) uses half-cotangent edge contributions and triangle-area/3 lumped masses. Negative cotangents are retained: clamping them would change finite-element affine precision. `weights="uniform"` gives each triangulation edge unit conductance and each vertex unit mass. Triangulation diagonals participate in both modes.

`order=1` minimizes the sum of coordinate energies `pᵀKp`; `order=2` (default) minimizes `pᵀKM⁻¹Kp`. The free displacement solves `Qff δ=−(QpSource)f`, with pinned displacements exactly zero. Biharmonic fairing with two fixed outer bands can preserve the discrete tangent behavior of a patch; it is not an exact continuous tangency condition. Weights are not recomputed during deformation. There is no volume constraint, rotation-invariant deformation energy, mesh-quality optimum or collision-free motion guarantee.

The matrix-free Jacobi-preconditioned conjugate-gradient solve uses `iterations=4000`, `tolerance=1e-10` and `absoluteTolerance=1e-12` by default. Zero iterations is allowed. The residual is periodically refreshed and independently recomputed on return. Each coordinate reports its actual linear residual, threshold, iterations and convergence. Ill conditioning and an insufficient iteration budget can produce explicit nonconvergence.

## Stored positions and completion

Only free coordinates are written as `originalPosition + componentExtent * solvedDisplacement`; fixed positions remain bit-for-bit identical. Checks run on the stored native Vector3 coordinates, separately from the double-precision linear solve. For each unlocked free row, acceptance requires

`abs((Q pNative)[i]) <= nativeAbsoluteTolerance + nativeTolerance * R[i] * S`.

The defaults are `nativeAbsoluteTolerance=1e-10` and `nativeTolerance=1e-6`. `S` is the maximum absolute reference or final normalized coordinate on that component and axis. Including the reference avoids a vanishing tolerance scale when a nonzero bump flattens to zero. `R` is the row sum of `abs(K)` for order one, or of `abs(K) M⁻¹ abs(K)` for order two. The latter bounds the absolute row sum of the biharmonic operator in exact arithmetic; these sums and reported backward residuals are numerical measurements, not outward interval certificates. Axis reports include `coordinateScale`, `nativeResidual`, `maximumNativeResidual`, `maximumNativeBackwardError` and `nativeConverged`. Locked axes skip this free-gradient condition.

Each component reports its source/final normalized energy and negative edge-weight count. The final energy may exceed the reference by at most `energyTolerance * max(1,abs(referenceEnergy))`, default `1e-10`. Tiny/large native coordinates are supported when the required computations remain finite and resolved; finite double solutions that overflow Vector3 reject. `maximumNativeError` measures the attempted conversion error, not a certified bound on geometric approximation.

The default geometry checks require finite oriented manifold data, positive face area, simple projected face boundaries, nondegenerate reference triangles at the final positions, and a source-to-result triangle normal change no larger than `normalLimit` (default pi/2, range zero through pi). Normal angles are numerical measurements with a small cosine comparison allowance; they are not exact orientation certificates. Fairing explicitly uses `minimumFaceArea=0` for validation and normal edits so valid small surfaces are not rejected by the general mesh validator's default `1e-12` threshold. Zero area still rejects. Native asset conversion may impose additional practical size limits.

By default, complete exact-native intersection scans must find both source and result intersection-free. `intersectionOptions` configures the bounded scans; `checkIntersections=false` explicitly skips them and sets `intersectionChecked=false`. These audits check endpoints, not the entire deformation trajectory. A geometry or collision failure rolls back the entire candidate, including otherwise successful components.

When any position changes, all intrinsic tangent/tangentSign fields are cleared. Normals are recalculated with the bounded fan-aware normal editor and optional `normalAngle`, honoring sharp-edge metadata. `recalculateNormals=false` preserves custom normals explicitly; those normals may no longer match the surface. Exact identity operations leave frames unchanged. Generic typed vector attributes do not automatically transform as directions.

`report.complete` requires successful linear solves, native residual checks and all enabled geometry/intersection gates. `applied` states whether returned positions changed. A geometrically valid finite candidate may return `complete=false, applied=true` with `reason="linearSolve"` or `"nativeResidual"`. Input intersection failures, unanchored components, nonfinite calculations, overflow, energy increases, invalid geometry and output collisions return the unchanged source snapshot. Rollback resets `modifiedVertices` and `maximumDisplacement`; attempted changes are retained as `candidateModifiedVertices` and `candidateMaximumDisplacement`. `requireComplete=true` throws for every incomplete result. Malformed inputs, hard limits and cancellation always throw.

## Budgets and composition

Defaults are `maxVertices=20000`, `maxFaces=40000`, `maxCorners=200000`, `maxTriangles=40000`, `maxFaceVertices=2000` and `maxWork=50000000`. Triangulation, operator applications, solve reductions, normal updates and both intersection audits share the counted work allowance. Indexing, copies and validation remain bounded by input/allocation limits; work units are not a wall-clock deadline. Source/options/selections are snapshotted before callbacks. Root `cancelled()` and nested intersection cancellation are honored; `checkpoint({stage,work})` can yield or throw. Soft scan limits such as `intersectionOptions.maxTests` can return incomplete scans; hard work limits may throw.

Fairing can edit a coarse level of `Subdivision.multires`; committing that coarse edit transports the stored fine residuals through the existing local frames. This preserves the package's residual-detail representation on fixed topology, not arbitrary world-space detail after remeshing. Basic weighted brushes and curve-distance fields remain available in `Sculpt` and `Stroke`; ordered dabs and symmetry are described below.

Twenty-eight tests cover eight independent NumPy dense solves, analytic harmonic and biharmonic patches, obtuse finite-element precision, pins/selections/seams/locks, source-data snapshots, partial and native-precision failures, collision/normal rollback, cancellation and budgets, disparate scales, large translations, sparse IDs, a larger patch, native overflow, multires detail transport and native EditableMesh conversion. NumPy is only used by the optional fixture regeneration script; the runtime is self-contained Luau.

The [Blender fairing description](https://docs.blender.org/manual/ja/5.0/sculpt_paint/sculpting/editing/sculpt.html) supplies the modeling comparison, and [Desbrun et al., Implicit Fairing](https://www.multires.caltech.edu/pubs/ImplicitFairing.pdf) describes related discrete geometry ideas. This implementation is a fixed-reference constrained energy solve, with no claim to implement that paper's implicit diffusion or volume-preservation method. No external implementation code is included.

## Ordered brush strokes

`Sculpt.brush(mesh, center, options)` applies one dab. `Sculpt.stroke(mesh, samples, options)` applies a dense array of records with finite Vector3 `position`, optional `pressure` in `[0,1]` (default one), optional nonzero Vector3 `normal`, and optional Vector3 `delta`. Global `options.normal` and `options.delta` provide record defaults. `brush` also accepts `options.pressure`. Both APIs return a new mesh and a report without creating native objects. `Examples.SymmetricStroke` draws a pressure-varying mirrored ridge on a UV panel.

```lua
local sculpted, report = E.Sculpt.stroke(mesh, {
    {position=Vector3.new(0.6,0,-1), pressure=0.25},
    {position=Vector3.new(0.8,0, 0), pressure=1},
    {position=Vector3.new(0.6,0, 1), pressure=0.25},
}, {
    brush="draw", normal=Vector3.yAxis,
    radius=0.6, spacing=0.3, strength=0.15,
    falloff="smoother", pinBoundary=true,
    symmetry={mirror={X=true}},
    adjustStrengthForSpacing=true,
    requireComplete=true,
})
```

Default `sampling="spaced"` measures cumulative three-dimensional distance along the input polyline and emits dabs every `radius * spacing`, starting at zero. Base `radius` defaults to one and `spacing` to 0.2; both must be finite and positive. The spacing radius is fixed, independent of pressure. Pressure and delta interpolate linearly at sampled distances. Normal vectors interpolate linearly and are renormalized; missing/inconsistent or cancelling directions reject when interpolation needs them. The final endpoint is included unless `includeEnd=false`. A near-duplicate endpoint caused only by numerical length/step roundoff replaces the previous endpoint dab. Inserting points on the same represented straight segment with consistent interpolated records retains the sampling grid, up to floating-point length accumulation.

`sampling="dabs"` applies every supplied event directly, including repeated stationary events. A zero-length spaced path emits one initial dab. A stroke requires at least one sample. `Sculpt.brush` always uses one explicit dab regardless of a supplied sampling setting. The APIs consume geometric records; they do not infer mouse motion, screen picking, time-based airbrush flow or pressure from hardware.

## Falloff and local brush fields

Each dab measures influence against the working positions before that dab. `shape="sphere"` (default) uses full 3D distance. `shape="projected"` uses distance perpendicular to the sample normal, making an infinite cylinder along that direction. It is an orthographic geometric influence shape, without perspective camera projection or occlusion. Vertices at or beyond the effective radius are excluded, including for constant/custom falloffs.

`falloff` defaults to `smooth`. For normalized radius `t`, the named formulas are: `constant=1`, `linear=1-t`, `smooth=3x²-2x³` with `x=1-t`, `smoother=6x⁵-15x⁴+10x³`, `sharp=(1-t)²`, `sharper=(1-t)⁴`, `root=sqrt(1-t)`, `sphere=sqrt(1-t²)`, and `inverseSquare=1-t²`. A custom callback receives `t` and must return a finite weight in `[0,1]`. It runs only for eligible vertices strictly inside the influence radius. The smoother/sharper formulas also work in the shared deformation falloff options.

`pressureSize=true` multiplies the radius by pressure; the default leaves radius fixed. `pressureStrength=true` (default) multiplies strength by pressure; setting it false disables that attenuation. Enabling both therefore affects both radius and displacement. Zero effective radius or strength skips the dab. `strength` defaults to 0.1 and can be signed except for flatten/smooth, which require `[0,1]`.

Let `R` be effective radius, `s` pressure-adjusted strength, `n` the normalized sample direction, `h=dot(p-center,n)`, and `lateral=(p-center)-n*h`. Before masks/falloff, the fields are:

| `brush` | Displacement for one ordinary dab |
| --- | --- |
| `draw` (default) | `n * R * s` |
| `inflate` | Current geometric area-weighted vertex normal times `R * s` |
| `move` | The sample's explicit `delta * s`; path movement is not inferred as displacement |
| `flatten` | `-n * h * s` |
| `pinch` | `-lateral * s`; negative strength magnifies |
| `crease` | `(-n * R - lateral * pinch) * s`, with `pinch=0.5` by default |
| `smooth` | Uniform topological neighbor-average displacement times `s` |

Draw, flatten, pinch, crease, projected influence and `frontFace=true` require explicit sample/global normals. Inflation computes normals from current geometry; an influenced vertex with a missing or cancelling geometric normal rejects. Smooth uses one simultaneous neighbor pass per dab and may shrink the surface. Fairing is the separate constrained energy solver described above.

Optional `adjustStrengthForSpacing=true` assigns each spaced dab the arc-length cell between adjacent sample midpoints, clipped to the complete input path. Exposure is that cell length divided by base radius. Draw/inflate/move/pinch/crease fields scale by exposure. Flatten/smooth use `1-(1-s)^exposure` to retain a bounded blend. With fixed constant influence, the accumulated draw dose is consequently proportional to path length rather than dab count. General spatially varying strokes still have sampling and native-rounding error. A stationary single dab retains unit exposure. This option requires spaced sampling; with it disabled, each ordinary dab retains unit exposure.

## Symmetry and constraints

`symmetry.mirror` is an X/Y/Z boolean set. `symmetry.radial={axis="Z",count=4}` repeats the dab around one specified axis; default count is one. `symmetry.frame` supplies an orthonormal CFrame for those local axes and origin. Mirror signs apply first, then the radial rotation. `symmetry.tileOffsets` is an explicit finite array of offsets in that frame; omitted means one zero offset. A supplied array determines all tiles and need not contain zero. Exact duplicate transforms/offsets are removed; cardinal rotations use exact zero/unit coefficients. Symmetry moves the dab positions, normals and deltas, without requiring mirrored vertex correspondences.

All symmetry copies of a dab evaluate the **same** working geometry before simultaneous writes. Default `feather=true` multiplies their summed weighted displacements by `maximumFalloffWeight / sumFalloffWeights`. Thus overlapping identical effects retain the strongest single-copy amplitude. Differing vector directions blend and can cancel on symmetry planes. `feather=false` adds their contributions. Distinct successive dabs still accumulate normally.

`mask` is a vertex boolean/`[0,1]` dictionary; omitted means one, absent dictionary entries mean zero. `group`, a scalar vertex `attribute`, and callback `maskField(originalPosition,id)` multiply that weight. `pins` fixes explicit vertices. `pinBoundary=true` protects open borders; `preserveSeams=true` enables the shared UV/material/typed-seam protections described for fairing. Both protections are opt-in for brushes. `lockAxes` locks world X/Y/Z displacement components exactly. `frontFace=true` excludes vertices whose current geometric normal has nonpositive dot product with the dab normal; this is directional filtering, not visibility testing.

## Detail, validation and limits

Optional `detailBase` is a same-ID, same-ordered-topology mesh supplying working positions. Influence, normals and neighbor motion are evaluated on that base. The final base displacement is added to the source positions, preserving the original source-minus-base residual vectors in world coordinates up to native rounding. It does not rotate those residual vectors. For rotating coarse-to-fine detail transport, apply the stroke to a coarse `Subdivision.multires` level and commit it, as verified by the tests. Neither mechanism transports arbitrary detail through topology changes.

All source data domains, material IDs, face loops and vertex IDs remain intact. Changed geometry clears intrinsic tangent/tangentSign values and recalculates normals by default; `normalAngle` controls smoothing fans and `recalculateNormals=false` explicitly retains custom normals. Exact identity edits retain their original frames and revision. Masks, samples, source/base positions and nested options are snapshotted before callbacks.

Strokes share the fairing endpoint geometry/intersection/normal audits: finite oriented manifold inputs, positive areas, simple projected polygons, final nondegenerate reference triangles, numerical `normalLimit` (default pi/2), and complete intersection-free input/output scans by default. `checkIntersections=false` explicitly skips those scans. Audits apply to the initial and final source surface; they do not certify the entire motion or every intermediate dab state. Invalid geometry, incomplete scans, collision or native overflow returns the unchanged snapshot with `complete=false` and a reason. `requireComplete=true` throws instead. Malformed schemas, allocation/work limits and cancellation always throw.

Reports include `complete`, `applied`, `brush`, `shape`, sampling counts/length/spacing, deduplicated `symmetryCopies`, `dabsApplied` (processed nonzero-strength/radius dabs, including fully masked ones), attempted `vertexWrites`, final `modifiedVertices`, maximum displacement/native-conversion error, `detailPreserved`, geometry and optional intersection reports. Rollback zeroes final modification measurements and retains attempted measurements as candidate fields. Native conversion error is measured, not an outward geometric certificate.

Mesh and shared-work defaults match fairing. Additional limits are `maxSamples=10000`, `maxDabs=10000`, and `maxCopies=256`; the raw mirror/radial/tile product must fit before duplicate removal. Dabs scan the bounded vertex set, so work can grow with vertices times dabs times symmetry copies. `cancelled()` and `checkpoint({stage,work})` participate throughout preparation, integration and audits. Input allocation bounds cover copies/indexing; work units are not elapsed-time guarantees.

Twenty-eight brush cases check independent field/falloff formulas, pressure and spacing dose, mirrored/radial/tiled transforms, masks/pins/locks, projected and front-facing sheets, same-topology and multires detail, immutable snapshots/all data domains, sparse IDs/extreme scales/translations, geometric/collision/native failures, limits/cancellation and native export. The [Blender stroke](https://docs.blender.org/manual/id/5.0/sculpt_paint/brush/stroke.html), [falloff](https://docs.blender.org/manual/nl/5.0/sculpt_paint/brush/falloff.html) and [symmetry](https://docs.blender.org/manual/th/5.0/sculpt_paint/sculpting/tool_settings/symmetry.html) descriptions provide the comparison vocabulary. These are the package's documented field and sampling formulas, without a claim of bit-for-bit Blender stroke behavior.
