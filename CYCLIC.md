# Cyclic spline control nets

`E.Cyclic` stores every control once. A periodic curve's `points`, `weights` and `intervals` each have one entry per unique control. Changing a seam control therefore changes both sides of the evaluated seam. All functions are pure data operations; constructors and edits return independent arrays.

`curve(points,degree,options)` returns `kind="cyclicCurve"`, `points`, `weights`, `degree` and `intervals`. Degree is 1–8 and below the unique control count. Positive finite weights default to one. `intervals` are nonnegative knot spans around one period, defaulting to one each. There must be one interval per unique control, a positive finite total, and fewer than `degree` consecutive zero intervals, including across the seam. Repeated knots can reduce continuity. With distinct knots, degree-p splines are C(p-1) across the seam.

`evaluate(curve,t)` and `derivatives(curve,t)` accept normalized t in [0,1], with the same derivative/report conventions as NURBS. They expand wrapped controls for evaluation. `toNURBS(curve)` returns an independent unclamped NURBS descriptor covering exactly one period. Its endpoint derivatives agree subject to knot continuity. That copy can be clamped, split, elevated, tessellated or fitted using other APIs; edits on the expanded copy no longer enforce cyclic control relationships.

`rotateSeam(curve,offset)` shifts the unique control and interval arrays by an integer, which may be negative. The new parameter origin is the old origin plus the corresponding accumulated knot intervals, modulo the period. `reverse(curve)` preserves geometry with t mapped to 1-t, including nonuniform intervals and rational weights.

`insertKnot(curve,t,count=1)` refines corresponding knots over three periods, retaining the middle control cycle. It preserves the periodic shape and keeps unique controls editable. t must be strictly between zero and one; rotate the seam for a boundary edit. Existing multiplicity plus count must not exceed degree. Invalid multiplicities throw rather than producing a broken seam.

`surface(control,degreeU,degreeV,options)` stores a unique rectangular grid and matching rational weights, with `kind="cyclicSurface"`. `cyclicU` and `cyclicV` default to true; at least one must be true. The corresponding `intervalsU`/`intervalsV` describe periodic directions. Open directions accept `knotsU`/`knotsV` and `clampedU`/`clampedV` with the NURBS defaults. Nonseparable rational weights are retained.

`surfaceToNURBS(surface)` expands the cyclic rows/columns into an independent NURBS surface. `evaluateSurface` and `surfaceDerivatives` use the NURBS parameter and differential conventions. `insertSurfaceKnot(surface,axis,t,count)`, `reverseSurface(surface,axis)` and `rotateSurfaceSeam(surface,axis,offset)` edit complete control rows/columns along `axis="U"|"V"`. Rotation rejects an open direction; reversal and insertion also work on open directions. Editing `control[i][j]` or `weights[i][j]` directly is supported; subsequent calls validate the net and generate wrapped copies.

The default constructor budget is 10,000 expanded controls, including seam copies. Constructors accept `maxControls`; the earlier conversion/insertion/reversal operations use the default. Three-period insertion has a stricter temporary expanded-control requirement. Very narrow intervals can fall below floating-point resolution. Those earlier operations have no cancellation callbacks; degree/removal edits and surface tessellation provide checkpoints.

## Degree elevation and knot removal

Version 0.27 adds `elevateDegree(curve,count=1,options)` and `removeKnot(curve,t,count=1,options)`, returning a unique cyclic descriptor and a completion report. `elevateSurfaceDegree(surface,axis,count,options)` and `removeSurfaceKnot(surface,axis,t,count,options)` apply the same edits across a periodic `axis="U"|"V"`. The other direction can be open or cyclic. These surface functions reject an open edit direction; ordinary NURBS degree/removal APIs remain available for open representations. Every returned control/weight/interval array is independent of the source, including unchanged or partially accepted results.

Elevation increases the degree by count, up to eight. Every distinct periodic knot's multiplicity increases by that count, including the seam, preserving the represented continuity and parameterization. The number of unique controls increases by count times the number of positive intervals. Unlike an open Bezier-chain conversion, this result keeps unique periodic controls and retains the original knot continuity. Count zero returns an independent copy. The whole requested elevation either succeeds or returns the unchanged descriptor with `complete=false`; a native rounding tolerance that is too small can reject an otherwise exact algebraic elevation.

Removal decreases the multiplicity of a knot once per accepted step. `t` is normalized within the period and must lie strictly between 0 and 1; rotate the seam before editing its knot. `t*sum(intervals)` must equal a cumulative interior interval boundary in double arithmetic. There is no fuzzy nearest-knot selection. Missing knots, insufficient unique controls, nonpositive recovered weights, ill-conditioned solves or excessive error stop removal. Previously accepted steps are returned, with `complete=false` when fewer than requested succeeded. The source remains unchanged. Surface steps accept or reject all rows/columns together.

Both edits refine source and candidate bases to a common piecewise Bernstein representation. Source homogeneous coefficients are elevated in scalar arithmetic when needed. A Givens QR least-squares solve recovers the candidate's unique homogeneous controls from coefficient equations, rather than fitting sampled curve points. Coordinates are centered and weights share a normalization to reduce translation/weight-scale sensitivity. Output controls are converted to native Vector3 and then substituted back into the coefficient equations before acceptance, so the reported bound includes that conversion's error.

For corresponding homogeneous coefficients A/B, let `deltaH` be the maximum XYZ coefficient difference, `deltaW` the maximum weight difference, `minimum` the smallest source weight coefficient, and `radius` the largest candidate Euclidean coefficient distance from the common origin. The accepted uniform position bound is `(deltaH + radius*deltaW)/minimum`. Positive Bernstein basis functions form a partition of unity, making this a bound between samples. Surface edits use a single origin, weight normalization and bound across all control rows with the unchanged transverse B-spline basis; independent per-row rational position bounds would miss changes in cross-row blending. Repeated removal sums accepted step bounds. This is a conservative floating-point coefficient calculation; scalar arithmetic is not an outward-rounded exact interval certificate, and normal/curvature error is not bounded. Native evaluation has its own rounding error.

Options are `tolerance=1e-5` in position units, `maxControls=256` unique controls along the edited direction, `maxSurfaceControls=10000` total unique surface controls before/after editing, `maxMatrixEntries=1000000` per coefficient/work matrix, `maxWork=50000000` accumulated estimated scalar work, and `rankTolerance=1e-12` for relative QR pivots. Matrix limits apply to each allocated matrix, not total simultaneous bytes. Dense solves make these editing tools appropriate for modest control nets, with explicit rejection of larger jobs. Constructor expanded-control limits still apply. `cancelled()` and `checkpoint({stage,work})` run at entry, refinement stages, QR columns, verification and finish; throwing cancels without modifying inputs. Budget and malformed-input errors throw, while a legitimate geometric/numerical inability to perform an edit returns an incomplete report.

Reports contain `complete`, `requested`, `elevated` or `removed`, cumulative `errorBound`, `tolerance`, `work`, `peakMatrixEntries`, and `method`. Unaccepted edits add `reason`; a tolerance rejection adds `rejectedErrorBound` for the attempted step. Always inspect `complete`, including for elevation. Degree elevation retains the mathematical shape within the accepted native-coordinate bound; knot removal can intentionally approximate it when a larger tolerance is requested. Neither operation certifies regularity, injectivity or absence of self-intersection.

```lua
local raised, elevation = E.Cyclic.elevateDegree(cyclic, 1, {tolerance=1e-4})
assert(elevation.complete, elevation.reason)
local refined = E.Cyclic.insertKnot(raised, 0.375)
local restored, removal = E.Cyclic.removeKnot(refined, 0.375, 1, {tolerance=1e-4})
assert(removal.complete, removal.reason)
```

`CyclicEditTests` includes independent rational line-segment coordinates, degrees 1–8, nonuniform and repeated knots, seam derivatives, exact and approximate removal, incomplete reports, native precision rejection, common weight scaling, transforms, cancellation/budgets, nonseparable rational surface weights, mixed open/cyclic directions and closed native mesh conversion. `Examples.EditedPeriodicSurface` demonstrates periodic surface edits. These operations have the conventional degree/multiplicity and removal roles described in the [Open CASCADE BSplCLib reference](https://occt3d.com/dev/doc/refman/html/class_b_spl_c_lib.html); this package uses its own coefficient solve and acceptance bound, with no Open CASCADE source incorporated.

```lua
local cyclic = E.Cyclic.curve({
    Vector3.new(2,0,0), Vector3.new(0,2,0),
    Vector3.new(-2,0,0), Vector3.new(0,-2,0),
}, 3)
cyclic.points[2] += Vector3.zAxis
local refined = E.Cyclic.insertKnot(cyclic, 0.37)
local openRepresentation = E.NURBS.clamp(E.Cyclic.toNURBS(refined))
```

The four-control example is a smooth closed spline, not an exact circle. Use `Surfaces.arc` for exact rational circular geometry. Tests cover degrees 1–8, seam derivatives, unique-control edits, nonuniform seam rotation/reversal, insertion near both endpoints, repeated knots, mixed open/closed surface directions and nonseparable weights.
