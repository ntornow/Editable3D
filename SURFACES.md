# Surface construction

`E.Surfaces` constructs editable NURBS descriptors from original mathematical geometry. No scene instances, downloads or asset publishing occur. Exact constructions preserve the stated shapes up to floating-point precision; this is not an exact-arithmetic CAD kernel.

## Profiles and compatible sections

`arc(frame,radius,startAngle,endAngle)` constructs a positive-weight rational quadratic arc in the frame's XY plane. Angles are radians, radius is positive, and the signed sweep is nonzero and at most one turn. Each span sweeps at most 90 degrees. Normalized spline parameter advances monotonically around the arc but is not linear in angle. A complete turn has a duplicated endpoint with an exact shared position, ready for deliberate mesh seam closure.

`compatible(curves,options)` clamps each curve's active domain, elevates to the maximum input degree, normalizes domains to [0,1], normalizes each section's maximum weight to one, and inserts the union of interior knots and multiplicities. Every returned curve has the same degree and knot vector; geometry and normalized parameter correspondence are preserved. The result may contain redundant controls and repeated knots. Near-equal knots are not silently merged. Section orientation and seam alignment are caller choices; use `NURBS.reverse` or `Cyclic.rotateSeam` before construction.

The default limits are 128 sections and 10,000 total compatible controls (`maxSections`, `maxControls`). `checkpoint(progress)` runs after each section. Operators validate inputs and allocate independent arrays; cancellation leaves original sections intact.

## Extrusion, rulings and lofts

`extrude(curve,displacement)` returns S(u,v)=curve(u)+v*displacement. The displacement must be finite and nonzero. U retains the profile's parameterization; V is linear displacement. It creates an open sheet without end caps.

`ruled(first,second,options)` first makes the sections compatible, then connects corresponding controls with a degree-one V direction. It exactly interpolates both boundary curves and stays on the straight ruling joining corresponding boundary positions. For different rational denominators, V advances along that ruling rationally rather than linearly in Euclidean distance. Constant scaling of an input's weights does not alter construction, because compatibility normalizes each section.

`loft(sections,degree=minimum(3,sectionCount-1),options)` interpolates every section using a homogeneous B-spline solve along V. U follows the common section basis. `parameters` may specify strictly increasing values spanning [0,1]; otherwise section indices are uniformly spaced. The V knot vector uses averaged interpolation parameters. A single Givens QR solve handles all four homogeneous components of every U control, with a local origin to reduce world-offset cancellation. It returns `(surface,report)` containing the solver rank, diagonal ratio, method and copied parameters.

Interpolation can require nonpositive control weights. Such a loft throws; it does not silently change the section curves. A degree-one loft always uses the positive section weights and is a useful alternative when a higher-degree interpolation is unsuitable. No automatic tangent/curvature constraints or global fairness objective are imposed. Matrix limits default to 1,000,000 entries and 50,000,000 conservative work units (`maxMatrixEntries`, `maxWork`); `rankTolerance` defaults to 1e-12. `checkpoint` also runs inside the solve.

## Revolution and primitives

`revolve(curve,origin,axis,angle,options)` rotates a profile around a finite origin and nonzero axis. V is the rational angular direction; U retains the profile's parameterization. `startAngle` defaults to zero; `angle` is a signed sweep in radians of at most one turn. A rational quadratic angular basis gives exact circles, while the profile's degree and relative weights are retained. `maxControls` defaults to 10,000; `checkpoint` runs per profile control. The normal follows U cross V; use profile reversal to change orientation deliberately.

Primitive constructors use a caller-supplied CFrame:

| Function | Shape and parameter directions |
| --- | --- |
| `plane(frame,size)` | Centered rectangular XY patch; positive Vector2 size, U along X, V along Y |
| `cylinder(frame,radius,height)` | Circular side sheet from local Z=0 to height; U angle, V height |
| `cone(frame,radius,height)` | Conical side sheet; U from apex at height to base at Z=0, V angle |
| `sphere(frame,radius)` | Sphere centered at the frame origin; U north-to-south meridian, V longitude |
| `torus(frame,majorRadius,minorRadius)` | Ring torus around local Z; major > minor > 0, U tube angle, V major angle |

Normals point outward at regular samples. Cylinder and cone sheets have no base caps. Sphere poles and cone apex are singular parameter locations. Torus and full angular directions have duplicated seam controls. Use deliberate seam/pole options when tessellating; do not treat an unwelded parameter grid as a closed solid.

## Coons patches

`coons(bottom,top,left,right,options?)` constructs a positive rational tensor-product surface from ordinary clamped or unclamped rational curves. Bottom/top advance in U; left/right advance in V. Inputs can have different degrees, weights, raw knot domains and internal spans. The default still returns exactly one surface. To inspect construction accuracy, use `returnReport=true`:

```luau
local surface, construction = E.Surfaces.coons(bottom, top, left, right, {
    returnReport = true,
    tolerance = 1e-5, -- agreement of adjacent boundary corners
    maxError = 1e-5,  -- representation error against the classical blend
})
assert(construction.complete)
local mesh = E.NURBS.tessellate(surface, 24, 24)
```

The geometric definition is the classical sum of two ruled blends minus their common bilinear corner blend:

`C(u,v) = (1-v) bottom(u) + v top(u) + (1-u) left(v) + u right(v) - B(u,v)`.

Here `B` interpolates bottom(0), bottom(1), top(0), top(1). Normalized parameters and each boundary's existing parameterization are retained. Adjacent corner positions must agree within nonnegative finite `tolerance` (default 1e-5). The left/right boundaries are interpolated by the real-arithmetic formula; bottom/top can differ from their inputs by at most the reported corner mismatch when input corners are merely close. This construction does not snap, refit or reparameterize the supplied curves. It leaves all inputs and option tables unchanged.

For rational boundaries `N/W`, the common denominator is the product of the bottom/top weight polynomials in U and left/right weight polynomials in V. Positive Bernstein products produce positive tensor weights. The numerator represents the geometric formula above, including its bilinear subtraction. The implementation extracts aligned spans in double homogeneous arithmetic and rounds to native Vector3 controls only at final construction. Shared span controls form one ordinary editable NURBS surface; all internal span boundaries use full degree knot multiplicity. This representation retains any higher geometric continuity of the inputs up to numerical error, but it does not store the smallest possible knot vector or cancel common polynomial factors.

For an axis with opposite boundary degrees `p` and `q`, let `wp=0` for a constant-weight boundary and `wp=p` otherwise, and define `wq` similarly. The output degree is `max(p+wq, q+wp, wp+wq+1)`. Thus two rational degree-8 boundaries can require degree 17. Constant-weight polynomial boundaries keep their usual maximum input degree. Ordinary NURBS representation and edits now support degrees 1 through 17; the unique-periodic and loft interpolation limits remain separately documented. `maxDegree` defaults to 17 and can be lowered. Inputs whose product requires a higher degree reject with an explicit budget error. A cyclic descriptor must first be converted into an ordinary curve with the intended seam; this operator does not choose cyclic seams automatically.

With `returnReport=true`, the second return includes:

| Field | Meaning |
| --- | --- |
| `complete`, `success`, `reason` | Construction met `maxError`, or failed with `reason="precision"`. |
| `constructionErrorBound` | Whole-patch positional bound/allowance relative to the classical real-arithmetic blend of the input curves. |
| `cornerMismatch`, `boundaryErrorBound` | Maximum adjacent-corner mismatch; construction bound plus mismatch bounds boundary disagreement. |
| `nativeRoundingBound` | Largest measured final control-position rounding/stitch displacement. |
| `arithmeticErrorBound` | Homogeneous arithmetic and denominator-conditioning contribution before knot normalization allowance. |
| `knotNormalizationAllowance` | Separate allowance for converting input raw knots into normalized parameter domains. |
| `degreeU`, `degreeV`, `controlsU`, `controlsV`, `patches`, `work` | Representation sizes and counted construction work. |
| `stitchAdjustments` | Shared controls whose independently computed nominal value or weight needed reconciliation. |
| `regularityChecked`, `intersectionsChecked` | Both false; positional accuracy is independent of surface regularity. |

Per-span reconstruction bounds use Bernstein coefficient differences, a positive lower denominator bound and the control hull radius. Conservative absolute floating-point allowances propagate through scalar operations. Knot-domain conditioning uses degree, minimum normalized knot separation, coordinate extent and weight range; it can dominate at large raw knot offsets or extreme weight ratios. These are numerical error bounds with conservative arithmetic allowances, not hardware-directed interval or symbolic certificates. They describe the mathematical surface represented by the returned native controls. Subsequent native evaluation/tessellation adds its own floating-point rounding and tessellation approximation error.

`maxError` is finite and nonnegative, default 1e-5 in authoring units. By default, a construction that cannot meet it throws. `requireComplete=false` permits an inspectable surface with `complete=false` and requires `returnReport=true`; this prevents the legacy single-return path from silently dropping an incomplete report. Corner incompatibility, invalid curves, resource exhaustion, cancellation, nonpositive/underflowed weights and nonfinite controls always reject. Common independent weight scalings do not change the intended geometry. Strongly varying weights, nearly coincident spans or large coordinate offsets can still cause precision failure.

Defaults are `maxControls=10000` for each input curve and the final tensor net, `maxIntermediateControls=20000` per extracted curve, `maxPatches=4096`, and `maxWork=20000000`. Counts are checked before corresponding allocations. Work charges scalar arithmetic and extraction visits; it does not measure wall time or bytes, and source validation/final descriptor copying have their own costs. Subsequent NURBS operations retain their documented default control-validation limit even when a constructor's limit is raised.

`cancelled()` is checked at entry, during work and between patches. `checkpoint(progress)` keeps the numeric progress form. `constructionCheckpoint({stage,work,patches})` additionally runs at entry, approximately every 256 counted visits, after each patch and at completion; it may yield or throw. `Examples.RationalCoonsPanel` constructs a nonplanar patch with four independently weighted boundaries. Twenty-one construction tests cover direct geometric formulas, independent double evaluations of the error bound, circular boundaries, parameter domains, editing, precision failures and native conversion; eight additional cases verify degree-9–17 spline evaluation and edits.

Explicit cross-boundary joins are available below. Automatic border discovery and intersection queries remain separate. Coons blending can fold or self-intersect even when every boundary is individually regular; no regularity or injectivity guarantee is implied.

## Constrained rational patch joins

`join(surfaceA, boundaryA, surfaceB, boundaryB, options)` returns **two independent surface descriptors and a report**. Each boundary is `"U0"`, `"U1"`, `"V0"` or `"V1"`. The surfaces retain their degrees, raw knots, clamping flags, positive weights and unique periodic controls. Only control positions change. Borders can have different along-border degrees, knots and rational denominators. Unclamped cross directions are supported; a periodic cross direction has no boundary and rejects. Along-border periodic directions remain periodic. `reverse=true` matches A's normalized border parameter `t` to B's `1-t`; otherwise both use `t`. Border selection and orientation are explicit.

```lua
local a, b, report = E.Surfaces.join(left, "U1", right, "U0", {
    order = 2,
    fixedA = true,
    pinsB = { ["4:1"] = true, ["4:4"] = true },
    tolerance = 1e-5,
    firstTolerance = 1e-5,
    secondTolerance = 1e-5,
})
```

Let `P` denote border position, `D` the **outward** normalized cross derivative (negative on a 0 border, positive on a 1 border), and `DD` the second normalized cross derivative. With `r=crossScale` (positive, default 1), `order=0` targets `PA-PB=0`; `order=1` also targets `DA+r*DB=0`; `order=2` additionally targets `DDA-r²*DDB=0`. The default order is 1. These are parametric C0/C1/C2 targets under the specified linear parameter correspondence. They are stricter than arbitrary geometric G1/G2 continuity: variable transverse scale, tangent shear and nonlinear border reparameterization are not solved. A repeated along-border knot retains its original one-sided continuity.

With fixed weights, rational positions and derivatives are linear in control positions. The implementation extracts both complete borders into a common Bernstein span partition and multiplies their positive denominators. For homogeneous position `H` and weight `W`, the derivative numerators are `Hx*W-H*Wx` and `Hxx*W²-2*Hx*W*Wx-H*W*Wxx+2*H*Wx²`, over `W²` and `W³`. It solves **every polynomial coefficient constraint**, rather than matching a finite set of samples. Pivoted, twice-reorthogonalized row QR finds the minimum weighted control displacement in the numerically independent constraints; it does not form normal equations. This implementation and its coefficient construction are original. The distinction between parametric derivative matching and geometric continuity follows the [MIT geometric modeling reference](https://web.mit.edu/hyperbook/Patrikalakis-Maekawa-Cho/node13.html).

`fixedA`/`fixedB` leave the respective entire patch unchanged. `pinsA`/`pinsB` use canonical `"i:j"` control keys: `true` keeps the original position, a finite `Vector3` sets an exact native pinned position, and `false` leaves the control free. A moved pin on a fixed patch rejects. `stiffnessA`/`stiffnessB` are positive finite scalars or dictionaries of positive control stiffnesses; missing entries default to 1. Larger stiffness penalizes movement more. The objective is the sum of stiffness times squared displacement over free controls; pins are exact constraints and excluded from that objective. Interior controls absent from the border equations receive zero displacement. Sources and options are copied before solving or callbacks.

All three absolute tolerances default independently to `1e-5`; derivative units refer to normalized cross parameters. Completion requires the whole-border position and requested cross-derivative residual bounds to meet their corresponding tolerances. Optional `maxDisplacement` additionally limits the largest native control movement, including moved pins. `requireComplete` defaults to true and throws when these conditions cannot be met. With `requireComplete=false`, valid descriptors and an incomplete report permit inspection of incompatible fixed weights/pins, insufficient numerical rank, native precision loss or a displacement violation. There is no automatic weight/degree change or fit fallback.

The report includes `complete`, `success`, `reason` (`"tolerance"`, `"constraints"` or `"displacement"`), `positionErrorBound`, the requested `firstDerivativeErrorBound`/`secondDerivativeErrorBound`, `maximumDisplacement`, `weightedSquaredDisplacement`, `spans`, `controls`, `work`, and solver rank/equation/variable counts and `dependentResidual`. Whole-span bounds use reconstructed **native** control coordinates, Bernstein numerator residuals, positive denominator lower bounds and propagated floating-point allowances. Separate `knotNormalizationAllowances` account conservatively for normalized/reversed knot arithmetic, using knot gaps, rational weight ratios and cross-basis derivative magnitudes; ill-conditioned normalization returns infinite bounds. These numerical allowances are not hardware-directed interval certificates. Bounds concern the mathematical surfaces defined by the returned native controls; evaluator rounding and tessellation are separate. They bound the stated position/transverse residuals, not tangential derivative errors, normal angles or curvature invariants near singular points.

`regularityChecked` and `intersectionsChecked` are false. Both-free incompatible rational borders can meet only by changing their geometry substantially, even collapsing a border. Fix a reference patch, pin controls or set `maxDisplacement` when those changes are unacceptable. Completion certifies the documented residual conditions; it does not certify regularity, injectivity, shape fairness, manifold mesh stitching or global patch-network consistency. Outputs remain separate descriptors and separate UV charts. `Examples.JoinedPanels` fixes one rational panel and pins the far border of the other before native tessellation.

Dense resource defaults are `maxControls=10000` per expanded input patch, `maxVariables=1024` free controls across both patches, `maxSpans=128`, `maxConstraints=2048` scalar coefficient rows, `maxMatrixEntries=1000000` per coefficient/work matrix and `maxWork=50000000` counted arithmetic/copy visits. A scalar coefficient carries a value and an error allowance; simultaneous buffers consume additional memory. All free controls count toward the variable budget, including controls with zero border influence. `rankTolerance=1e-11` is relative to individually normalized equation rows and must be between zero and one. `cancelled()` and `checkpoint({stage,work})` run at entry, during counted work, between spans, in QR and at completion; checkpoints may yield or throw. Input descriptor validation, output reconstruction and some table allocation/loop overhead are outside the counted work. The budget is deterministic, not a wall-clock bound. Existing periodic conversion retains its ordinary 10,000-control validation ceiling.

## Mesh seams and poles

`NURBS.tessellate(surface,uSegments,vSegments,options)` returns `(mesh,report)`. Existing callers may ignore the second return. `closedU`/`closedV` weld corresponding sampled seam vertices after checking positions within `seamTolerance` (default 1e-6). Closed directions require at least three segments. UVs and analytic normals remain per corner, so UV discontinuities and hard normal seams survive shared geometric vertices. Closure checks sampled positions; it does not certify that two distinct curves coincide between samples.

`collapsePoles=true` recognizes boundary isocurves whose entire rational control polygon lies within the seam tolerance of one point. It collapses each such boundary into one vertex and converts neighboring quads to triangle fans. Singular samples elsewhere still reject. At a pole, normals use a regular interior sample 1e-5 normalized parameter units from the boundary; this approximates a one-sided limit. Cone apex normals remain different around the fan. A position map that separates a requested seam or pole causes rejection. The report exposes `poles`, `closedU`, `closedV` and `collapsedQuads`.

```lua
local sphere = E.Surfaces.sphere(CFrame.identity, 2)
local mesh = E.NURBS.tessellate(sphere, 32, 64, {
    closedV=true, collapsePoles=true,
})
assert(mesh:validate().closed)
local torus = E.Surfaces.torus(CFrame.identity, 3, 1)
local ringMesh = E.NURBS.tessellate(torus, 32, 64, {
    closedU=true, closedV=true,
})
```

Control edits can still create foldovers, self-intersections or poor triangles. Uniform tessellation does not have a geometric approximation-error guarantee. Bounded adaptive tessellation and closest-point queries are available through SurfaceAdaptive and SplineQuery; see [SPLINE_QUERIES.md](SPLINE_QUERIES.md). Explicit UV trimming and bounded adaptive trimmed tessellation are available through [SurfaceTrim](TRIMMING.md); isolated curve/surface roots and certified surface/surface local arcs with explicit unresolved covers are available through SplineQuery. Complete parameter component partitions and validated global open/closed traversal are available when certified; exact isolated-endpoint periodic seam quotient is available separately. Seam-contained/corner contacts, uncertified seam geometry and general singular/boundary/overlap classification remain open. Tests verify independent circle/sphere/cone/torus equations, section interpolation between samples, all Coons boundaries, constrained border derivatives, normal orientation, seam topology, UV corner continuity and native EditableMesh round trips.
