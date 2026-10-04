# Rational curves and surfaces

`E.NURBS` adds editable positive-weight rational B-spline curves and tensor-product surfaces. The descriptors are ordinary Luau data; constructors copy their control arrays, weights and knots. Operators return new descriptors. Nothing creates Roblox instances until the caller explicitly uses `E.Roblox`.

```lua
local curve = E.NURBS.curve({
    Vector3.xAxis, Vector3.new(1, 1, 0), Vector3.yAxis,
}, 2, {weights = {1, math.sqrt(0.5), 1}})
local refined = E.NURBS.insertKnot(curve, 0.4, 2)
local left, right = E.NURBS.split(refined, 0.4)
local point = E.NURBS.evaluate(curve, 0.5)
local differential = E.NURBS.derivatives(curve, 0.5)
```

This example represents an exact unit quarter circle up to floating-point precision. Knot insertion adds controls without changing its shape. Moving a control on the returned descriptor changes the shape deliberately.

## Domain and representation

- `curve(points, degree, options)` uses `options.knots` and `options.weights`. Its descriptor contains `kind="curve"`, `points`, `degree`, `knots` and `weights`.
- `surface(control, degreeU, degreeV, options)` uses `control[uIndex][vIndex]`, a rectangular Vector3 grid. Options include matching `weights[uIndex][vIndex]`, `knotsU` and `knotsV`. Its descriptor contains `kind="surface"`, `control`, `weights`, both degrees and both knot arrays.
- Ordinary curve/surface degree is 1 through 17, below the control count in that direction. The expanded range supports exact rational Coons product representations. Unique periodic `Cyclic` descriptors retain their separate degree-8 limit, and loft interpolation in the section direction retains its degree-8 solve limit. The default knot vector is clamped and uniformly spaced internally. Custom vectors must be finite, nondecreasing and clamped by default with degree+1 repeated endpoint knots. Set `clamped=false` on a curve, or `clampedU=false`/`clampedV=false` on a surface, to permit exterior knots and non-interpolated endpoint controls. The active raw domain is knots[degree+1] through knots[controlCount+1]. These flags are retained in returned descriptors. Unclamped default knots are uniformly spaced across both the active and exterior spans. Interior multiplicity is at most the degree, so the represented shape stays continuous. Control count defaults to a budget of 10,000; constructors accept `maxControls` to change their allocation check, while subsequent operators currently use the default validation budget.
- Weights must be positive and finite. Common weight scale does not affect evaluation. Zero/negative weights and discontinuous internal knots are rejected. Unique periodic control relationships are provided by [Cyclic](CYCLIC.md). An extremely ill-conditioned rational denominator can still exceed numerical range and raises explicitly.
- Every public parameter is normalized to `[0,1]` and checked rather than clamped. Custom knot domains are mapped internally. Derivatives are with respect to normalized parameters. At an internal repeated knot the right-hand derivative is returned; at the final endpoint the left-hand derivative is returned.

## Curve operations

`evaluate(curve,t)` returns a Vector3. `derivatives(curve,t)` returns `position`, `first`, `second`, `regular` and `curvature`. Curvature is absent at a stationary sample. The implementation differentiates the polynomial basis twice, then applies the rational quotient rule. It accumulates homogeneous coordinates relative to a control-point origin to limit cancellation at world offsets.

`insertKnot(curve,t,count=1)` performs homogeneous corner cutting. The parameter must be strictly interior, and the resulting multiplicity cannot exceed degree. `count=0` returns a validated copy; the same interior-parameter rule applies. `split(curve,t)` inserts the interior knot to degree multiplicity and returns two curves, each parameterized over `[0,1]`. The split ends are clamped; original outer endpoints retain their clamped/unclamped behavior. If split at `s`, left(t) equals original(s*t), and right(t) equals original(s+(1-s)*t). Derivatives scale accordingly. `reverse(curve)` reverses controls, weights and knot intervals, preserving the shape under t → 1-t.

`clamp(curve)` inserts active endpoint knots and removes exterior support controls to produce an equivalent clamped representation. `clampSurface(surface,axis)` does so along U or V. These operations preserve positions and derivatives throughout the active domain, including nonuniform knots and rational weights. Bezier decomposition and degree elevation automatically clamp an unclamped input before constructing their clamped result.

## Surface operations

`evaluateSurface(surface,u,v)` returns a Vector3. `surfaceDerivatives(surface,u,v)` returns `position`, `du`, `dv`, `duu`, `duv`, `dvv`, `regular`, `normal`, `meanCurvature` and `gaussianCurvature`. The oriented normal is `du × dv`; curvature follows that orientation. Normal and curvatures are absent at singular samples. On an outward unit cylinder, mean curvature is -0.5 and Gaussian curvature is zero under this convention.

`insertSurfaceKnot(surface,axis,t,count)`, `splitSurface(surface,axis,t)` and `reverseSurface(surface,axis)` use `axis="U"|"V"`. They operate on complete rows/columns while retaining the relative homogeneous weights between those rows/columns. Refinement therefore preserves the full rational surface, including unequal row weight scales. This does not insert a single isolated control vertex.

`isoCurve(surface,axis,t)` returns an exact rational isoparametric curve. `axis` chooses the varying coordinate and `t` fixes the other coordinate: `isoCurve(surface,"U",0.3)` describes surface(u,0.3).

```lua
local refined = E.NURBS.insertSurfaceKnot(surface, "U", 0.5, 2)
refined.control[3][2] += Vector3.new(0, 0, 0.1)
local mesh = E.NURBS.tessellate(refined, 64, 32, {material=1})
```

`tessellate(surface,uSegments,vSegments,options)` returns `(mesh,report)` with an authoring quad mesh (triangle fans at explicitly collapsed poles), with corner UVs and analytic surface normals. Segment counts are positive integers; `maxVertices` defaults to 100,000. `material` selects the face slot. Optional `map(position,uv,differential)` changes sampled positions and triggers mesh normal recalculation. `checkpoint(progress)` runs after each row and can yield or throw. Singular samples reject unless they lie on a recognized boundary pole with `collapsePoles=true`. `closedU`/`closedV` share coincident seam vertices while retaining per-corner UVs and normals. See [SURFACES.md](SURFACES.md) for seam tolerance, pole normals and topology contracts. The caller remains responsible for topology validation after mapping or severe control edits.

Wrapping, pole collapse and closure require explicit options. Trim domains are available separately through SurfaceTrim; see [TRIMMING.md](TRIMMING.md). There is no global self-intersection test yet. Prepared evaluators, Bezier patch extraction, geometric queries and bounded adaptive tessellation are documented in [SPLINE_QUERIES.md](SPLINE_QUERIES.md). Fixed-weight point fitting is available in SplineFit; nonlinear general fitting is not implemented. Adjacent independent patches need deliberate shared boundaries and seam handling. Floating-point knot comparisons use exact supplied values; intervals too narrow to represent reject during insertion. Curvature is a local differential measurement, not a certification of mesh quality or photographic similarity.

## Degree elevation, Bezier spans and knot removal

`basisWeights(curve,t)` returns the positive rational basis weights; they sum to one and reconstruct the evaluated point as their weighted control sum.

`bezierSegments(curve)` returns `{curve,first,last}` records for each nonempty original knot span. Each returned Bezier curve has normalized local parameters; `first` and `last` map it into the original normalized domain. Homogeneous knot insertion preserves the shape and source weight scales.

`elevateDegree(curve,count=1)` raises polynomial degree while preserving rational shape and parameterization, through homogeneous Bezier degree elevation. The maximum degree remains eight. Adjacent elevated spans share their endpoint control and use full interior degree multiplicity. This is an intentionally redundant representation: original geometric continuity is retained, but the returned knot vector may not have the minimum control count. `count=0` returns an independent copy. `elevateSurfaceDegree(surface,axis,count)` applies the same operation to complete rows or columns while preserving relative weight scales across the net.

`removeKnot(curve,t,count=1,options)` reverses insertion using a small homogeneous least-squares system solved with Givens QR. `removeSurfaceKnot(surface,axis,t,count,options)` evaluates a complete rational control net, not independent row error estimates. Parameters must identify existing interior knots. Neither operation changes the input.

Removal is accepted only when a conservative uniform rational control-net bound is within `options.tolerance` (default 0.00001 authoring units). This bound uses positive basis functions and their partition of unity, so it applies between samples as well as at samples. Bounds accumulate over sequential removals. Extremely unequal weights can make the bound conservative; a refused removal is not evidence that no better approximation exists.

Both return `(descriptor,report)`. The report has `requested`, `removed`, `complete`, `tolerance` and accumulated `errorBound`. Refusal includes `reason`, and an error-bound refusal includes `rejectedErrorBound`. A failed attempt leaves that attempt's original descriptor intact; earlier accepted removals remain in the returned descriptor. Absent knots, nonpositive candidate weights and ill-conditioned inversion report refusal. Invalid arguments throw. `checkpoint(progress)` runs before each removal and may yield or throw to cancel. Cancellation preserves the caller's input.

See [SPLINE_FITTING.md](SPLINE_FITTING.md) for curve/surface interpolation and fixed-weight least-squares fitting.

## Verification and provenance

`NURBSTests` covers exact circular arcs and cylinders, analytic derivatives against independent finite differences, curvature, arbitrary knot domains, weight scaling, knot multiplicity and one-sided derivatives, shape preservation under curve/surface insertion and splitting, reversal, isoparametric curves, native conversion, immutability, translation, cancellation and invalid inputs. `Examples.RationalSurface` refines an exact cylinder, moves a new control, and tessellates it.

The implementation is original Luau. [Michigan Tech's curve knot-insertion notes](https://pages.mtu.edu/~shene/COURSES/cs3621/NOTES/spline/NURBS-knot-insert.html) describe the homogeneous construction, and its [surface notes](https://pages.mtu.edu/~shene/COURSES/cs3621/LAB/surface/knot-insrt.html) explain row/column refinement. No model geometry or third-party implementation was incorporated.
