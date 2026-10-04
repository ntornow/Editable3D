# Curve and surface fitting

`E.SplineFit` creates and refines editable rational NURBS descriptors from caller-supplied positions. `curve` and `surface` provide fixed-weight, fixed-parameter linear fits; `refineCurve` and `refineSurface` jointly refine controls, positive rational weights and sample correspondences. Fitting is pure Luau, does not fetch geometry and does not create scene objects. It complements `E.NURBS` control editing, degree elevation and conservative knot removal.

```luau
local curve, report = E.SplineFit.curve(points, 3, 8, {
    parameterization = "centripetal",
    pinEndpoints = true,
})
local interpolating = E.SplineFit.interpolateCurve(points, 3)
local surface, fit = E.SplineFit.surface(sampleGrid, 3, 3, 6, 6, {
    parametersU = sampleU,
    parametersV = sampleV,
})
local mesh = E.NURBS.tessellate(surface, 64, 64)
```

## Parameters and weights

`curve(points,degree,controlCount,options)` minimizes weighted squared point residuals at specified parameters. `interpolateCurve(points,degree,options)` uses one control per sample and also checks the resulting sample error against `options.tolerance` (default 0.0001 authoring units); incompatible pins or excessive numerical error reject instead of reporting interpolation success.

Parameters must be strictly increasing and span exactly `[0,1]`. Supply `options.parameters`, or choose `parameterization="chord"|"centripetal"|"uniform"` (default chord). Adjacent repeated samples cannot use chord/centripetal parameters unless all points coincide; use uniform parameters or provide an explicit sequence. A wholly constant sequence uses uniform parameters. Interpolation uses averaged interior knots. Fits with fewer controls use uniformly spaced clamped interior knots. `options.knots` supplies a different valid clamped vector.

`weights` are fixed positive rational control weights, default one. They are not optimized. `sampleWeights` are positive observation confidence weights and are normalized internally; multiplying all confidences by a common finite positive factor does not affect the solution. Both rational and sample weight arrays must match their respective counts. Extreme ratios can make the system singular or exceed numerical range and reject.

Curve endpoints are pinned to the endpoint samples by default. Set `pinEndpoints=false` to fit them freely. `pins[controlIndex]=Vector3` holds additional control positions exactly. Conflicting endpoint pins reject. Pins constrain control positions, not parameter-space samples.

## Surfaces

`surface(grid,degreeU,degreeV,controlsU,controlsV,options)` fits a rectangular `grid[uIndex][vIndex]`. `interpolateSurface(grid,degreeU,degreeV,options)` uses the sample counts as control counts and enforces the same interpolation tolerance contract.

`parametersU` / `parametersV` supply exact parameter arrays. Without them, the selected curve parameterization is computed on each row/column and averaged in the corresponding direction. `knotsU` / `knotsV` override the defaults. `weights[uControl][vControl]` may vary independently across the entire control net. The solve uses the complete rational tensor-product basis; it does not incorrectly treat a nonseparable weight grid as independent curve fits.

`pins[uControl][vControl]=Vector3` constrains surface controls. Surface fitting does not automatically pin boundary samples. `sampleWeights[uSample][vSample]` supplies observation confidence. Positive weights and rectangular dimensions are validated before solving.

## Solve and report

Coordinates are centered at the first sample. A private dense Givens-QR kernel solves the fixed-weight linear system without forming normal equations. The result is a newly allocated NURBS descriptor; inputs and pins are not mutated. Rank deficiency or excessive conditioning loss rejects. The `rankTolerance` threshold defaults to 1e-12 relative to the largest encountered pivot (with an absolute floor at that scale).

Reports contain `success`, `rank`, matrix `rows` / free `columns`, `method`, a diagnostic `diagonalRatio`, unweighted `rmsError` / `maximumError` over supplied samples, parameters and control/sample counts. QR's diagonal ratio is a diagnostic, not a certified condition number. Fitting success means the bounded linear solve completed; it does not mean that the requested control count can accurately represent the samples. Inspect the residuals. Interpolation additionally reports `interpolated=true` and the checked tolerance.

Defaults: 256 controls (total for surfaces), 10,000 samples, 1,000,000 matrix entries and a conservative 50,000,000-unit work budget. `maxControls`, `maxSamples`, `maxMatrixEntries` and `maxWork` can be explicitly changed. Allocation/work estimates are checked before matrix construction. This is a dense solver; larger fits should be partitioned or use deliberate budgets. `checkpoint(progress)` runs per QR column and may yield or throw to cancel; cancellation does not mutate input data.

The library stores positions in Roblox Vector3 values, so float32 precision bounds the resulting controls. The four APIs above keep parameters and rational weights fixed. The refinement APIs below optimize them; none of these functions chooses control count automatically. Local fit accuracy does not certify global surface validity or absence of intersections.

## Nonlinear refinement

`refineCurve(initialCurve, points, options?)` and `refineSurface(initialSurface, points, options?)` return an independent fitted descriptor and report. They accept ordinary clamped/unclamped NURBS or unique periodic `Cyclic` descriptors. Knots, intervals, degrees, cyclic state and control counts remain fixed. Periodic controls are fitted once; expanded seam duplicates share their unique control's variables. Start from a reasonable descriptor, for example a primitive, edited control grid or preceding linear fit. These are local nonlinear solves and cannot choose a globally correct parameter correspondence or escape every local stationary point.

The sample input is a flat array of finite Vector3 positions for both functions, including surfaces. `parameters` supplies one scalar per curve sample or one Vector2 per surface sample, initially in [0,1]. Surface parameters are required; they need not form a rectangular grid. Curves default to uniform parameters over [0,1], or [0,1) for a cyclic curve. A single curve sample starts at zero. Samples need not be ordered and repeated parameters are allowed. Parameters can move independently and change order during fitting. Open directions clamp to [0,1]; cyclic directions wrap across their seam. Optimized parameters are local correspondences, not globally certified closest points. Use the separately bounded `SplineQuery` closest-point APIs when that certificate is needed.

```luau
local fitted, report = E.SplineFit.refineSurface(initial, samples, {
    parameters = initialUVs,
    optimizeControls = true,
    optimizeWeights = true,
    optimizeParameters = true,
    pins = { ["1:1"] = initial.control[1][1] },
    parameterPinsU = { [1] = 0 }, -- sample 1 stays on the U=0 border
    tolerance = 0.0001,
})
if report.converged and report.toleranceSatisfied then
    local mesh = E.NURBS.tessellate(fitted, 32, 32)
end
```

Controls and parameters optimize by default; rational weights stay fixed unless `optimizeWeights=true`. Disable each family independently with `optimizeControls=false`, `optimizeWeights=false`, or `optimizeParameters=false`. All-disabled fits still evaluate residuals and return a copied descriptor. They report `termination="fixed"`, because no permitted variable remains, even if sample errors are large.

`pins` supplies exact control positions and `weightPins` supplies positive exact weights. Refinement curve pins use numeric control indices; refinement surface pins use canonical `"i:j"` keys, matching `SurfaceEdit` selections. These dictionaries differ from the nested surface pin arrays of the older linear fitting functions. Missing indices and noncanonical keys reject. Pins are applied to the initial state before fitting, including when that variable family is disabled. Pin values and samples are copied and remain unchanged on failure.

`parameterPins[sampleIndex]` supplies an exact scalar or Vector2 parameter and holds it fixed. Surface `parameterPinsU` and `parameterPinsV` fix individual coordinates and override the corresponding component of a full parameter pin. Surface parameter states and reports use native Vector2 precision; scalar U/V pins are rounded to that same representation. Curve scalar parameters use Luau number precision. Neither control endpoints nor sample endpoints are implicitly pinned during refinement.

Weights are optimized in logarithmic coordinates, so every accepted weight remains positive. The relative weight change is bounded by `exp(±maxLogWeightChange)` from its initial value; the default log limit is 20, with supported explicit values in (0,100]. These bounds prevent unlimited scale drift but still permit extreme, poorly conditioned rational distributions. Multiplying all initial weights and weight pins by a common finite positive factor leaves the rational problem unchanged, subject to representable ratios. When weights optimize without any weight pin, the first unique control weight is held fixed to remove the common-scale ambiguity; `weightGaugeControl` identifies it. With explicit weight pins, those pins set the scale. Common scaling can still overflow/underflow finite arithmetic and reject.

`sampleWeights` supplies positive observation confidence for the flat sample array. Confidences are normalized by their maximum. The objective is the sum of confidence-weighted squared residuals divided by a fixed coordinate scale squared. That scale is the largest absolute coordinate difference from the first sample among all initial controls and samples, or one for a constant dataset. The report exposes `coordinateScale`, `initialCost`, `cost`, monotone accepted `costHistory`, ordinary and confidence-weighted RMS errors, and maximum sample error. Weight fitting, control fitting and parameter updates all minimize this same objective. No smoothing/fairness penalty or outlier loss is added implicitly.

## Nonlinear solver and completion

The solver uses analytic rational derivatives for control coordinates, log weights and normalized parameters. Log-weight derivatives are `R_i(P_i-S)`, where `R_i` is the rational basis coefficient; repeated periodic contributions are accumulated into the unique control coefficient. Native surface/curve derivatives supply parameter directions. Coordinate increments are normalized by the fixed scale. A private Givens-QR solve computes a damped Gauss–Newton step by appending diagonal damping rows, avoiding normal equations. This follows the standard augmented least-squares damping construction described in the [Ceres nonlinear solving guide](https://ceres-solver.readthedocs.io/latest/nnls_solving.html); no Ceres code is incorporated.

Variables at a bound whose descent direction points outwards are held fixed for that step. Proposed steps are limited to one coordinate-scale unit per control coordinate, one log-weight unit, and 0.25 per parameter coordinate by a shared step factor, then projected/wrapped as appropriate. Candidate controls are stored as native Vector3 values and surface parameters as native Vector2 values before evaluating the objective through the ordinary NURBS evaluator. Only strict measured cost decreases are accepted. Accepted steps reduce damping; rejected steps increase it. Thus a double-precision linear prediction cannot produce a false accepted improvement that vanishes when saved to native geometry.

Reports distinguish convergence from accuracy. `complete`, `success` and `converged` agree and become true when the maximum sample error meets `tolerance` (default 1e-5 authoring units), the scaled projected gradient meets `gradientTolerance` (default 1e-8), or all variables are fixed. `toleranceSatisfied` independently states whether the maximum error met the requested accuracy. A constrained or noisy fit may converge with substantial residual. Gradient stationarity does not certify a local minimum, global optimum, unique solution, globally closest correspondences, surface regularity or absence of intersections; `regularityChecked=false` remains explicit.

Iteration exhaustion returns the best accepted state with `termination="iterations"` and false completion. Failure to find a decreasing candidate within the attempt limit returns `termination="stalled"`; native precision plateaus can cause this even with a nonzero analytic gradient. The solver does not silently reinterpret a tiny native step as convergence. `requireConverged=true` throws for these incomplete outcomes. Invalid inputs, exhausted allocation/work budgets, arithmetic failures and cancellation also throw without mutating caller data. `projectedGradient` is present only when measured at the returned state; residual-based early completion does not claim a final gradient measurement.

Defaults are 30 iterations, 8 damping attempts per iteration, damping 0.001, rank tolerance 1e-12, 64 unique controls, 1,000 samples, 256 scalar variables, 10,000 expanded controls, 1,000,000 entries per dense matrix and 200,000,000 estimated work units. Options are `maxIterations` (0–1,000), `maxAttempts` (1–64), `damping` (1e-12–1e16), `rankTolerance` (0–1 exclusive), `maxControls`, `maxSamples`, `maxVariables`, `maxExpandedControls`, `maxMatrixEntries` and `maxWork`. Downstream NURBS evaluation retains its own expanded-control limit. Each free control contributes three variables, each free weight one, and each free sample parameter one or two. Dense QR costs grow with the square of the variable count; partition large jobs or deliberately set budgets. No wall-clock bound is promised.

`cancelled()` and `checkpoint({stage, work, iterations, evaluations})` run during setup, sample evaluation, iterations and QR columns. Work accounting includes sample/basis evaluation, Jacobian assembly and conservative QR estimates. Reports include iterations, accepted/rejected steps, evaluations, variable/control/sample counts and consumed work. Callbacks can yield or throw; they must not rely on a particular callback frequency. Neither function creates native objects or publishes assets.

## Verification

Tests compare fitted curves and surfaces to independent polynomial geometry between sample locations, recover exact circle geometry with known rational weights, exercise nonseparable surface weights, verify confidence scaling and exact pins, and check translation, immutability, budgets, cancellation and refusal of incompatible interpolation constraints. Native conversion remains covered by the NURBS tessellation and Roblox adapter suites.

Twenty-three nonlinear cases additionally recover unknown circle/surface weights and local sample correspondences, check joint fitting and periodic seam crossing, compare analytic Jacobians to centered differences, verify a constrained weighted-mean solution, exact pins, common weight/confidence scales, moderate world transforms, unclamped knots, bound stationarity, iteration/precision failure reports, cancellation inside QR and a fitted native mesh roundtrip with normals and UV borders. `Examples.RationalFitStudy` demonstrates rational weight recovery on an editable surface.
