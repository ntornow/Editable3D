# Spline queries and adaptive surface meshes

These are pure Luau geometry operations. They validate descriptors, work on copies and leave scene mutation, native conversion and publishing to callers. Length, sampling, closest-point and adaptive-mesh bounds use ordinary floating-point geometric algorithms. Curve/surface intersections have separate outward-interval and exact affine-plane contracts below. Native Vector3 precision and ill-conditioned weights impose practical accuracy floors. Choose tolerances consistent with model scale and inspect completion reports.

## Prepared evaluation and patch extraction

`NURBS.compileCurve(curve)` and `NURBS.compileSurface(surface)` validate and copy their inputs once. The returned frozen tables expose `evaluate(t)`/`derivatives(t)` or `evaluate(u,v)`/`derivatives(u,v)`. Functions are called with a dot, without a self argument. Subsequent edits to the source descriptor do not change the prepared snapshot. This avoids repeated validation and array copies during dense sampling; parameter checks and numerical-range checks still run.

`NURBS.bezierPatches(surface)` clamps both active directions, inserts interior knots to full degree multiplicity and extracts independent rational Bezier patches. Each record contains `surface`, `u0`, `u1`, `v0`, `v1`. Local (u,v) maps to original (u0+(u1-u0)*u, v0+(v1-v0)*v). Positions and rational weights are preserved; derivative scaling follows that mapping. The result may have more controls than the input and uses the NURBS control budget.

## Curve length and sampling

`SplineQuery.length(curve,options)` decomposes the curve into Bezier spans and adaptively splits the span with the widest length interval. Chords give lower bounds, and control-polygon lengths give upper bounds. It returns `length` (the interval midpoint), `lowerBound`, `upperBound`, `errorBound` (half the interval width), `converged`, `visited`, `segments`, and a `reason` on nonconvergence.

Subdivision-based chord/polygon length bounds are described by [Gravesen's research](https://orbit.dtu.dk/en/publications/adaptive-subdivision-and-the-length-and-energy-of-b%C3%A9zier-curves/). Positive-weight rational subdivision also uses Euclidean corner cutting; triangle inequalities keep the refined control-polygon length below the original polygon length. No quadrature estimate is substituted for the reported geometric interval. The implementation is original and does not incorporate third-party source code.

`SplineQuery.sample(curve,options)` returns `(points,report)`. It splits Bezier spans until their control hull lies within the requested distance of the endpoint segment. The convexity of distance to a segment bounds the complete curve between samples. The ordered polyline includes both endpoints. `report.parameters` contains corresponding normalized parameters; it also includes `errorBound`, `converged`, `segments`, `visited`, and optional `reason`. This is a geometric polyline-distance bound, not a bound on linear parameter interpolation or on tangent angles. Closed curves retain their duplicated final point for callers to handle explicitly.

## Closest points

`SplineQuery.closestCurve(curve,point,options)` and `closestSurface(surface,point,options)` return a candidate with `position`, `distance`, `parameter`, `lowerBound`, `errorBound`, `converged`, `visited`, and optional `reason`. Curve parameters are numbers; surface parameters are `{u=...,v=...}` tables of doubles.

Candidates come from endpoints/corners and projected Newton steps with line search and positive-Hessian fallback. A priority queue of rational control hulls supplies the global search: axis-aligned and oriented enclosing boxes provide conservative distance lower bounds, and knot subdivision tightens them. The search stops when the candidate distance minus the smallest remaining lower bound is within tolerance. Local Newton convergence alone never declares the global search complete.

`errorBound` measures uncertainty in the minimum distance. It does not bound the positional distance from one unique minimizing point; symmetric or flat shapes may have multiple equally close points. Parameters remain constrained to [0,1], including boundaries. Queries do not assume an outward normal or a closed solid and return no inside/outside sign. The returned position is on the spline; no mesh approximation is used for the final candidate.

All four SplineQuery operations accept positive `tolerance` (default 1e-4 authoring units), `maxNodes` (default 10,000), and `maxDepth` (default 24, maximum 52). A limit produces a useful partial result with `converged=false` and an explicit reason. `checkpoint(progress)` can yield or throw to cancel. Initial Bezier extraction and local candidate iterations are additional bounded work; node counts measure subdivision/search work rather than raw evaluations. Pathological precision or weight ratios can prevent convergence.

```lua
local profile = E.Surfaces.arc(CFrame.identity, 2, 0, math.pi)
local length = E.SplineQuery.length(profile, {tolerance=0.001})
assert(length.converged)
local points, sampling = E.SplineQuery.sample(profile, {tolerance=0.01})
local surface = E.Surfaces.sphere(CFrame.identity, 2)
local nearest = E.SplineQuery.closestSurface(surface, Vector3.new(3,2,1), {
    tolerance=0.001,
})
assert(nearest.converged)
```

## Curve/surface intersections

`SplineQuery.intersectCurveSurface(curve,surface,options)` defaults to `method="interval"` and returns a report containing `roots`, `unresolved`, `complete`, `success`, `converged`, `coverageCertified`, and counters. It accepts ordinary or unique-periodic rational descriptors with positive weights. Raw, nonuniform and unclamped domains are retained; returned parameters are normalized to the original full domains. Inputs and options are snapshotted before callbacks. No mesh approximation is used to discover or certify roots.

```lua
local result = E.SplineQuery.intersectCurveSurface(curve, surface, {
    tolerance = 1e-5,
    parameterTolerance = 1e-7,
    maxNodes = 10000,
})
for _, root in result.roots do
    -- Existence and uniqueness are certified even if native accuracy is limited.
    print(root.curveParameter, root.u, root.v, root.position, root.errorBound)
end
if not result.complete then
    -- These parameter boxes remain possible intersections; none may be discarded.
    for _, region in result.unresolved do print(region.reason, region.parameterBox) end
end
```

Each root record contains scalar `curveParameter`, `u`, `v`; a native `position`; `parameterBox={{t0,t1},{u0,u1},{v0,v1}}`; an absolute-coordinate `positionBox={{xmin,xmax},{ymin,ymax},{zmin,zmax}}`; `errorBound` enclosing the distance from the native returned position to the exact intersection; and `parameterErrorBound` enclosing the maximum scalar-coordinate error of the returned parameters. `certified` and `unique` are true. `classification="isolated"`, `nonsingularEnclosure=true`, `contractionNorm<1`, and `isolatingBoxes` record the isolation proof. `accurate` additionally requires spatial error at most `tolerance` and every parameter-box width at most `parameterTolerance`. A large world translation can leave an existing, isolated mathematical root unrepresentable accurately as a native Vector3; that root remains certified with `accurate=false` and the query incomplete.

Roots are sorted by curve parameter, then U/V. Distinct parameter branches at the same spatial point are retained. Duplicate search discoveries merge only when a certified root enclosure lies inside another certified isolating box. Overlapping root enclosures without such an identity proof make the result incomplete. Periodic descriptors expand into their ordinary mathematical representation; this version retains the closed `[0,1]` parameter domain and does not choose ownership of the 0/1 seam automatically.

The kernel centers native control coordinates, normalizes each descriptor by a common positive weight gauge, and extracts homogeneous Bezier controls using outward-rounded interval knot insertion in the **raw** knot domain. It keeps scalar doubles throughout extraction and restriction. Control hulls enclose homogeneous values, rational positions, and normalized first derivatives over every intersected knot span. A query crossing an internal knot combines all applicable one-sided derivative enclosures; matching remains valid for continuous piecewise differentiable splines. Source degree/knots/weights are unchanged.

For homogeneous curve `HC/WC` and surface `HS/WS`, the root system is `F=HC*WS-HS*WC` in three parameters. Interval range and geometric-box separation prove empty regions. A numerical inverse supplies a preconditioner `C`; its accuracy is validated by outward interval bounds rather than assumed. The Krawczyk map `m-C*F(m)+(Identity-C*J(X))*(X-m)` encloses every root in box X. Disjointness excludes X. Inclusion in X together with an outward infinity-norm bound below one proves a contractive self-map and a unique root. This also handles compatible internal knot boundaries through the enclosed piecewise derivatives. Search uses overlapping children to avoid making an artificial split plane a permanent root boundary. A final pass removes unresolved regions subsequently covered by a certified isolating box. The implementation is original; see the [MIT interval arithmetic discussion](https://web.mit.edu/hyperbook/Patrikalakis-Maekawa-Cho/node45.html) for background on interval spline geometry.

Arithmetic uses IEEE754 buffer representations documented by [Luau](https://luau.org/library/). Adjacent-double operations use stored integer bits. Some Studio runtimes flush subnormal arithmetic or comparisons to zero: arithmetic inputs/results in that range are conservatively widened to normal endpoints around `2.2250738585072014e-308`, instead of relying on subnormal comparisons. Nonzero subnormal parameter endpoints or knots, underflowing raw knot gaps, and weights whose normalized lower bound is nonpositive reject explicitly. Ordinary finite arithmetic is widened outward. Tests compare **stored bits and endpoint ordering**, including cancellation, subnormal operands, overflow and division, against 2,900 independent Python nextafter/Fraction checks. Separate exact Fraction fixtures verify homogeneous values, rational positions and normalized derivatives for seven curve and 49 nonseparable tensor samples. The fixture generators are in `tools/` and require only Python's standard library.

`coverageCertified=true` means every possible root in the requested parameter box is retained in a certified isolation region or an unresolved region; it does **not** mean every retained region contains a root. `complete`, `success` and `converged` are true only when no unresolved regions remain and every certified root is accurate. A complete empty list proves no intersections in that parameter domain. `reason` is `"complete"`, `"unresolved"` or `"precision"`. `unresolved` records contain `parameterBox`, `depth`, `certified=false`, and `reason` (`"nodes"`, `"depth"`, `"roots"`, `"boundary"`, `"singular"`, `"precision"` or `"identity"`). Those reasons identify why the search stopped; they are not geometric classifications. Reports also include `visited`, `excluded`, `covered`, `curvePieces`, `surfacePieces`, `work`, and the requested `parameterBox`.

The default interval method certifies isolated roots and whole-domain exclusions. The explicit `exactPlane` method below resolves tangencies, overlap intervals and closed boundary contacts for a rank-two affine patch. These classifications for general curved surfaces and periodic seam ownership remain **open**. Such contacts are retained explicitly; an approximate residual near zero alone never certifies them. An unresolved box may contain several roots or a continuous overlap. The API does not produce intersection curves between two surfaces, curve/curve intersections, trim loops, intersection multiplicities, surface regularity or self-intersection certificates. `Examples.IntersectionProbe` demonstrates a certified crossing and native surface tessellation.

| Option | Default and behavior |
| --- | --- |
| `tolerance` | `1e-5`, positive native position error limit |
| `parameterTolerance` | `1e-7`, positive maximum width of each certified root parameter interval |
| `parameterBox` | `{{0,1},{0,1},{0,1}}`; three nonempty closed ranges within the original normalized domains |
| `maxNodes` | `10000`; exhaustion retains pending boxes as unresolved |
| `maxDepth` | `48`, range 0–128; includes contractions and subdivision |
| `maxRoots` | `1024`; additional root regions remain unresolved |
| `maxIterations` | `20`, range 1–128; contractions refining one certified root |
| `maxControls` | `10000` per expanded descriptor; existing periodic conversion additionally retains its ordinary 10,000-control validation ceiling |
| `maxPieces` | `2048` spans/patches per descriptor; projected patch count is checked before extraction |
| `maxCoefficients` | `1000000` scalar interval coefficients per retained descriptor and intermediate work array; value and derivative storage is projected before extraction, and simultaneous buffers consume additional memory |
| `maxWork` | `50000000` counted interval/coefficient and search visits; exceeding this hard work budget throws |
| `requireComplete` | `false`; true throws instead of returning an incomplete report |
| `cancelled`, `checkpoint` | Cancellation predicate and `checkpoint({stage,work,visited,roots})` at entry, counted work, search steps and completion; callbacks may yield or throw |

Node/depth/root/accuracy limits return the explicit partial cover. Validation, arithmetic-range and hard allocation/work failures throw transactionally. Input snapshot/validation, some allocation/copy overhead, sorting and the interval kernel's bit operations are outside the counted work. Counts are deterministic resource measures, not wall-clock guarantees. Returning only `roots` while ignoring `complete` and `unresolved` can lose intersections.

## Exact curve/affine-plane contacts

`SplineQuery.intersectCurveSurface(curve, patch, {method="exactPlane"})` computes the complete contact set of a positive-weight rational curve and a single rank-two affine patch. The curve can be ordinary or unique-periodic, with nonuniform, unclamped or repeated raw knots. The patch must be an ordinary degree-one 2×2 surface with constant weights, an exact stored-coordinate parallelogram and two independent directions. Unsupported patches throw; the method does not silently approximate them by a plane. The default interval method remains available for general curved surfaces.

```lua
local result = E.SplineQuery.intersectCurveSurface(curve, patch, {
    method = "exactPlane",
    requireComplete = true,
})
for _, root in result.roots do
    print(root.curveParameter, root.u, root.v, root.position)
    for _, contact in root.contacts do
        print(contact.knotSpan, contact.order, contact.planeIdentity)
    end
end
for _, arc in result.overlaps do
    -- The two vertices delimit a continuous rational arc, not a straight chord.
    local first, last = result.vertices[arc.first], result.vertices[arc.last]
    print(first.curveParameter, last.curveParameter)
end
```

The authoritative output is a finite contact complex in the closed `(t,u,v)` parameter domain:

- `vertices` contains ordered contact events, including overlap endpoints and internal boundary touches. `roots` contains only isolated vertices, which have no incident overlap arc. A result with an empty `roots` list can still contain continuous intersections in `overlaps`.
- `overlaps` contains closed rational arcs, with `first` and `last` indices into `vertices`. `homogeneousExact` holds four low-degree-first rational power coefficient arrays `(X,Y,Z,W)` in the original knot span's local coordinate `x`. Divide the first three values by positive `W` to recover the exact spatial curve. `surfaceParametersExact={U,V,W}` similarly gives patch parameters. `parameterMap={offset,scale}` maps `x` to full-domain `t=offset+scale*x`.
- `localEndpoints` gives the two exact or algebraically isolated local endpoint values. `endpointPolynomial` is square-free; a non-exact endpoint is its unique real root in the returned closed rational `[low,high]`. For `exact=true`, `low==high` is authoritative and need not be a root of that polynomial (for example, a requested domain endpoint).
- `components` lists `vertexIndices`, `overlapIndices` and `parameterDimension` (zero or one). These are complete connected components in parameter space. A constant spatial curve still has a one-dimensional parameter component. Spatial coincidences and cyclic `t=0/1` representatives remain distinct; no periodic quotient is performed.

Each vertex has scalar `curveParameter`, `u`, `v`, a `parameter={t,u,v}` record and `parameters={t,u,v}` array, outward native `parameterBox` and `positionBox`, native `position`, `parameterErrorBound`, `errorBound`, and `accurate`. `algebraic` stores its local exact/isolated value and the exact map to full-domain t. Exact rational events additionally expose `parametersExact` and `positionExact`. Exact values use the existing `{sign,n,d}` base-2²⁴ unsigned-limb rational representation; native positions are approximations of these values, not replacements for them. `activeBounds` names exact `uMin`, `uMax`, `vMin` or `vMax` contacts relative to the requested box. `edgeIndices` identifies incident overlaps.

`contacts` retains one record per incident knot span: `span`, original `knotSpan`, `planeIdentity` and `order`. For a noncoincident span, `order` is the multiplicity of its homogeneous plane numerator at the contact: an even interior order touches the plane without changing side; an odd order changes side, including stationary odd-order crossings. At knots these are one-sided analytic orders, not a global smoothness assertion. A coplanar span reports `planeIdentity=true, order=0`, including isolated contacts caused by patch inequalities. Shared knots are merged by exact normalized t and verified exact spatial equality, never by proximity.

`coverageCertified`, `rootCoverageComplete`, `parameterTopologyCertified` and `parameterComponentsCertified` are true on every returned report. Hard proof failures throw without a partial success. `complete`, `success` and `converged` additionally require every native event position and parameter to meet the requested error bounds; otherwise `reason="approximation"`. Exact arcs do not carry a sampled-polyline or whole-chord approximation claim. `unresolved` is empty; an empty **vertices and overlaps** result proves disjointness. `Examples.PlaneContacts` demonstrates a double corner tangency and an overlap with irrational endpoints.

The implementation forms exact homogeneous span powers directly from stored raw knots and controls. Square-free decomposition preserves repeated-root orders. Closed-endpoint Sturm counts isolate every plane root; exact common factors decide zero boundary constraints at algebraic roots, while rational interval refinement determines nonzero signs. For coplanar spans, the square-free least common multiple of boundary polynomials partitions the entire parameter interval into constant-sign cells. Closed feasible cells and their endpoints give the contact graph. Domain endpoints remain explicit unless the isolated root is exactly that endpoint; strict rational gaps between isolators provide interior samples even for overlaps shorter than the requested native tolerance. See [Sturm's Theorem with Endpoints](https://arxiv.org/html/2208.07904v1) for the half-open counting convention; the implementation is original. Independent Python Fraction/Decimal fixtures cover 128 polynomial cases (270 roots), 64 weighted curve/plane configurations (57 contacts), and 320 raw-knot homogeneous de Boor values.

| Option | Exact-plane behavior |
| --- | --- |
| `tolerance`, `parameterTolerance` | Positive native event error limits, default `1e-5` and `1e-7`; parameter tolerance bounds maximum coordinate error, not interval width |
| `parameterBox` | Three nonempty closed normalized t/u/v ranges, default the full domain |
| `maxDepth` | `128`, range 0–512; exact bisection depth for each local root, including boundary sign decisions |
| `maxNodes` | `10000`; shared isolation and refinement node cap across all spans |
| `maxRoots` | `1024`; caps each span's critical roots and the total returned vertices |
| `maxIterations` | `24`, range 0–128; additional refinements per feasible event for native accuracy, after exact classification |
| `maxControls`, `maxPieces` | `10000` controls per descriptor and `2048` positive curve spans; cyclic conversion retains its ordinary validation ceiling |
| `maxPolynomialDegree` | `96`, maximum 256; caps intermediate polynomial degree, including boundary arrangements |
| `maxExactBits` | `8192`; signed rational numerator/denominator arithmetic bit cap |
| `maxCoefficients` | `1000000`; cumulative scalar polynomial coefficient allocations, not just one live array |
| `maxWork` | `50000000`; shared exact arithmetic, coefficient and search work visits |
| `maxSnapshotEntries` | `4000000`; bounded detached source/options copies, maximum nesting 64, cycles rejected |
| `requireComplete`, `cancelled`, `checkpoint` | Completion requirement and callbacks follow the curve/surface convention; callback errors propagate |

Proof node/depth/root/degree/coefficient/bit/work exhaustion throws; it cannot be mistaken for an empty intersection or complete classification. Native endpoint approximation can instead return a proved contact complex with `complete=false`. Counted work is deterministic and includes integer limb arithmetic; validation, table overhead and sorting are not wall-clock guarantees. High-degree or ill-conditioned exact polynomials can exhaust the caps. This specialization does not complete general curved surface tangencies/overlaps or arbitrary surface/surface singularities.

## Surface/surface intersection arcs and parameter components

`SplineQuery.intersectSurfaces(surfaceA,surfaceB,options)` defaults to `method="interval"`, returning a certified cover by ordered local arcs. It accepts the same positive rational ordinary/unclamped/unique-periodic descriptors and snapshots inputs before callbacks. Parameters are `{uA,vA,uB,vB}`, each normalized to its original full source domain. The surfaces remain unchanged. The explicit `method="exactAffine"` described below returns complete convex contact/overlap cells for single affine parameterizations. `method="exactRuled"` returns exact graphs, exceptional rulings and coplanar bands for a rational ruled first surface and an affine second patch. `method="exactTensorPlane"` extends this to general tensor first surfaces, both original knot directions and both periodic seams. `method="exactRuledPair"` classifies two rational ruled operands through a planar base and compact convex ruling fibers. `method="exactGraphPair"` classifies two curved tensor graphs with a common exact affine planar projection.

```lua
local result = E.SplineQuery.intersectSurfaces(surfaceA, surfaceB, {
    tolerance = 0.002,
    requireComplete = true,
    requireComponents = true,
})
for _, arc in result.curves do
    for _, segment in arc.segments do
        local a = arc.samples[segment.first].position
        local b = arc.samples[segment.last].position
        -- The exact arc is within segment.errorBound of this chord.
    end
end
```

The report contains `curves`, `unresolved`, `coverageCertified`, `rootCoverageComplete`, `complete`, `success`, `converged`, `reason`, `parameterBox`, `visited`, `excluded`, `covered`, `work`, `segmentCount`, `piecesA` and `piecesB`. Every possible intersection in the requested four-dimensional domain is covered by a curve's `parameterBox` or an unresolved region. An unresolved region is a possible-root enclosure, not an existence claim. `rootCoverageComplete=true` means all possible roots are covered by proved graphs; `complete=true` additionally requires all their ordered approximations to meet the requested accuracy. A complete empty result certifies disjoint surfaces in the requested domains. Component certification is reported separately below.

Each curve has `certified=true`, `uniqueGraph=true`, `parameterAxis` (1–4), `parameterRange`, `parameterBox`, `isolatingBox`, `contractionNorm<1`, `samples`, `segments`, `accurate` and an overall `errorBound` when sampling succeeds. For every value of the free `parameterAxis` in `parameterRange`, exactly one dependent parameter triple exists in `isolatingBox`; all such triples lie in `parameterBox`. Each record therefore represents a connected, ordered local parameter graph. The choice of free coordinate can change between records, allowing coverage of closed loops and multiple branches. Accepted domain expansion and padding each receive a fresh existence proof.

A sample contains `parameter`, four double `parameters`, certified `parameterBox` and absolute `positionBox`, native `position`, Euclidean `errorBound`, `parameterErrorBound`, `certified` and `accurate`. Samples increase in free parameter. A segment names its consecutive `first` and `last` sample indices, `parameterRange`, `parameterBox`, interval `tangentBox` and `parameterDerivativeBox`, Euclidean chord `errorBound`, `certified`, `accurate` and optional failure `reason`. Derivatives use the free parameter as the independent variable; its component is exactly one. Endpoint error includes native Vector3 rounding. Segment error bounds the continuous exact arc and the real straight segment joining the stored native endpoints, in both directions by their common linear parameter correspondence. Further client-side arithmetic or rendering rounding is additional.

Records can overlap and duplicate portions of one branch. `components` groups their indices using proved shared-root connections. `parameterComponentsCertified=true` means this is the complete connected-component partition of all roots in the requested **closed four-dimensional parameter domain**. It requires complete root coverage and proved separation between every remaining group, independently of chord accuracy. Only then is `componentCount` present. Every curve has a one-based `component` index. Each group contains `curveIndices`, `connectionIndices`, a hull `parameterBox`, `connected=true`, and `isolated`/`certified` flags. Without a complete certificate, these are proved connected subsets that may belong to larger components; a group's hull does not assert roots throughout its interior.

`connections` is a spanning forest of shared-root witnesses, with `firstCurve`, `secondCurve`, `sourceCurve`, `targetCurve`, `parameterBox`, `parameterAxis`, `parameterRange`, `certified=true` and proof text. A nonempty restriction of the source graph whose root enclosure lies inside the target's full isolating domain proves a shared root by existence and uniqueness. Spatial proximity or overlapping boxes alone never proves a connection. Remaining pairs are separated by disjoint root enclosures or by exhaustive interval restriction of one graph. Finite unions of compact, connected graphs with pairwise proved separation give the certified partition. Redundant connections within an already joined group need no further proof.

`unresolvedConnections` retains undecided intergroup pairs (`firstCurve`, `secondCurve`, overlap `parameterBox`, `reason`, `certified=false`). `connectivity` reports `complete`, `pairs`, `visited` (new graph restrictions), `excludedPairs`, `witnessTests`, `connections`, `unresolvedPairs`, and `reason`. Pair exhaustion adds a `frontier` naming the first unexamined pair; all subsequent lexicographic pairs remain unexamined except those already in the same group. Unknown pairs later joined transitively are removed. `connectivity.complete` concerns the returned graphs; only `parameterComponentsCertified` also requires complete root coverage.

`componentSpace` explicitly keeps periodic zero/one endpoints distinct. Different parameter roots at the same world position remain distinct. For nonuniform periodic descriptors, floating-point expansion of raw knots need not produce exact translated knot sequences; the cyclic flag alone is insufficient to certify a seam quotient. The local `curves` records remain overlapping and unordered within a component; their connection forest alone does not classify loops. Optional validated assembly below supplies a separate ordered path and a parameter-topology certificate. Optional exact isolated-endpoint seam identification is described below. General tangencies, overlapping patches, isolated singular contacts and difficult domain-boundary contacts remain open. Ignoring either unresolved cover, concatenating all records, or treating the local curve count as a component count is invalid. `Examples.IntersectionComponents` demonstrates two certified branches.

The three homogeneous equations are `F=HA*WB-HB*WA`. A selected three-column Jacobian minor treats the remaining coordinate as a free interval. Interval Krawczyk inclusion and contraction prove one dependent root for **every** free value, rather than merely finding point samples. Exclusion and closed midpoint subdivision retain all possible roots. Graph enlargement requires another inclusion proof; dependent padding encloses the interval Newton image and stays within the requested domain. Covered-region cuts remove only subsets of already certified isolating domains and retain closed slabs covering the remainder. Jacobian variation guides search order without changing proof conditions.

An optional `affinePartner` certificate accelerates intersections with a degree-one, two-by-two, equal-weight affine patch. Exact expansion arithmetic verifies the parallelogram identity; an outward nonzero projected determinant proves an injective affine parameterization. Outward projection of the other source's entire positive-weight control hull must lie strictly inside the requested affine parameter ranges. Only under these conditions may search retain those two full ranges and subdivide the other source's parameters, with larger boxes visited first. The original four-parameter equations still certify every graph. The record contains `surface` (`"A"` or `"B"`), `fixedAxes`, `searchAxes`, `projectedParameterBox` and `certified=true`. Near-planarity, unequal weights and clipped footprints fall back to general search. `nonlinearSplits` and `coveredCuts` count search heuristics, not additional certificates.

For sampling, an outward residual `R=Id-C*J` with infinity norm below one gives the implicit derivative identity `g'=-C*F_t+R*g'`. A Neumann bound followed by interval fixed-point intersections encloses dependent derivatives. Rational first jets map this bound into spatial derivatives. On a free interval of width `h`, each coordinate's difference from its endpoint chord is bounded by `h/4` times the width of its derivative enclosure; endpoint uncertainty is then added in Euclidean norm. This first-derivative argument remains valid for continuous piecewise smooth splines with kinks, without assuming continuous second derivatives. Integrating the two signed pieces of the interpolation error kernel gives equal absolute integrals `s*(h-s)/h <= h/4`; subtracting the derivative interval's lower endpoint gives the stated bound. Refinement recomputes derivative bounds on smaller intervals. The outward arithmetic and flush-to-zero safeguards described above apply.

| Option | Default / behavior |
| --- | --- |
| `tolerance` | `1e-4`, positive Euclidean native-endpoint/chord error |
| `parameterTolerance` | `1e-7`, maximum dependent parameter width at samples |
| `parameterBox` | Four `{0,1}` ranges; nonempty, finite, normalized, normal-range endpoints |
| `maxNodes` | `20000`, interval search nodes |
| `maxDepth` | `48`, maximum search or per-chart sampling depth, at most 128 |
| `maxCurves` | `1024`, certified local graph records |
| `maxSegments` | `8192`, total returned chord segments across all records |
| `maxIterations` | `20`, contraction iterations per graph/sample restriction, at most 128 |
| `maxControls`, `maxPieces` | `10000`, `2048`, per-source control/Bezier-patch bounds |
| `maxCoefficients`, `maxWork` | `1000000`, `100000000`, hard coefficient/work budgets |
| `requireComplete` | `false`; throw on incomplete coverage or approximation |
| `requireComponents` | `false`; throw unless the complete parameter component partition is certified |
| `maxConnectionPairs` | `100000`, intergroup chart pairs considered; zero allowed |
| `maxConnectionNodes` | `10000`, total new point/range restrictions during connectivity; cached samples do not consume nodes; zero allowed |
| `maxConnectionDepth` | `24`, pair-separation subdivision depth, at most 128; zero allowed |
| `cancelled`, `checkpoint` | Cancellation callback and `{stage,work,visited,curves}` progress; may throw/yield |

Node/depth/curve limits retain unresolved boxes. Sampling depth/segment/native-precision limits retain certified graphs with `accurate=false`; graphs beyond the segment budget can have empty sample/segment arrays with `reason="segments"`. Their existence and coverage certificates remain valid. Connection limits retain unknown pairs or a pair frontier without changing the graph cover or `complete`. Validation, coefficient/work exhaustion and cancellation throw transactionally. Work counts include spline restrictions, interval algebra, search comparisons and connectivity; source copying/validation, table allocation and bit-operation overhead are not wall-clock guarantees. The `connect` checkpoint occurs before connectivity work and during its pair/refinement visits. Bounds can be conservative with poor parameterization, high degrees or large weight ratios. Validated intersection analysis is discussed in the [MIT subdivision overview](https://web.mit.edu/hyperbook/Patrikalakis-Maekawa-Cho/node108.html) and [validated intersection tracing paper](https://web.mit.edu/deslab/pubs/files/SM04.pdf); this implementation uses parametric interval graphs rather than an ODE solver.

## Exact affine contacts and overlaps

Use `method="exactAffine"` when both surfaces have degree one in each direction, a 2×2 control net, equal positive weights within each net, and an **exact stored-coordinate parallelogram**. Each surface is then `P(u,v)=O+u*U+v*V` over its full normalized domain. Single unclamped spans are supported. Rank-zero points and rank-one collapsed patches are allowed. Nonaffine bilinear patches, nonconstant weights, larger/higher-degree nets and periodic nets reject explicitly; this method does not approximate them as planes. Geometrically planar rational patches can still have nonaffine parameterizations and therefore be ineligible.

```lua
local result = E.SplineQuery.intersectSurfaces(a, b, {
    method = "exactAffine",
    tolerance = 0.0001,
    requireComplete = true,
    requireComponents = true,
})
for _, cell in result.cells do
    print(cell.kind, cell.parameterDimension, cell.spatialDimension)
    -- The full root set is the convex hull of parametersExact at every vertex.
    -- For a spatial polygon, triangles indexes the corresponding vertex records.
    for _, triangle in cell.triangles do
        local p = cell.vertices[triangle[1]].position
        local q = cell.vertices[triangle[2]].position
        local r = cell.vertices[triangle[3]].position
    end
end
```

The method solves `A(uA,vA)=B(uB,vB)` as three exact rational linear equations, intersected with the requested closed four-dimensional `parameterBox`. Row reduction gives a nullspace of dimension `d`. Every vertex of this bounded polytope has `d` linearly independent active coordinate bounds in that nullspace. Exhaustively solving every choice of `d` coordinates and lower/upper sides, rejecting infeasible candidates and deduplicating exact vertices therefore finds **all** roots as their convex hull. There are at most 32 candidate systems in four parameters. A nonempty bounded polytope always has a vertex, so no feasible vertices proves emptiness. Exact affine-hull ranks classify both the parameter polytope and its spatial image. No geometric tolerance is used to decide incidence, rank, coincidence or emptiness.

The report has `algorithm="exactAffine"`, `cells` (zero or one), `affineEquations` (three rows of four coefficients followed by the right-hand side), `equalityRank`, `affineCandidates`, `parameterBox`, `work`, `rootCoverageComplete=true`, `coverageCertified=true`, `cellTopologyCertified=true` and `parameterComponentsCertified=true`. `componentCount` is zero or one: every nonempty root set is convex and connected. A component names `cellIndices`, its parameter `dimension`, a hull `parameterBox`, and `connected/isolated/certified=true`; its `curveIndices` and `connectionIndices` are empty. `curves`, `unresolved`, `connections` and `unresolvedConnections` are empty. `visited=1` represents the solved domain; `covered` or `excluded` records whether that domain has a cell. Read `cells` for this method rather than interpreting an empty `curves` list as disjointness.

Each cell contains:

| Field | Meaning |
| --- | --- |
| `certified`, `topologyCertified`, `convex`, `connected` | Exact closed convex root and image sets; the parameter set is a closed ball of its stated affine dimension, including a point in dimension zero |
| `parameterDimension` | Affine dimension 0–4 of the full parameter root set |
| `spatialDimension`, `kind` | Spatial dimension 0–2 and `point`, `segment` or `polygon` |
| `surfaceRanks` | Exact constant derivative ranks of A and B, each 0–2 |
| `spatialMapInjective` | True exactly when the parameter and spatial dimensions agree; otherwise different parameter roots share world positions |
| `vertices` | Every parameter-polytope vertex with its corresponding exact spatial point; spatial points may duplicate or lie inside the spatial hull |
| `parameterBoundary` | A point index, two ordered endpoint indices, or an ordered polygon boundary for parameter dimension 0, 1 or 2; absent for dimension 3 or 4, whose full vertex hull remains the exact representation |
| `spatialBoundary` | One point index, two ordered extreme endpoints, or a counterclockwise polygon boundary, indexing `vertices`; duplicate and collinear spatial points are removed |
| `parameterProjectionAxes`, `spatialProjectionAxes` | Coordinate indices used for boundary ordering; one axis for a segment, two for a polygon; polygon order is counterclockwise in that injective coordinate projection |
| `triangles` | Fan triangles indexing `vertices` for spatial polygons; empty for point/segment images |
| `parameterBox`, `positionBox` | Outward coordinate hulls enclosing the entire exact cell |
| `errorBound`, `accurate` | Outward two-sided whole-cell distance bound to the native spatial convex hull, and whether it meets `tolerance` |
| `nativeTopologyCertified` | True only when all native spatial vertices are exact (`errorBound=0`); otherwise native hull topology is unverified even if the approximation meets tolerance |

A vertex stores four `parametersExact` and three `positionExact` scalars as canonical rationals `{sign,n,d}`. `n` and `d` are little-endian unsigned base-2²⁴ integer limbs; the exact value is `sign * integer(n) / integer(d)`, with positive denominator and coprime integers. Zero is `{sign=0,n={},d={1}}`. These detached values are authoritative; do not convert large limb integers to a single double before dividing. The record also contains approximate double `parameters`, outward `parameterBox`, absolute `positionBox`, native Vector3 `position`, Euclidean native `errorBound`, maximum-coordinate `parameterErrorBound`, `certified`, `accurate`, and `activeBounds` entries `{axis,side}` (axes 1–4; side 1 lower, 2 upper).

Positive leading-limb interval evaluation encloses each rational, with the existing flush-to-zero safeguards and exact stored-bit checks for representable values. The maximum vertex displacement bounds the **whole** exact/native spatial convex hulls in both directions: use the same convex coefficients on their corresponding vertices. Polygon fan triangles likewise give a common piecewise-linear correspondence with this bound. This proves approximation distance, not preservation of native triangle orientation, nondegeneracy or polygon topology after rounding. Client interpolation/rendering can introduce additional rounding. Approximate parameter coordinates evaluated independently on the surfaces need not coincide; the exact parameter hull is the root representation.

`complete`, `success` and `converged` additionally require the spatial approximation to meet the positive `tolerance` (default `1e-4`). A tiny tolerance can yield `reason="approximation"` while the root set, dimensions and component partition remain exact and complete. `requireComplete` then throws. Empty results are complete. `requireComponents` is supported. The interval arc traversal and periodic quotient flags retain their separate meanings: `parameterTopologyCertified`, `componentTopologyCertified`, `orderedComplete` and quotient flags stay false here. Requesting `orderComponents`, `requireOrdered`, `identifyPeriodicSeams` or `requireQuotient` with this method throws; the cell boundaries above describe its geometry instead.

The common source validation, nonempty normalized parameter ranges, snapshot rules, `maxControls`, `maxPieces`, `maxWork` (default 100,000,000), `maxCoefficients` (default 1,000,000), cancellation and checkpoints apply. This implementation reserves a 4,096-coefficient working allowance before exact enumeration. `maxExactBits` (default 8,192) bounds integer intermediates; exhaustion throws instead of replacing an exact decision with a numerical guess. Progress adds `affineIdentity`, `affineSolve` and `affineBounds` stages. The interval-search soft limits (`maxNodes`, depth/curve/segment/ordering limits) do not control this finite enumeration. There is no source mutation or partial commit on error.

`Examples.AffineOverlap` constructs an eight-sided overlap and its native-ready triangle fan. Tests include 72 independent Fraction/Cramer/minor configurations with 185 exact vertices, 85 rational enclosure cases, rank-zero/rank-one degeneracies, boundary and corner-only contacts, tiny positive gaps, nearly parallel planes, disparate scales, native precision, snapshots, hard limits/cancellation and an EditableMesh round trip. General curved tangencies, singularities and overlaps remain outside this affine method.

## Exact ruled-surface/affine-plane contacts

`SplineQuery.intersectSurfaces(ruled, patch, {method="exactRuled"})` computes the complete closed-domain contact set when the first surface has degree one and exactly two controls along one direction. Its other, profile direction can have arbitrary supported degree, positive rational weights, nonuniform or unclamped raw knots, repeated knots and unique-periodic controls. `linearAxis="U"` or `"V"` chooses the ruling direction; the default chooses V when eligible, otherwise U. The second surface must be an ordinary degree-one 2×2 constant-weight patch whose stored controls form an exact rank-two parallelogram. Unsupported inputs throw.

This includes tangent rulings, crossing branches, isolated boundary points, branches attached to coplanar regions and wholly coplanar overlap regions. It retains source parameter dimension even when the spatial image collapses to a line or point. It does not identify coincident spatial points. Periodic profile endpoints remain separate unless exact seam identification is requested below. `Examples.RuledContacts` demonstrates a saddle crossing and a clipped coplanar quadratic patch.

```lua
local result = E.SplineQuery.intersectSurfaces(ruled, patch, {
    method = "exactRuled",
    requireComplete = true,
    requireComponents = true,
})
for _, component in result.components do
    print(component.parameterDimension, #component.cellIndices)
end
for _, cell in result.cells do
    print(cell.kind, cell.parameterDimension, cell.component)
end
```

The authoritative output is symbolic, with exact rational coefficients in the existing `{sign,n,d}` base-2²⁴ limb representation. Polynomial arrays are ordered from constant term upward; an empty array is zero. A rational function `{n,d}` means the polynomial numerator divided by the polynomial denominator.

- `spans` is a map keyed by the original positive profile-span ordinal; restricted domains can leave gaps in these keys. Each entry has four homogeneous polynomial arrays `a` and `b`. In local profile coordinate `s` and original normalized ruling coordinate `t`, the source surface is `(a(s)+t*b(s)).XYZ / (a(s)+t*b(s)).W`. Positive weights prove a positive denominator. `offset` and `scale` map local s to the original profile parameter. `u` and `v` are pairs of homogeneous polynomials giving the affine patch's normalized parameters after division by W. `knotSpan` retains the original raw knot index.
- `events` orders critical profile values, including both requested endpoints. Its `profile={polynomial,low,high,exact,offset,scale}` identifies one exact rational value or one isolated root of a square-free polynomial. For `exact=true`, `low==high` is authoritative and need not be a polynomial root. The remaining fields include `feasible`, incident `spans` and an optional owned `cell`. Shared original knots have one event owner after exact homogeneous continuity and fiber-bound checks.
- A `kind="fiber"` cell owns one feasible closed event fiber. `profile` identifies its profile value; `linearBounds` contains two rational functions evaluated there. `parameterDimension` is zero for a point and one for a nontrivial ruling interval. `first` and `last` index its native anchor vertices. `rulingInPlane` records whether the whole source ruling lies in the plane before patch clipping.
- A `kind="graph"` or `"band"` cell has an **open** profile interval given by `profileEndpoints`, `firstEvent` and `lastEvent`. Its `linearBounds` gives the closed feasible t interval for every interior s. Equal bounds define a one-dimensional graph; strictly ordered bounds define a two-dimensional band. `boundaryVertices` stores the two limiting t anchors at each endpoint. The endpoint fibers own these closed boundaries, including attachment points inside a larger exceptional ruling.
- `connections` records each slab's complete endpoint-limit attachment to its event fiber, using `firstCell`, `secondCell`, `side`, `firstVertex` and `lastVertex`. `components` gives the complete connected-component partition through `cellIndices`, `connectionIndices` and maximum `parameterDimension`; each cell has a `component` index. This is a partition in the closed four-dimensional source parameter domain. An interval of spatially constant contacts still has positive parameter dimension.

Each vertex contains four `parameters`, outward `parameterBox` and `positionBox`, a native `position`, `parameterErrorBound`, `errorBound`, `accurate`, `event`, and its exact `algebraic={profile,linear,span}` description. Exact rational events additionally expose `parametersExact` and `positionExact`. Native vertices are anchors: joining them with straight segments or polygons does **not** inherit an approximation certificate for the intervening graph or band.

Every returned report has `coverageCertified`, `rootCoverageComplete`, `cellTopologyCertified`, `cellDimensionsCertified` and `parameterComponentsCertified` true. Graph cells are continuous parameter arcs; bands are homeomorphic to an open profile interval times a closed ruling interval. `parameterTopologyCertified` and `componentTopologyCertified` remain false: this method does not provide a manifold classification or globally ordered traversal through singular branches. `ordering.requested` is false, and requests for global regular-arc ordering throw. `periodicQuotient.requested` is false by default; complete fiber identification can be requested below. `complete`, `success` and `converged` additionally require all native anchors to satisfy both error tolerances; otherwise `reason="approximation"`. An empty `cells` array proves disjointness. Proof-budget failures throw transactionally; they cannot return a misleading empty or partially certified result.

For each original knot span, plane equality and patch clipping reduce to polynomial inequalities `a_i(s)+t*b_i(s)>=0`. The projection set consists of each coefficient and every pair determinant `a_i*b_j-a_j*b_i`. Exact root unions, localized common-root tests and rational interval refinement order all real critical values, including subnative gaps. Strict gaps between event isolators provide interior rational samples. On each open slab, coefficient signs and bound ordering are invariant, so the feasible fiber is empty, a graph or a band. Common factors cancel before endpoint evaluation; compact ruling bounds guarantee finite limits. Exact algebraic comparisons verify each full limit interval lies in the closed endpoint fiber. These incidences certify the connected components. Projection can add extra subdivisions after a coordinate transform; cell counts are not geometric invariants.

| Option | Exact-ruled behavior |
| --- | --- |
| `tolerance`, `parameterTolerance` | Positive native anchor error limits, default `1e-4` and `1e-7`; no root-merging tolerance |
| `parameterBox` | Four nonempty closed normalized uA/vA/uB/vB ranges, default the full domain |
| `linearAxis` | `"U"` or `"V"`; selected axis must have degree one and exactly two controls |
| `maxDepth`, `maxNodes` | `256` (maximum 512) bisections per root and `20000` shared search/refinement nodes |
| `maxIterations` | `24`, range 0–128; extra refinements per native anchor after exact classification |
| `maxControls`, `maxPieces` | `10000` controls per descriptor and `2048` positive profile spans; cyclic conversion retains ordinary validation limits |
| `maxEvents` | `2048`; caps raw isolated roots per span before union and the global event array, including requested endpoints |
| `maxCells`, `maxVertices` | `8192` each; at most two connection records per graph/band cell |
| `maxPolynomialDegree`, `maxExactBits` | `96` (maximum 256) intermediate polynomial degree and `8192` integer arithmetic bits |
| `maxCoefficients`, `maxWork` | `2000000` cumulative polynomial coefficients and `100000000` shared exact arithmetic/search work visits |
| `maxSnapshotEntries` | `4000000`; detached sources/options, maximum nesting 64, cycles rejected before callbacks |
| `requireComplete`, `requireComponents` | Require accurate native anchors and certified parameter components, respectively; component certification holds for every returned report |
| `cancelled`, `checkpoint` | Cancellation and callback errors propagate; checkpoints receive detached stage/work/node/cell/vertex counters |

Work counts include integer arithmetic but are not wall-clock guarantees; validation, table allocation, duplicate detection and sorting have additional overhead. Exact high-degree or ill-conditioned inputs can exhaust hard caps. Tests include 384 independent quadratic-field comparisons, 576 Fraction-clipped fibers across 64 weighted surfaces, shared raw knots, cyclic profiles, near-endpoint roots, extreme scales, source snapshots, resource limits and native conversion. Arbitrary tensor-curved surface pairs remain outside this specialization. Periodic fiber quotients for this ruled/affine family are described next.

### Exact periodic ruled-contact quotient

Set `identifyPeriodicSeams=true` or `requireQuotient=true` with `method="exactRuled"` to identify complete contact fibers at a cyclic profile seam. This supports point contacts, corner contacts, whole seam-contained rulings, branch attachments inside a ruling and coplanar bands. It applies to a `cyclicSurface` first operand with both profile endpoints included in the requested range. Ordinary surfaces and restricted profile ranges retain their original parameter complex; spatial coincidences alone do not enable a seam.

The original `cells`, `events`, `vertices` and `components` remain in the closed four-parameter domain. `periodicQuotient` describes their quotient:

- `axes` records the cyclic profile axis, whether it is `enabled`, and an exact seam identity proof or `restrictedRange` reason. The whole two rational ruling maps must agree at equal normalized ruling parameter. Exact homogeneous polynomial cross products decide this, including nonconstant weight factors for collapsed rulings. Coincident rounded native evaluations cannot substitute for that proof.
- `joins` identifies the entire closed feasible fiber at `firstEvent` and `lastEvent`, using `firstCell`, `lastCell`, `linearRangeExact`, `parameterDimension` and `axis`. Every value of the exact ruling interval is identified with the same value on the other representative. This includes attachment anchors present on only one side; the continuous join is authoritative.
- `components` contains certified connected quotient components with `parameterComponentIndices`, `cellIndices`, `joinIndices` and maximum `parameterDimension`. `componentCount` is also available as top-level `quotientComponentCount`. Original parameter components can merge across a seam; unrelated components remain separate.
- `vertexClasses` groups existing native anchors by exact seam ruling parameter, retaining `vertexIndices`, one `representative` source index, `seam` and optional `linearParameterExact`. `vertexMap` maps each original anchor index to its class. Nonseam anchors have singleton classes. A seam class can also be a singleton when an internal branch attachment was sampled on only one representative; the full fiber join still identifies the corresponding unsampled point on the other side. Original per-corner UV parameters can therefore retain both zero and one at a shared native mesh vertex.

`periodicQuotient.topologyCertified`, `contactsCertified`, `componentsCertified` and top-level `quotientTopologyCertified` certify this exact cell complex with its complete fiber identifications. They do not classify manifoldness or provide ordered path traversal through singularities. Unlike the interval method's ordered-path quotient below, this representation also permits two-dimensional contact bands and seam-contained intervals. `periodicQuotient.complete` and top-level `quotientComplete` additionally require the existing native anchors to meet their error tolerances. Native anchors still provide no whole-curve or whole-band polygonal approximation certificate.

An unequal stored seam returns `reason="seamGeometry"`, an exact nonzero coefficient polynomial in `axes[].identity.difference`, and an `unresolved` entry, with quotient certification false. The original parameter contact certificate remains valid. No quotient is fabricated, even for an empty contact set on such a source. A valid seam with no contacts yields a certified empty quotient. Native accuracy failure instead retains exact quotient topology with `reason="approximation"`. `requireQuotient=true` throws for either incomplete result; `requireComplete` by itself still concerns the original native anchors.

The two seam fibers already own every closed contact at their respective profile boundaries. Exact seam geometry implies equal feasible ruling intervals; these are checked explicitly. Their equal-parameter identification is continuous and covers every possible seam contact. Joining their original components therefore gives the complete connected quotient partition, independently of spatial coincidences elsewhere. No transversality or isolated-endpoint assumption is needed.

All arithmetic, snapshots and cancellation use the original query budgets. Additional hard caps are `maxSeamNodes=20000` for identity-coordinate checks, feasible-fiber joins and seam-anchor scanning, and `maxSeamPairs=100000` for exact anchor ordering/equality comparisons; both accept zero. Exhaustion throws. Checkpoints include `seamGeometry`, `seamComponents` and `seamFinish`, with `seamNodes` and `seamPairs` counters. `Examples.PeriodicRuledContacts` demonstrates a tangent ruling with two original components and one quotient component. Eighteen cases cover independent analytic component counts, corners, bands, whole seam intervals, clipped/restricted domains, weighted raw knots, exact unequal-seam witnesses, degenerate spatial maps, weight gauges, native accuracy, snapshots, limits/cancellation and native seam UV conversion.

## Exact tensor-surface/affine-plane contacts

`SplineQuery.intersectSurfaces(surface, patch, {method="exactTensorPlane"})` extends exact closed-domain classification to a positive rational tensor first surface with arbitrary supported degrees in both directions. Ordinary, unclamped, repeated-knot and unique-periodic descriptors are accepted. The second operand must be an ordinary degree-one 2×2 constant-weight patch whose stored controls form an exact rank-two parallelogram. This method covers tensor/affine-plane pairs; it does not classify every pair of curved surfaces.

```lua
local contacts = E.SplineQuery.intersectSurfaces(surface, planePatch, {
    method = "exactTensorPlane",
    requireComponents = true,
    requireComplete = true,
    identifyPeriodicSeams = true,
})
```

The result retains isolated tangencies, crossing branches, cusps, closed loops, vertical components, boundary and corner contacts, and coplanar regions with curved boundaries. Both original knot directions are supported. `parameterBox` has the same four normalized ranges `{uA,vA,uB,vB}` as other surface queries. Positive weights and the injective affine second patch identify the complete four-parameter contact set with a closed subset of the first surface's parameter rectangle. Dimensions and components refer to that parameter set, even when its spatial image collapses.

### Exact cell representation

`coverageCertified`, `rootCoverageComplete`, `cellTopologyCertified`, `cellDimensionsCertified` and `parameterComponentsCertified` are true on a returned result. Hard proof limits throw. Native anchor accuracy is independent: `complete`, `success` and `converged` require every anchor's position and parameter bounds to satisfy the requested tolerances. An inaccurate anchor appears in `unresolved`, with `reason="approximation"`; `requireComplete=true` throws in that case. No polygonal approximation of the curved contact cells is supplied.

- `spans` is keyed by the original positive tensor-span ordinal; restricted ranges can leave holes. Each record contains original `knotSpans`, two `offset`/`scale` maps, the local rectangular `domain`, exact `homogeneous` powers, affine U/V numerators, positive `weightBounds`, the active `constraints`, a squarefree coprime `basis`, univariate `projection` polynomials and `controlBounds`. A bivariate polynomial is an array of T coefficients, each an array of S coefficients, with both degrees increasing from zero. All scalar coefficients use the exact rational `{sign,n,d}` representation. Control bounds prove any discarded clipping inequalities redundant, or prove the whole span excluded.
- `events` contains every critical local S value and both local domain endpoints. Each event has a `span`, `profile` root record, ordered fiber `roots`, open fiber `sectors`, and `cellIndices`. A root record has `low`, `high`, `exact`, `polynomial` and `coefficientField`. Exact values are specified by `low==high`; otherwise the interval isolates one root. Fiber coefficients in `profileAlgebraic` are fractions `{n,d,sign}` of rational polynomials evaluated at that event's profile root. Their denominators are nonzero at this selected real root; the defining profile polynomial need not be irreducible. Fiber isolator bounds themselves are rational.
- A `fiber` cell owns a closed feasible interval or point at one `event`, with inclusive `rootIndices={lower,upper}` and dimension zero or one. A `graph` or `band` owns the open profile interval between `firstEvent` and `lastEvent`. Its `rootIndices` select the ordered distinct roots of the span's basis union within the local T domain throughout that interval. Equal ordinals define a graph; different ordinals include the full closed interval between two continuous branches. `profileSample` and `sampleRootBounds` record one exact rational sample fiber. These are symbolic branch cells, not line segments.
- `connections` records complete slab-limit intervals and intersections on shared knot edges. `spanJoins` retains both tile representatives and their exact owned contact intervals. Each tile has its own closed chart; shared edges are explicitly identified. `components` gives the complete partition through `cellIndices`, `connectionIndices`, `parameterDimension`, `connected` and `certified`, and every cell has a one-based `component`.
- `vertices` are native samples of feasible critical fiber roots. They have the usual outward `positionBox`, `parameterBox`, `errorBound`, `parameterErrorBound`, `accurate`, optional exact rational coordinates, and `span`/`event`/`root` references. Shared tile anchors remain available in their original charts; `parameterVertexClasses` and `parameterVertexMap` identify equal parameter samples. Continuous joins also cover boundary points that were sampled on only one side.

`parameterTopologyCertified` and `componentTopologyCertified` remain false: this result certifies exact coverage, local cell dimensions, incidences and connected components, not a manifold classification or globally ordered path. `orderComponents` and `requireOrdered` are unsupported for exact cell methods and throw when requested.

### Projection, lifting and endpoint proof

Original stored controls, weights and raw knots are converted directly into homogeneous tensor powers using exact rational Cox–de Boor recurrence. No rounded knot insertion participates. Polynomial content in S accounts for exceptional full fibers. Primitive bivariate polynomials are squarefreed and split into a pairwise-coprime basis by primitive pseudo-remainders. Their coefficients, discriminants and pairwise resultants are projected, using fraction-free Sylvester determinants. Exact root unions partition S into critical events and open intervals. Rational fibers use ordinary Sturm isolation; algebraic event fibers use the ordered coefficient field at the selected profile root. Original sign conditions determine all feasible points and intervals.

A primitive polynomial in rational S coefficients cannot vanish identically in T at an algebraic S event: the event's minimal polynomial would divide every coefficient, contradicting primitive content. Thus every bounded branch endpoint belongs to a finite event-root union. Rational horizontal cuts separate these roots. Interval bounds prove each specialized separator polynomial nonzero in a one-sided S neighborhood. A rational sample in that neighborhood maps every stable branch ordinal to exactly one event-root interval. Compactness and polynomial continuity then force the branch to that root; a band has the full interval between its two limits. Closed sign conditions retain the entire attachment. `spans[i].adjacency` stores the cuts, separator polynomials, proved neighborhoods and sampled root maps. Exact interval intersections and homogeneous boundary identities glue both original knot directions.

The projection approach follows the standard framework described in [Brown's CAD tutorial](https://www.usna.edu/Users/cs/wcbrown/research/qebycad/Tutorial/node6.html). The implementation and the bounded horizontal-separator incidence proof above are specific to this package.

### Periodic tensor contact quotient

`identifyPeriodicSeams=true` or `requireQuotient=true` identifies full seam contact sets in either or both cyclic first-surface directions. An axis is active only when its full normalized range `[0,1]` is requested. Exact homogeneous cross products prove same-parameter boundary identity on every paired seam span. Unequal stored boundaries produce an exact polynomial witness and `periodicQuotient.reason="seamGeometry"`, even when native evaluations coincide; `requireQuotient` throws.

When geometry matches, owned point/open/closed interval contacts identify the complete seam sets. This includes curved boundary contacts, seam-contained intervals, internal attachments, two-axis corner identifications and collapsed spatial images. `periodicQuotient.joins` retains both span and cell representatives with exact varying-parameter intervals and open-end flags. Its `components`, `vertexClasses` and `vertexMap` start from the original parameter identifications and apply all active seam joins transitively. `quotientTopologyCertified` certifies this complete cell-gluing model and component partition; it does not assert that a component is a manifold or supply an ordered curve. `quotientComplete` additionally requires accurate native anchors. Original cells and parameter components are retained.

### Tensor proof limits

Shared defaults are `maxControls=10000`, `maxPieces=2048`, `maxEvents=2048` per root union, `maxCells=8192`, `maxVertices=8192`, `maxNodes=20000`, `maxDepth=256`, `maxIterations=24`, `maxWork=100000000`, `maxCoefficients=2000000`, `maxPolynomialDegree=96` (at most 256), `maxExactBits=8192` and `maxSnapshotEntries=4000000`. The degree cap applies to intermediate projected polynomials as well as source powers; high-degree inputs may exhaust it.

Additional defaults are `maxPolynomials=64` for the coprime basis, `maxMatrixEntries=4096` per Sylvester matrix, `maxLiftedRoots=20000`, `maxConnections=16384`, `maxConnectionPairs=100000`, `maxSeamNodes=20000` and `maxSeamPairs=100000`. Except for the basis size, these additional limits accept zero. Matrix storage and algebraic-field coefficient allocations also consume the shared coefficient budget. Root nodes are shared across rational and algebraic lifting, root comparison, native refinement and endpoint proofs; cells, lifted roots and connections are cumulative across all active spans. Inputs and settings are snapshotted before `checkpoint` or `cancelled` callbacks. Hard limits, cancellation and invalid inputs throw without scene changes or success-returning partial topology.

`TensorPlaneContacts` demonstrates a circular contact across four knot tiles and a corner contact identified through both periodic directions. General curved/curved singular-contact classification remains separate work.

## Exact contacts between two rational ruled surfaces

`SplineQuery.intersectSurfaces(a,b,{method="exactRuledPair"})` accepts two positive rational ruled surfaces. Each operand must have degree one and exactly two controls along its ruling direction. Its profile direction may have arbitrary supported degree, raw unclamped or repeated knots, and unique-periodic controls. `linearAxisA` and `linearAxisB` select `"U"` or `"V"` independently; each defaults to V when eligible, otherwise U. General tensor/tensor pairs require a separate method. All computation is bounded by the exact-arithmetic proof limits.

```lua
local result = E.SplineQuery.intersectSurfaces(firstRuled, secondRuled, {
    method = "exactRuledPair",
    requireComplete = true,
    requireComponents = true,
    identifyPeriodicSeams = true,
})
for _, component in result.components do
    print(component.parameterDimension, #component.cellIndices)
end
```

Parameters remain `{uA,vA,uB,vB}` normalized to the original source domains. `parameterBox` restricts those four domains before solving. Exact endpoint curves are extracted directly from the original stored knots. Original profile knots in either operand have closed representatives with explicit identifications. No mesh approximation or spatial welding participates in classification.

### Convex ruling fibers and connected components

At a fixed pair of profile parameters, each restricted ruling is a line segment. Positive homogeneous endpoint weights give a homeomorphism from its original linear parameter to a Euclidean segment coordinate, denoted alpha or beta. The equality of the two spatial points is three affine equations in alpha and beta, constrained to the unit square. Thus each nonempty fiber is a point, segment or square, including collapsed spatial rulings.

Every nonempty compact polytope has an extreme vertex. The solver enumerates pairs of active world equations and rectangle bounds. Their Cramer determinants, numerators and substituted residuals give an exact Boolean feasibility condition in the two profile parameters. An internal planar sign decomposition isolates the entire feasible base, including closed loops, isolated points, crossings, overlaps and boundaries. The finite certificate represents each ruling fiber as the convex hull of its feasible Cramer vertices. Determinants equal to zero are excluded by their guards, not divided numerically.

The complete four-parameter contact set projects properly onto this base with nonempty connected compact fibers. If a preimage of one connected base component were disconnected, its disjoint compact pieces would project to disjoint closed sets partitioning that base component: a connected fiber cannot meet both pieces. This proves that the complete base-component partition is also the complete four-parameter component partition. Exact rank and active-boundary signs determine fiber dimension on every atomic base sign cell. The maximum of base dimension plus fiber dimension gives each region and component's semialgebraic dimension, from zero through four.

A coarse base cell may contain internal sign changes and different fiber ranks. Its preimage is a `fiberedRegion`, rather than a certified product cell. `baseCellTopologyCertified`, `coverageCertified`, `rootCoverageComplete`, `cellDimensionsCertified` and `parameterComponentsCertified` are true on return. `cellTopologyCertified`, `parameterTopologyCertified` and `componentTopologyCertified` remain false. Base adjacency does not assert that every point in an exceptional full ruling fiber is a limit of every incident region. No global manifold classification or ordered arc traversal is supplied.

### Finite certificate and native anchors

- `profileAxes` and `rulingAxes` give the two operands' global parameter indices. `spans` is keyed by original profile-span-pair ordinal, so restricted ranges may leave holes. Each span records its maps, domain, homogeneous `endpointCurves`, positive `weightBounds`, `rulingRanges`, three affine `equations`, sign basis, projection and endpoint-adjacency evidence. Equation `reduction` records independent homogeneous endpoint scales, cancelled profile divisors, the positive weight products they divide, and final nonzero constant scale. These factors preserve the exact world equalities throughout the supported domains.
- `span.fiber.constraints` contains the three equalities followed by alpha-low, alpha-high, beta-low and beta-high inequalities. Each `case` stores `determinant`, `alpha`, `beta`, its active constraint pair and sign references for determinant and residuals. A reference is a constant sign or an `index` into `signPolynomials` with an `orientation`. A case is feasible when its determinant is nonzero, every equality residual is zero, and every inequality residual times the determinant sign is nonnegative. Its affine vertex is `(alpha/determinant,beta/determinant)`. All bivariate polynomials use increasing partner-profile powers outside and first-profile powers inside; coefficients use the existing exact rational representation.
- `events` contains critical first-profile roots and complete second-profile root/sector records. `slabs` retains ordered roots and sectors at a rational profile sample between two events. Root ordinals select continuous branches across that open slab. Every feasible atomic record includes `fiberDimension`, full `parameterDimension`, `vertexIndices` and its owning coarse `cell`. Root records use the same rational or selected profile-algebraic coefficient fields as the tensor/plane method.
- `cells` contains `fiberedRegion` records with `baseKind`, `baseDimension`, full `parameterDimension`, `fiberDimensionRange`, inclusive `rootIndices`, an `event` or `slab`, and anchor indices. `connections` describes certified base-profile limit incidences and full-fiber identifications on shared original profile knots. `spanJoins` retains complete owned point/open/closed base intervals. `components` supplies the connected partition through cell and connection indices.
- `vertices` samples every feasible atomic representative's extreme ruling vertices. Each has its original four parameters, outward position/parameter boxes, error bounds, exact rational coordinates when available, and `span`, `case`, `base` and `boundaryMask` references. Mask bits 0–3 indicate alpha-low, alpha-high, beta-low and beta-high. `parameterVertexClasses` and `parameterVertexMap` identify matched anchor representatives across original knots; continuous joins cover unsampled boundary points too. Anchors are not a polygonal approximation of the contact set.

For endpoint weights `w0,w1` at a profile value, the normalized position inside the original restricted ruling interval is `xi=alpha*w0/((1-alpha)*w1+alpha*w0)`. Apply its stored interval offset and width to recover the original ruling parameter, and use beta similarly for the second operand. The positive denominators make these maps continuous even for spatially collapsed rulings.

`complete`, `success` and `converged` additionally require every native anchor to meet both spatial and parameter tolerances. Native floating-point precision may prevent this despite an exact complete symbolic classification; the report then has `reason="approximation"` and identifies inaccurate anchors in `unresolved`. `requireComplete` throws in that case.

### Two-operand periodic identification and limits

`identifyPeriodicSeams` or `requireQuotient` activates each cyclic profile direction whose full `[0,1]` range is requested. Exact homogeneous ruling identities prove equal original-parameter boundaries. Complete owned base intervals then identify their entire ruling fibers, with transitive corner identification across both operands. Unequal stored seams return `periodicQuotient.reason="seamGeometry"` with an exact witness; native coincidence is insufficient.

`periodicQuotient.contactsCertified`, `periodicQuotient.componentsCertified` and `quotientComponentsCertified` certify the seam identifications and quotient component partition. `quotientComplete` additionally requires accurate native anchors, and `requireQuotient` throws unless it is true. The original parameter components are retained. `periodicQuotient.topologyCertified` and `quotientTopologyCertified` remain false because a complete four-dimensional cell-complex topology is not asserted. The quotient includes axis metadata, joins, components and matched vertex classes/maps.

This method uses the tensor proof limits above, with `maxPolynomials=128` and an additional `maxFiberPolynomials=1024` per span-pair sign pool. Both accept zero as an explicit disabling budget. Polynomial degree, arithmetic work and cumulative coefficient limits also apply to Cramer construction and intermediate projection polynomials. Generic weighted high-degree pairs can exhaust these limits even with few source controls; exhaustion throws. Known nonvanishing weight factors and homogeneous constant scales are removed exactly to reduce unnecessary arithmetic. Inputs and options are snapshotted before callbacks; cancellation, callback errors and hard-cap failures cannot return a partial success certificate. `RuledPairContacts` demonstrates a curved cylinder loop and a two-dimensional self-overlap.

## Globally ordered intersection paths

Set `orderComponents=true` to attempt validated assembly after the local cover and parameter component analysis. `requireOrdered=true` requests assembly and throws unless every component has a certified topology and an accurate ordered polyline. These options leave the meaning of `complete` and `requireComplete` unchanged: a coarse or exhausted local-chart approximation can coexist with a complete separately sampled ordered path. Conversely, a complete local cover does not imply successful ordering.

```lua
local result = E.SplineQuery.intersectSurfaces(surfaceA, surfaceB, {
    tolerance = 0.002,
    requireOrdered = true,
})
for _, component in result.components do
    local path = component.ordered
    for _, segment in path.segments do
        local first = path.samples[segment.first].position
        local last = path.samples[segment.last].position
        -- Consecutive segments share a sample index, including loop closure.
    end
end
```

`parameterTopologyCertified` and its compatibility alias `componentTopologyCertified` are true only when every parameter component has a certified single traversal. `orderedComplete` additionally requires every ordered approximation to meet tolerance. Both remain false when ordering was not requested. These flags concern the original closed four-dimensional parameter domain named by `componentSpace`. They do not identify periodic seams, weld spatial self-overlaps, certify regular source surfaces, or certify that the world-space image is injective. A cyclic surface can therefore yield an open parameter path whose two endpoints have the same spatial position.

The `ordering` record contains `requested`, `complete`, `reason`, `visited` (ordering refinement/derivative/bridge attempts), `steps`, `segments` and optional `addedCharts`. Without complete component certification it returns `reason="components"` and performs no traversal. Otherwise each component gains `ordered`. A failed topology attempt retains `topologyCertified=false`, `complete=false`, a `reason`, `partialArcCount` and an optional `frontier` containing the current point's `parameterBox`, chart `isolatingBox`, `parameterAxis`, signed `direction` and original `sourceCurve` when available. The complete original root cover remains in `curves`/`unresolved`; a failed traversal is not returned as a completed path.

A certified `ordered` path has:

| Field | Meaning |
| --- | --- |
| `topologyCertified`, `closed` | One simple parameter circle or one parameter interval. `closed` does not classify the spatial image. |
| `complete`, `reason`, `errorBound` | Ordered approximation completion, optional failure reason, and largest whole-chord bound. Missing chords have infinite error. |
| `charts` | Local graph certificates used by traversal, including fresh continuation charts. Each has `parameterAxis`, `parameterRange`, `parameterBox`, `isolatingBox`, `contractionNorm`, `certified`, and an original `sourceCurve` index when applicable. A new chart has a `connection` with `sourceChart`, shared-root `parameterBox`, and `certified=true`. |
| `anchors` | Exact mathematical join points represented by certified root enclosures and native approximations. Each has host `chartIndex`, host `parameterAxis`/`parameter`, four `parameters`, `parameterBox`, `positionBox`, native `position`, both error bounds and accuracy flags. |
| `arcs` | Ordered nonoverlapping parameter pieces, with `chartIndex`, `firstAnchor`, `lastAnchor`, signed `direction`, outer `parameterRange`, `neighborhoods` and `certified=true`. A neighborhood records its restricted `parameterRange`, root `parameterBox` and certificate. |
| `joins` | One per adjacent arc pair, plus closure for a circle. `anchor`, `fromArc`, `toArc`, `fromChart`, `toChart` and an outward `parameterDerivative` certify the shared point and direction. The derivative is of the destination chart's free coordinate with respect to the source chart's free coordinate; its sign matches both arc directions. |
| `samples`, `segments` | One globally ordered native polyline. Each segment has shared `first`/`last` sample indices, its `arc`, outer `parameterRange`, root `parameterBox`, `tangentBox`, `errorBound`, certificate/accuracy flags and optional failure reason. The last segment of a closed path returns to the first sample index; the first point is not duplicated. |
| `endpoints` | For an open path, two indices into `anchors`. Each endpoint has `boundary={axis,side,parameter,certified}`: the exact free parameter lies on the lower (`side=-1`) or upper (`side=1`) requested domain face. This is not a full geometric edge/corner or trim-ownership classification. |

A sample's fixed `parameter` belongs to its host chart, which may differ from the segment's chart. Use the sample's four-coordinate `parameterBox` when changing charts. At a shared root, the new chart's free value is generally enclosed by an interval rather than stored as an exact scalar. `parameterRange` encloses both actual endpoints; it is not a claim that those outer bounds are themselves the arc's exact endpoints. All segment indices are one-based. Distinct parameter points can round to the same native position; no spatial welding is implicit.

The topology proof uses more than atlas adjacency. A parametric Krawczyk graph gives one continuous root for every free value. Along each accepted piece, refined root boxes lie strictly inside all nonglobal dependent domain boundaries. Its strictly ordered endpoint parameters put interior points inside the chart's free range. At a chart endpoint, the adjoining chart supplies the open neighborhood; requested-domain endpoints instead have a one-sided neighborhood. Shared-root inclusion proves exact join identity, and a derivative interval excluding zero proves compatible continuation direction. Fresh bridge charts receive new existence/uniqueness proofs, including image padding when needed. Chart-choice and progress heuristics do not weaken these tests.

For a closed traversal, every earlier piece excludes the exact seed root, and the final return has a certified matching direction. For an open traversal, both directions from the seed terminate at proved parameter-boundary endpoints. The compact path image has a full relative root-set neighborhood at every interior/join point and the appropriate half-neighborhood at its ends. It is therefore both open and closed in its already certified connected component, so it covers that entire component. Local orientation and the first-return test prevent multiple traversal. This argument permits C0 knots through interval bounds on the one-sided jets; it does not resolve singular or branching regions that lack the required graph neighborhoods.

Sampling reuses each exact anchor identity across adjacent arcs. A chord between uncertain free endpoints still has actual parameter width at most the outer interval width. The same `h/4` derivative-width bound described above, plus native endpoint errors, therefore bounds the complete intervening arc. Subdivision chooses a new exact free value strictly between the endpoint enclosures. When a path is complete, its maximum chord bound bounds the whole native polyline against the exact parameterized component. Extra client arithmetic/rendering error remains additional.

| Ordering option | Default / behavior |
| --- | --- |
| `orderComponents` | `false`; attempt global parameter traversal and a separate native polyline |
| `requireOrdered` | `false`; implies ordering and throws on incomplete topology or approximation |
| `maxOrderNodes` | `10000`, shared point/range restriction, derivative and bridge attempts; zero allowed |
| `maxOrderSteps` | `1024`, traversal steps including bridge retries, shared across components; zero allowed |
| `maxOrderDepth` | `24`, neighborhood proof and ordered chord subdivision depth, at most 128; zero allowed |
| `maxOrderedSegments` | `8192`, total ordered chords, independent of local `maxSegments`; zero allowed |

Ordering limits retain explicit failures; `maxWork` still bounds the complete query and throws on exhaustion. Checkpoints include `order` and `orderSample`, plus `orderNodes`, `orderSteps` and `orderedSegments` counters during ordering work. High-degree multiple-loop queries can need a larger work budget than the default. The exact nested quartic-circle regression uses `maxWork=200000000`, with a 2,000-node root search and 0.01 chord tolerance. `Examples.OrderedIntersectionLoop` shows a closed result. Tests independently verify winding once around each analytic loop, open endpoints, chord interiors, rational and C0 curves, transformed geometry, parameter seams, precision floors, limits/cancellation, source snapshots and native mesh conversion.

## Periodic seam quotient

This section describes the default interval method's ordered-path quotient. The exact ruled-contact method above uses full closed fiber identifications and also supports seam-contained intervals, corners and bands.

`identifyPeriodicSeams=true` requests ordering followed by exact seam identification. `requireQuotient=true` requests the same work and throws unless the resulting quotient topology and native polyline are complete. The existing `parameterComponentsCertified`, `parameterTopologyCertified`, `orderedComplete`, `componentCount`, `components`, `complete` and their strict options retain their original closed-rectangle meanings. The quotient is a separate result: `quotientTopologyCertified`, `quotientComplete` and `periodicQuotient`. These flags are false when identification was not requested.

```lua
local result = E.SplineQuery.intersectSurfaces(periodicSurface, plane, {
    tolerance = 0.005,
    requireQuotient = true,
})
for _, path in result.periodicQuotient.paths do
    -- A circle shares its last segment's last index with its first segment.
    for _, segment in path.segments do
        local a = path.samples[segment.first].position
        local b = path.samples[segment.last].position
    end
end
```

Only a cyclic direction whose requested range is exactly `{0,1}` participates. A restricted range keeps its own boundary; no wrap is inferred across missing parts of the source domain. Ordinary NURBS descriptors do not acquire periodicity merely because their endpoints appear coincident.

The implementation first proves a sufficient **exact C0 boundary identity for the expanded stored-knot model**. Repeated degree-one endpoint controls and weights supply this identity for arbitrary valid positive intervals. For higher degrees, repeated homogeneous controls and exact period translation of the local knot neighborhoods supply it. Knot differences are compared using error-free sum expansions, rather than rounded difference equality. This comparison requires nonzero raw knot magnitudes between `2^-900` and `2^900`, keeping all possible expansion residuals normal under Studio's flush-to-zero behavior. These fast tests are sufficient shortcuts. If they fail, an exact rational boundary-curve comparison now decides whether the stored model really has the same boundary at both parameter ends. No positional tolerance relaxes seam identity. The [B-spline control-wrapping construction](https://pages.mtu.edu/~shene/COURSES/cs3621/NOTES/spline/B-spline/bspline-curve-closed.html) describes the underlying basis relationship; this implementation additionally checks the actual stored knots. Common weight scaling and native control transforms preserve repeated-control identities.

The fallback evaluates the end-direction B-spline basis exactly and obtains two positive homogeneous boundary curves. In every span of the other direction, it constructs their normalized power-basis coefficients and checks all coefficients of `H0[k] * H1[w] - H1[k] * H0[w]`, for each spatial coordinate. Vanishing of these cross-product polynomials is necessary and sufficient for equality at the same boundary parameter, including cases with a nonconstant homogeneous weight factor. It is not a test for coincidence after an arbitrary reparameterization. A single unequal coefficient proves that the stored model is not exactly closed; matching native endpoint evaluations cannot override that result.

The private rational core decodes finite float64 inputs from their stored bits, including subnormal bit patterns, and uses signed integer limbs in base `2^24`. Integer products and carries stay exactly representable in binary64. Rational normalization, addition, multiplication, division and equality therefore incur no floating-point uncertainty. The spline query's existing input restrictions still apply before this fallback. `maxExactBits` defaults to `8192` and caps integer intermediates, including conservative temporary bounds. Bit or shared work exhaustion throws; it never certifies approximate equality. The fallback is bounded but can cost more than the structural shortcuts, particularly at high degree or with unrelated knot denominators.

An axis proved by the fallback has `reason="exactBoundaryCurveIdentity"` and `identity={certified=true,equal=true,checkedSpans=...}`. A disproved identity retains the original shortcut failure reason for compatibility and adds `identity={certified=true,equal=false,reason="differentBoundaryCurves",span,axis,coefficient,checkedSpans}`. Here `span` is the one-based raw knot-span index, `axis` is the spatial coordinate and `coefficient` is the one-based normalized power coefficient. The axis's top-level `certified` remains false because the periodic seam is not equal. Shortcut proofs do not need the optional `identity` record. Extreme but valid raw-knot scales can now pass through this fallback even when the expansion-based translation shortcut cannot be used.


In particular, nonuniform floating-point interval accumulation need not produce exact translated knots. A cyclic descriptor with such higher-degree knots is not silently welded. Each `axes` record gives `axis` (1–4), `enabled`, `certified` and `reason`: `repeatedEndpointControls`, `exactKnotTranslation`, `restrictedRange`, `storedKnotsNotExactTranslates`, `knotExponentRange` or `controlIdentity`. The empty root set has a trivially complete quotient even if an otherwise unused seam identity is unavailable.

Once the original parameter topology is certified, every path is checked for seam contacts. Refined graph enclosures must stay strictly inside all participating periodic coordinates, except a proved original path endpoint whose graph's free coordinate is that seam coordinate. Strict monotonicity of the free coordinate then excludes any additional contact along that arc. Uncertain dependent-coordinate contact triggers bounded graph refinement. Consequently this solver handles isolated transverse endpoint crossings; a curve contained in a seam, a tangential seam touch, or a simultaneous corner contact can remain unresolved either in the original root search or in this contact check.

For each accepted seam endpoint, its exact boundary coordinate is changed from zero to one or vice versa. Exact C0 seam equality guarantees that the translated parameter point is still a root. Containing that entire translated root enclosure inside the counterpart's isolating domain identifies the points by the counterpart graph's uniqueness at the same free value. Overlapping boxes, close native positions and spatial self-intersections never suffice. The certified original partition and single traversal make distinct endpoints distinct in the rectangle, so a successful counterpart is unique. Every periodic endpoint must have its proved counterpart before quotient paths are returned.

The resulting endpoint graph has degree two at every seam join and degree one at retained nonperiodic boundaries. Following its edges yields one interval or circle per quotient component, using every original component once. Two disconnected rectangle components can become one open path, or a rectangle interval can become a circle. Different parameter branches at coincident spatial positions remain different; a single quotient circle may wind more than once around its spatial image. Topology here is in the **parameter quotient**, not the world-space image. No surface regularity, spatial injectivity, normal continuity, singular contact multiplicity or trim ownership is claimed.

`periodicQuotient` contains:

| Field | Meaning |
| --- | --- |
| `requested`, `topologyCertified`, `complete`, `reason` | Separate quotient request, topology and approximation status. Failure reasons include `parameterTopology`, `seamGeometry`, `seamContact`, `endpointIdentity`, `nodes`, `pairs` and `approximation`. |
| `axes`, `contactsCertified` | Geometry certificates above, and whether all path contacts satisfy the isolated-endpoint condition. |
| `nodes`, `pairs` | Contact/refinement visits and endpoint comparisons, including comparisons filtered by axis, side or existing pairing. |
| `joins` | Proved identities with `fromComponent`, `fromEndpoint`, `toComponent`, `toEndpoint`, `axis`, signed integer `shift`, translated root `parameterBox`, `targetChart` and `certified=true`. Endpoint numbers are 1 or 2 in the original ordered path. The witness box is in the target's parameter representation. |
| `unresolved`, optional `frontier` | Failed contact/identity locations or the first unexamined endpoint comparison. All original root covers and ordered paths remain available. |
| `paths`, `componentCount` | Complete quotient topology, available only after all identities and contact exclusions succeed. `componentCount` is the number of quotient paths and is independent of the original count. |

Each quotient path has `topologyCertified=true`, `closed`, `sections`, `seamJoins`, `complete`, `reason`, `errorBound`, `samples` and `segments`. A section references the original `componentIndex` and traversal `direction` (`1` or `-1`). Its original ordered path retains all chart, arc, parameter and derivative certificates. `seamJoins` records directed component/endpoint pairs, the directed `shift`, `axis`, and a `proof` index into `periodicQuotient.joins`; that identity witness can have the opposite orientation. Open paths also have two `endpoints`, each referencing an original component and endpoint number.

Quotient samples have native `position`, `positionBox`, `errorBound`, `certified`, `accurate` and `sources`. Every source is `{componentIndex,sampleIndex}` into an original ordered path. A shared seam vertex keeps **both parameter representations** in this list; there is no averaged seam UV. A segment has shared `first`/`last` sample indices, `sourceComponent`, `sourceSegment`, traversal `direction`, `errorBound`, `endpointDisplacementBound`, `certified` and `accurate`. Its source segment supplies the original parameter range and graph bounds. Reversing a section reverses segment order and endpoint indices without changing those source ranges.

At a seam, a canonical existing native endpoint replaces its equivalent counterpart. The outward distance between the old and new native points bounds the change of every point on an adjacent chord. Adding the larger of the two endpoint displacements to the original chord bound preserves the whole-arc guarantee. This can make an otherwise accurate source approximation exceed tolerance; topology remains certified but `complete=false` with `reason="seamApproximation"`. If any section's ordered approximation was already incomplete, the quotient retains its topology/sections with `reason="sourceApproximation"`, infinite error and empty sample/segment arrays. The original partial approximations remain accessible. The quotient never invents missing chords or resamples beyond the ordered segment budget.

| Quotient option | Default / behavior |
| --- | --- |
| `identifyPeriodicSeams` | `false`; implies original parameter ordering |
| `requireQuotient` | `false`; implies seam identification and throws on incomplete quotient topology or approximation |
| `maxSeamNodes` | `10000`, contact visits, fresh source-chart reconstructions and interval restrictions; zero allowed |
| `maxSeamPairs` | `100000`, endpoint comparisons; zero allowed |
| `maxSeamDepth` | `24`, contact-exclusion subdivision depth, at most 128; zero allowed |
| `maxExactBits` | `8192`, positive hard cap on exact rational integer intermediates for boundary identity |

All stages share the query's hard `maxWork`, immutable source/options snapshots, and cancellation contract. Checkpoints add `seamGeometry`, `seamIdentity`, `seamContacts`, `seamPairs` and `seamSample`, with `seamNodes`/`seamPairs` counters. Output copies at most the existing ordered samples and chords, with shared seam vertices; original graph and ordered-output limits still apply. Counted work is a deterministic arithmetic/visit budget, not a wall-clock guarantee. `Examples.PeriodicIntersectionLoop` constructs a mesh boundary from the quotient while retaining both source seam parameters. Tests cover 320 independent exact arithmetic operations, 96 stored-bit float64 inputs, 32 pointwise de Boor boundary references, independent winding/chord checks, rational and doubly periodic geometry, disconnected and coincident branches, restricted domains, native meshes, transforms, weight gauges, source snapshots, budgets and cancellation.

## Adaptive surface tessellation

`SurfaceAdaptive.bound(surface)` accepts exactly one Bezier patch and returns `errorBound`, `rationalDeviation` and `twist`. `SurfaceAdaptive.tessellate(surface,options)` first extracts Bezier patches, then subdivides patches whose bounds exceed tolerance. It returns `(mesh,report)` with `converged`, `errorBound`, `leaves`, `refinements`, `triangles`, `poles` and an optional nonconvergence `reason`.

For a rational patch S=H/W and its corner bilinear patch B, the algorithm constructs Bernstein coefficients of H-W*B in degree (p+1,q+1). Their maximum norm divided by the minimum positive weight bounds |S-B|. Let this bound be R, and let T be the length of the bilinear twist vector P00-P10+P11-P01. A parameter triangle whose vertices lie on S has pointwise linear-interpolation error at most 2R+T/4: R bounds S-B, another R bounds interpolated vertex deviations, and T/4 bounds the bilinear interpolation term. This covers interior points, not only edge and center samples.

Accepted patch boundaries collect every neighboring split parameter, including across the original Bezier spans. A center fan triangulates each conforming boundary. Adjacent leaves therefore share geometric vertices even when their subdivision depths differ; per-corner UVs and analytic normals retain seams. The bound applies to this triangle interpolation. The conservative test can produce more triangles than a heuristic screen-error sampler, especially with uneven weights or nonlinear parameterization of a flat patch.

Options:

| Option | Default and behavior |
| --- | --- |
| `tolerance` | 0.01, positive authoring-space approximation tolerance |
| `maxLeaves` | 10,000; bounds accepted plus pending patches |
| `maxDepth` | 16, permitted range 0–24 |
| `maxVertices` | 100,000; exceeding it throws |
| `maxTriangles` | 200,000; exceeding it throws |
| `material` | Face material slot |
| `closedU`, `closedV` | Explicit seam closure; opposite boundaries must coincide |
| `collapsePoles` | Explicit boundary pole collapse, as in uniform NURBS tessellation |
| `seamTolerance` | 1e-6 authoring units; increase when native coordinate rounding requires it |
| `checkpoint` | Receives `{stage="refine",leaves,refinements}` or `{stage="mesh",progress}`; may yield or throw |

Depth or leaf limits return a valid partial mesh with `converged=false`; the reported error is the actual largest remaining geometric bound. Invalid topology, unmatched seams, unresolved interior singularities, and allocation budgets throw. No scene instances are created before these checks. Pole normals use regular interior limits, as documented in [SURFACES.md](SURFACES.md). Closed-direction edge splits are synchronized before meshing. Position callbacks are intentionally excluded because arbitrary displacement would invalidate the bound.

```lua
local mesh, report = E.SurfaceAdaptive.tessellate(surface, {
    tolerance=0.03, closedV=true, collapsePoles=true,
})
assert(report.converged and mesh:validate().closed)
```

Explicit UV trimming and bounded adaptive trim meshes, including periodic seam synchronization and pole collapse, are available through [SurfaceTrim](TRIMMING.md). Arc-length inversion is covered in [CURVE_EDITING.md](CURVE_EDITING.md), constrained joins in [SURFACES.md](SURFACES.md), and nonlinear fitting in [SPLINE_FITTING.md](SPLINE_FITTING.md). Exact isolated-endpoint periodic quotient and validated regular parameter ordering are available above. Single affine patches now have exact closed-domain contact/overlap cells through `method="exactAffine"`. General curved singular/boundary/overlap cases and periodic seam-contained/corner contacts remain open. Stored seam equality now has an exact rational decision within hard arithmetic/work limits; genuinely unequal stored boundaries remain ineligible for a periodic quotient. The adaptive-mesh Bernstein bounds describe the rational control-net model; their floating-point extraction, subdivision and evaluation incur native-coordinate roundoff and are not outward-rounded interval certificates. Tolerances below native spatial precision may be unsuitable. An approximation bound does not certify visual realism or prevent folds caused by the input control net. Regression tests cover between-sample errors, exact circles and primitive projections, multiple local minima, tilted boundaries, scale and common-weight invariance, translated control nets, unequal subdivision depths, seam/pole topology, allocation limits, cancellation and native EditableMesh round trips.


## Two curved tensor graphs with a common affine projection

`SplineQuery.intersectSurfaces(a,b,{method="exactGraphPair"})` accepts two ordinary positive rational tensor surfaces whose projections along `graphDirection` are exact affine maps of their normalized parameters. `graphDirection` is a finite nonzero `Vector3`, defaulting to world Z. Both projected maps must have rank two and retain the same affine coefficients across every original knot span. Degrees, positive weights, raw/unclamped knots and repeated internal knots may differ between operands. Stored projection identities are checked exactly; an approximately affine control lattice rejects.

```lua
local contacts = E.SplineQuery.intersectSurfaces(firstGraph, secondGraph, {
    method = "exactGraphPair",
    graphDirection = Vector3.zAxis,
    requireComplete = true,
})
for _, component in contacts.components do
    print(component.parameterDimension, component.cellIndices)
end
```

Both surfaces can curve in both parameter directions. The method retains isolated interior tangencies, singular and tangent crossing curves, closed loops, closed boundary/corner contacts and two-dimensional curved overlap. It does not require either operand to be affine or ruled. It does require the common affine projection: general tensor pairs without that property remain outside this method. Unique-periodic descriptors reject; a globally affine projected chart of rank two cannot identify an entire opposite parameter edge with the same projected geometry. The other exact methods retain their documented periodic capabilities.

### Exact reduction and original knot ownership

Choose a nonzero component `d[k]` of the direction. The two linear projected coordinates are `d[k]*X[i]-d[i]*X[k]`, for `i` different from `k`. For each original span, the method extracts exact homogeneous powers from the stored controls and weights. It derives a candidate affine projected map and verifies the polynomial identity `projectedNumerator = weight * affineParameterMap`. Local coefficients are converted to normalized full-source parameters and checked across all original spans.

The inverse of B's rank-two affine map then gives one exact affine correspondence `(uB,vB) = M*(uA,vA)+c`. Under this correspondence, equality of the remaining world coordinate is equivalent to equality of the full 3D positions. For each original span pair, clearing its strictly positive weights produces one exact bivariate height-difference polynomial.

A **single global planar decomposition** classifies the Boolean union of all closed span-pair conditions: both source span domains, the requested second-operand parameter ranges, and zero height difference. The requested first-operand ranges bound the base domain. Original internal knots therefore have one base parameter owner, including oblique second-operand knot lines; no duplicate local complexes need to be joined. Validated ordinary NURBS internal knot multiplicities ensure continuity. The affine correspondence is a homeomorphism between this closed base contact set and the full four-dimensional parameter contact set, so the exact planar incidence proves its component partition and dimensions.

`parameterBox` retains the usual four normalized ranges. All four source parameters remain available at native anchors, even when the projected maps differ, reverse orientation or shear. Native anchors use the exact active span-pair guards, rational interval evaluation and shared algebraic-root refinement. The same native `tolerance` and `parameterTolerance` rules apply; topology certification remains separate from native approximation accuracy. The anchors do not form an ordered polyline or a tessellation of an overlap.

### Finite reports and limits

The report uses the existing exact-cell `events`, `cells`, `connections`, `components`, `vertices`, `parameterVertexClasses` and `parameterVertexMap` fields. `baseComplex` contains the one planar decomposition, including its sign-measure constraints, projection polynomials, root-ordinal data and adjacency witnesses. Cells, events and vertices identify `complex=1`. `sourceSpans[1]` and `[2]` retain original homogeneous powers, original knot indices and affine local maps, composed base-coordinate powers, positive weight bounds and `baseGuards`. `spanPairs` retains the source span indices, exact `heightPolynomial` and its normalized sign reference. `domainGuards` describes the second operand's requested parameter bounds. The sign-measure constraints are combined by these guarded span-pair alternatives; they are not all conjoined.

`projection` records the direction, dropped coordinate, two source affine forms, rank and exact certification. `parameterMap` stores two rows `{constant,uAcoefficient,vAcoefficient}` for B's parameters. Each vertex has `spanPair` identifying its active source formula. Component dimensions and cell ownership refer to the full four-parameter set, using the proved affine correspondence.

`coverageCertified`, `rootCoverageComplete`, `cellTopologyCertified`, `cellDimensionsCertified` and `parameterComponentsCertified` are true after the exact decomposition succeeds. The broader `parameterTopologyCertified` and `componentTopologyCertified` remain false. `complete` additionally requires every reported native anchor to meet its position and parameter error limits; `requireComplete` enforces that condition. `requireComponents` is satisfied by the exact component partition. Ordered-arc options reject. For these ordinary domains, requesting periodic identification returns the identity quotient, with no active periodic axes; `requireQuotient` still requires native accuracy.

The tensor/plane exact arithmetic, snapshot, root, cell, connection and native-anchor limits apply. `maxPieces=2048` also caps the number of original span pairs. `maxGraphPolynomials=1024` bounds pooled sign-measure constraints; `maxPolynomials=64` separately bounds the derived bivariate basis. Generic high-degree pairs can exhaust these explicit symbolic limits and raise an error. Inputs and options are snapshotted before callbacks, and cancellation propagates at entry, during arithmetic and before completion.

Twenty-five added tests include 752 independent Fraction evaluations with unrelated positive weights, affine shears and a non-axis-aligned projection direction; analytic polynomial and rational loops, tangencies, singular crossings, interior and boundary points, curved overlap, raw unclamped domains with 81 span pairs, reversed parameters, exact-identity rejection, finite certificates, snapshots, proof limits and native anchor/UV conversion. `GraphSurfaceContacts` demonstrates a closed loop between two curved tensor graphs.

## Exact general tensor pairs

`SplineQuery.intersectSurfaces(a,b,{method="exactTensorPair"})` accepts any two ordinary or unique-periodic positive rational tensor surfaces supported by the package. Neither operand needs an affine projection, a regular Jacobian, nor a noncollapsed image. Original degrees, weights, raw/unclamped knots and repeated knot boundaries are retained. The bounded exact solver either returns a complete parameter contact decomposition or throws when its proof resources are exhausted. Periodic descriptors expand their stored knot/control data exactly; optional complete seam identification is described below.

```lua
local contact = E.SplineQuery.intersectSurfaces(a, b, {
    method = "exactTensorPair",
    parameterOrder = {3, 4, 1, 2},
    requireComplete = true,
})
for _, component in contact.components do
    print(component.parameterDimension, #component.cellIndices)
end
```

The parameter axes are always `(uA,vA,uB,vB)` in native anchors and `parameterBox`. `parameterOrder` chooses their cylindrical decomposition order, a permutation of `{1,2,3,4}`; the default is that natural order. Choosing the least expensive order can greatly reduce work without changing the contact set. `GeneralTensorContacts` demonstrates a closed nonlinear contact loop with irrational boundary parameters.

Each original homogeneous span pair supplies the three exact equations `HA.xyz*HB.w-HB.xyz*HA.w=0`, closed original-span guards, and the requested closed domain guards. Strictly positive weights make these equations equivalent to positional equality. Exact polynomial row rewrites preserve the equation ideal and retain quotient witnesses. A global Boolean union of all span pairs gives each contact cell one deterministic source owner, including shared original knots. No native resampling, degree fitting or tolerance welding changes these equations.

The solver uses a sign-invariant cylindrical algebraic decomposition (CAD) of the four parameter axes. The guarded projection uses primitive coprime squarefree factors, coefficients, discriminants and pair resultants. Intermediate nullification triggers a full Collins projection restart, including every reductum and principal subresultant coefficient; the retry remains charged to the shared work and allocation budgets. `cadProjection="full"` requests this full projection from the start. The projection constructions follow the full/reduced operators described in [England, *An implementation of CAD in Maple*, §2](https://arxiv.org/pdf/1302.6401).

Derivative sign labels distinguish every sibling cell via Thom encodings; see [Coste and Roy, *Thom's lemma, the coding of real algebraic numbers and the computation of the topology of semi-algebraic sets*](https://www.sciencedirect.com/science/article/pii/S0747717188800087). Algebraic tower coefficients use exact Sturm–Tarski sign queries rather than relying on repeated interval refinement. Modular inverses localize a reducible defining polynomial only after proving that the discarded factor excludes the chosen root. The signed-remainder identity is the Sturm–Tarski theorem in [Li, Passmore and Paulson, *Deciding Univariate Polynomial Problems Using Untrusted Certificates in Isabelle/HOL*, §5](https://api.repository.cam.ac.uk/server/api/core/bitstreams/04ac96fb-1984-4894-9a4f-2c97f71aa636/content).

Connected components require actual closure incidence. Simply changing strict inequalities to weak inequalities is incorrect: the closure of `x>0, x²<z<2x², xy=z` at `x=z=0` only contains `y=0`, although the weakened inequalities admit arbitrary `y`. For cells C and D the general decision is `exists x in D: for every epsilon in (0,1]: exists y in C: |x-y|² < epsilon²`. Exact rational graph elimination reduces this formula when its denominator is nonzero near the target. Cartesian or planar closure decisions apply only after their hypotheses are proved. A positive-dimensional target's sample can prove a positive incidence; an unsuccessful sample requires the full target-cell decision. Joining all proved incidences partitions the closed contact set into connected components. The report retains both successful joins and separation decisions.

The returned contract is:

- `coverageCertified`, `rootCoverageComplete`, `cellTopologyCertified`, `cellDimensionsCertified` and `parameterComponentsCertified` are true. Each `cells[]` item has a cylindrical cell `node`, `parameterDimension` from zero through four, one `component`, one `spanPair`, and one `anchorVertex`.
- `components[]` gives `cellIndices`, `connectionIndices`, `parameterDimension`, `connected=true` and `certified=true`. `connections[]` references exact closure proofs. A cell is connected; no full adjacency graph, component manifold type, arc order or triangulation is asserted. `parameterTopologyCertified` and `componentTopologyCertified` remain false, and ordering requests reject.
- `decomposition` contains finite projection polynomials, sign labels, algebraic root stacks and nodes. `constraints`, `domain`, `sourceSpans`, `spanPairs`, `proofs` and `pairAudit` retain original homogeneous data, equation rewrites and closure evidence. Nested algebraic coefficients explicitly encode numerators, denominators and field depth. These are data records without solver closures or cyclic tables.
- `vertices[]` are bounded sample anchors, not a polygonal approximation. Each retains all four original normalized parameters, a native position, outward parameter/position errors and `accurate`. Exact interval evaluation encloses both original homogeneous surfaces. `complete`, `success` and `converged` require every anchor to meet the requested tolerances; otherwise `reason="approximation"` and `unresolved` identifies the inaccurate anchors while the exact contact certificate remains valid. `requireComplete` throws on this failure.
- On ordinary descriptors, `identifyPeriodicSeams` or `requireQuotient` returns the identity quotient with no seam axes. Periodic descriptors use exact boundary transport as described below. Native anchor inaccuracy keeps `quotientComplete=false`; `requireQuotient` then throws. Different parameter components are not merged merely because their spatial images coincide.

The shared exact-query tolerances, snapshots, cancellation and budgets above apply. General-specific settings are `maxGeneralPolynomials=1024`, `maxProjectionPolynomials=256`, `maxProjectionCandidates=4096`, `maxGcdCache=10000`, `maxMatrixEntries=4096`, `maxLiftedRoots=20000`, and `maxComponentPairs=65536`. `maxCells=8192` bounds each CAD's cell allocation; shared `maxWork=100000000`, `maxCoefficients=2000000`, root-node and lifted-root budgets also cover nested closure decisions and full-projection retries. `maxEquationPasses=64` and `maxEquationRewrites=1024` bound optional exact equation simplification; their exhaustion is an explicit error. `maxPolynomials=256` bounds each planar closure helper. All limits are positive integers. CAD can be expensive even at moderate degree; budget exhaustion returns no certificate. Internal quantifier, projection and closure controls cannot be supplied as public options.

Independent fixtures cover 51 principal subresultant minors, 81 multivariate GCD identities, 157 algebraic signs including a cancellation below 10^-80, and 2,304 original homogeneous span evaluations. Analytic surface cases cover separate curves, a nonlinear loop, a tangent point, no contact, independently weighted curved overlap, original knot crossings, restricted domains, invertible affine transforms, and collapsed contacts of dimensions three and four. Additional cases verify full/guarded projection, parameter permutations, native accuracy, snapshots, cancellation, limits and finite evidence.

### Bernstein boundary reduction and general periodic quotients

Before four-parameter projection, the method converts each original span's homogeneous powers to its exact tensor Bernstein coefficients. On the relative interior of a cube face, every supported Bernstein basis function is strictly positive. Therefore a one-sign polynomial vanishes on that face precisely when every supported coefficient is zero. The maximal zero faces give an exact union of endpoint constraints. A span pair with an impossible one-sign equality can be excluded immediately. When all its equalities are one-sign or identically zero, the boundary union replaces them. Other pairs retain their original equation ideal, which can be cheaper than partially applying the restrictions. `spanPairs[].signProof` records coefficients, degrees, zero faces and whether the reduction was applied; `remainingCoordinates` and `alternatives` record the actual constraints. This resolves boundary-only contacts such as sixteen periodic corner points without a large interior arrangement. All allocations and arithmetic remain charged to the shared budgets.

`identifyPeriodicSeams=true` and `requireQuotient=true` now work on either or both periodic axes of both operands. An axis is enabled only when its requested parameter range includes both 0 and 1. Each enabled axis first checks exact homogeneous equality between its original first/last span boundaries, across every tile in the other parameter direction. Native endpoint coincidence is insufficient. An unequal stored boundary returns `periodicQuotient.reason="seamGeometry"`, a nonzero polynomial witness and false quotient certification, including for an empty contact set. The original parameter decomposition remains certified. Restricted axes retain disabled metadata with `reason="restrictedRange"`.

For a valid seam, changing its parameter from 0 to 1 maps every lower-side boundary cell continuously into the contact set. A cylindrical cell is connected, so its entire image lies in one already-certified parameter component. The solver transports an exact algebraic sample and evaluates the original CAD sign labels to locate that component. Doing this for every lower-side boundary cell proves all component joins, including seam-contained curves, tangencies, overlaps, singular attachments and corners. Repeating the operation across all enabled axes gives the complete quotient partition. A seam cell's image need not be one CAD cell; the proof concerns its connected component. No sample-to-sample proximity inference is used.

The quotient reports `contactsCertified=true`, `componentsCertified=true`, `componentCount`, `components[].parameterComponentIndices`/`cellIndices`, and `joins[]` with exact sign-transport evidence. `quotientComponentsCertified=true` exposes the component result at the report root. General periodic `topologyCertified`/`quotientTopologyCertified` remain false: a full quotient incidence complex, manifold type, arc ordering and tessellation are not asserted. On ordinary inputs the identity-quotient topology flag remains true for compatibility.

`vertexClasses` and `vertexMap` partition existing exact sample anchors under all endpoint flips. The method enumerates at most sixteen representatives per four-parameter anchor, locates each representative's owning cell, and tests an exact formula fixing that cell's sector samples. Those formulas express nested algebraic coordinates through their original tower roots and rational functions. Nearby unequal points remain distinct, and spatially collapsed surfaces retain their distinct parameter samples. All original UV representatives and native positions remain in `vertices`; no new approximation is substituted. `vertexProofs` retains the exact equality evidence. Native approximation failure keeps the exact component and anchor-class certificates but sets `quotientComplete=false` with `reason="approximation"`.

`maxSeamNodes=20000` and `maxSeamPairs=100000` bound seam identities, transports and anchor comparisons, in addition to the shared exact-query limits. Dense collapsed periodic domains may need a larger `maxComponentPairs` because their original knot boundaries produce many parameter cells. `PeriodicTensorContacts` demonstrates a biquadratic seam curve and a separate curved contact. Regression cases include all four periodic axes, sixteen periodic corners, quadratic tangencies, weighted anchor errors, unequal rounded seams, restrictions, nested radical anchor comparisons and 3,888 independent Fraction contact references.
