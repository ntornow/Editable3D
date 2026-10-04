# Editable Bezier curves and distance queries

`E.Bezier` stores editable cubic chains as `{kind="bezier", closed, nodes, durations}`. Each node has a `position`, absolute `left` and `right` handle positions, and a handle-pair `mode`. All edit functions return independent descriptors; they do not modify their input or the scene.

```lua
local E = require(game.ReplicatedStorage.Editable3D)
local chain = E.Bezier.new({
    Vector3.new(0,0,0), Vector3.new(2,3,0), Vector3.new(5,1,1),
})
chain = E.Bezier.setHandle(chain, 2, "right", Vector3.new(4,3,0))
chain = E.Bezier.split(chain, 1, 0.4)
local rational = E.Bezier.toNURBS(chain)
local distanceMap = E.ArcLength.prepare(rational, {tolerance=0.001})
local half = distanceMap.atFraction(0.5)
assert(half.converged)
local path, sampling = distanceMap.sample(32)
assert(sampling.converged)
local mesh = E.Curves.sweep(E.Curves.circle(0.1, 8), path)
```

## Handles and editing

`Bezier.new(points, options)` requires 2–3333 points. `closed=true` adds a wrap segment. `durations` supplies a positive finite duration per segment; defaults are one. Their normalized cumulative sums define the shared `[0,1]` parameter. `left` and `right` can supply full handle arrays. Explicit handles default to free mode; other nodes default to automatic mode. `mode` overrides that choice for all nodes. `maxNodes` may lower the constructor budget.

| Mode | Behavior |
| --- | --- |
| `free` | Handles are independent. |
| `aligned` | Handles are collinear and opposed, with independently retained lengths. Selecting this mode uses the right handle direction when it is nonzero. |
| `vector` | Each handle points one third of the way toward its neighboring anchor; endpoints with no neighbor have a zero handle. Each segment is a straight line. |
| `auto` | Direction is the normalized sum of incoming and outgoing unit chords; each handle length is one third of its adjacent chord. Opposing chords produce zero handles. |

`setPoint(curve, index, position)` transports that node's handles by the anchor displacement, then recomputes automatic/vector handles and enforces aligned pairs. `setMode(curve, index, mode)` changes the pair's mode and resolves handles. `setHandle(curve, index, side, position)` edits one absolute handle. Automatic pairs become aligned; vector pairs become free. For aligned pairs, the opposite handle rotates to remain opposed without changing its length. A zero moved handle imposes no direction. Other nodes remain unchanged.

`split(curve, segment, localParameter)` performs cubic de Casteljau subdivision, inserts a node and divides the segment duration proportionally. Shape and the global parameterization are retained to native-position precision. The affected endpoint pairs become free so automatic recomputation cannot change the result. The inserted pair is aligned. Wrap segments on closed curves are supported. `reverse(curve)` reverses durations and swaps handles; closed curves retain their first anchor as their seam. Evaluation then corresponds to the original at `1-t`.

`toNURBS(curve)` returns an ordinary polynomial cubic NURBS descriptor, with triple interior knots and clamped endpoints. Closed chains duplicate the first endpoint in their NURBS representation. `evaluate(curve,t)` and `derivatives(curve,t)` use that representation. For repeated queries, use `NURBS.compileCurve(Bezier.toNURBS(curve))`. Curve joins are C0 in general; aligned handles give geometric tangent continuity when nonzero. Parametric derivative continuity additionally depends on handle lengths and segment durations. Automatic handles do not guarantee absence of overshoot, intersections or curvature discontinuities.

The handle concepts follow the [Blender curve structure documentation](https://docs.blender.org/manual/en/5.0/modeling/curves/structure.html). This is an independent, documented automatic-handle rule and a mode per handle pair; it does not claim Blender's exact automatic placement or per-side mode representation. Descriptors expose their resolved controls so callers can author them directly; use the edit functions when mode constraints should be recomputed. Collapsed duration intervals and invalid/nonfinite inputs reject explicitly.

## Reusable arc-length maps

`ArcLength.prepare(curve, options)` snapshots a positive-weight NURBS curve and extracts its Bezier spans. Chord lengths bound each span from below; control-polygon lengths bound it from above. The largest unresolved intervals are subdivided first. The returned frozen map contains `length` (interval midpoint), `lowerBound`, `upperBound`, `errorBound`, `converged`, `reason`, `segments`, `visited` and these dot-call functions:

- `atLength(distance)` returns a parameter whose prefix arc length approximates the supplied nonnegative world-space distance.
- `atFraction(fraction)` targets the fraction of the curve's true total length, for `fraction` in `[0,1]`.
- `sample(count)` returns positions and a report for equally spaced length fractions, including both endpoints.

`ArcLength.parameter(curve,distance,options)` and `ArcLength.sample(curve,count,options)` are convenience calls that prepare a map once per call. Retain a prepared map for repeated queries.

Inverse queries bisect using prefix-length intervals. A bracket moves only when its interval is wholly on one side of the target interval. Results include `parameter`, `position`, `tangent` (the unnormalized parameter derivative), prefix `length/lowerBound/upperBound`, `targetLowerBound/targetUpperBound`, `errorBound`, `converged`, `iterations`, `parameterLowerBound/parameterUpperBound` and `reason`. Convergence means the arc-distance residual is within the requested tolerance; it does not require a unique inverse. Flat/zero-length spans can return any suitable parameter. Absolute distances beyond the upper length bound reject; distances within total-length uncertainty may remain unresolved. Fraction endpoints return the original parameter endpoints exactly. Total length and prefix length are correlated at those endpoints, so their fraction residual is zero.

Defaults: `tolerance=1e-4`, `maxNodes=10000` refinements, `maxLeaves=20000`, `maxDepth=24`, `maxIterations=48`, `maxSamples=10000` and `maxWork=1000000`. Preparation aims for total interval width at most `tolerance/4`, leaving room for inverse residuals. A failed preparation can still answer an easy query, so inspect the individual query's convergence. Sampling bounds its prospective inverse iterations by `count*(maxIterations+1) <= maxWork`; refinement is separately bounded by `maxNodes`. `checkpoint({stage, visited|iteration})` can yield or throw to cancel, including the beginning of each prepared query.

Sampling reports `parameters`, per-sample `results`, maximum `errorBound`, total `length` estimate and `converged`. The bound applies to each sample's target distance; adjacent spacing can differ by twice that bound. Initial span allocation, invalid options and sample budgets throw. Refinement/depth/iteration exhaustion returns nonconvergence and its actual residual interval. These are numerical bounds from positive rational control hulls, subject to floating-point evaluation and native float32 control rounding. Choose tolerance relative to object size and translation; requesting below native precision cannot establish an exact CAD result.

## Tangent-controlled adaptive samples

`SplineQuery.sample(curve, {tolerance=0.01, maxAngle=0.05})` additionally bounds the angle between a segment chord and every regular tangent inside that segment. `maxAngle` is in radians and must be in `(0,pi/2)`. The derivative numerator `H'W-HW'` is expressed in a Bernstein basis; its coefficients must lie in a convex forward cone around the chord. Subdivision continues until both distance and tangent tests pass, subject to the existing node/depth limits.

The report adds `tangentErrorBound` and `stationarySegments`. A constant segment has no directional constraint and is counted as stationary. A reversal or unresolved cusp cannot satisfy a forward cone across that segment. Explicit knot corners may have different tangents on their two sides; this option bounds each segment, not the angle between adjacent segments. A tiny rational weight ratio that underflows during the proof rejects rather than returning a false bound. Without `maxAngle`, existing sampling behavior is unchanged.

Tests cover independent cubic and circle geometry, nonuniform rational speeds, repeated anchors, zero-length spans, closed seams, handle edit semantics, shape/derivative preservation under splitting, reversal, immutable maps, scale/weight/translation effects, cancellation and budgets, tangent checks throughout segment interiors, and edited-curve sweeps through native EditableMesh conversion.
