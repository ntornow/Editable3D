# Solid Boolean methods and attribute transfer

`Boolean.union(a,b,options)`, `intersect`, `subtract` and `apply(a,b,operation,options)` return a new triangulated mesh and a report. Inputs are unchanged, including on error/cancellation. `method="bsp"` is the default polygon-clipping method. `method="arrangement"` arranges intersecting triangles, classifies both operands' winding regions and audits the resulting boundary. Neither method is an exact algebraic CAD kernel.

```lua
local cut, report = E.Boolean.subtract(body, cutter, {
    method = "arrangement",
    windingRuleA = "nonzero",
    windingRuleB = "nonzero",
    tolerance = 1e-5,
    materialOffsetB = 10,
})
assert(report.complete, report.reason)
```

## Arrangement method

Each operand must have valid, closed, consistently oriented topology, or be empty. Disconnected/nested components and geometrically intersecting sheets are allowed. `windingRuleA` and `windingRuleB` independently select `"nonzero"`, `"positive"` or `"odd"` occupancy. Their fallback is `windingRule`, then `"nonzero"`. A negative winding component occupies space under nonzero occupancy. Opposite nested components make a cavity; identical opposite components cancel. The rules are described in [INTERSECTION_REPAIR.md](INTERSECTION_REPAIR.md).

The method builds one shared intersection arrangement, but counts each operand separately at every winding sample. Union retains `insideA or insideB`; intersection retains `insideA and insideB`; subtraction retains `insideA and not insideB`. Output orientation follows the selected region, including reversed cutter faces in a difference. Coplanar duplicate ownership is deterministic: the lowest joined source triangle wins, so operand A has priority where both supply the same retained surface.

These are regularized volume operations. A face/edge/point-only intersection is empty. A union whose occupied components meet only along a nonmanifold edge or vertex can be unresolved. The algorithm does not invent a bridge or gap to force manifold topology.

Construction, feature snapping, native sliver correction, finite-ray classification and retained-boundary conformity share the repair implementation. `windingPrecision="auto"` first uses native samples, then restarts classification with exact rational samples on recoverable precision failures. `"native"` and `"exact"` force the corresponding path. Two unambiguous rays must agree for each operand at each side sample. Native classification also checks two offset distances; exact classification proves normal-line clearance before sampling. An output scan always runs. `complete=true` requires valid topology, a closed-or-empty result, and a complete native-coordinate audit with no crossings, overlaps or unwelded contacts.

By default an unresolved arrangement Boolean raises an error. `allowInvalid=true` returns the candidate with `complete=false` and a `reason`: `invalid_topology`, `open_boundary`, `incomplete_audit` or `remaining_intersections`. This option does not bypass construction/classification failure or cancellation. `checkIntersections=true` additionally requires each original operand to be intersection-free and refuses unresolved output even with `allowInvalid=true`. Without that option, an operand's intersecting source sheets are interpreted by its winding rule.

All repair limits and precision contracts apply, including `maxExactBits=8192` and `maxExactCoefficients=1000000`. Default `tolerance` is `max(usedVertexExtent*1e-6,1e-7)`. A positive `epsilon` can supply this value for callers sharing Boolean configurations; explicit `tolerance` takes precedence. `maxPolygons` aliases `maxFaces` unless the latter is supplied. `weldEpsilon` and `maxDepth` are BSP-only and reject for the arrangement method. Source `regularization`, winding options, `windingPrecision`, the two exact-arithmetic limits, `tolerance`, `classificationOffset` and `maxRayDirections` reject for the BSP method rather than being silently ignored.

Arrangement calls snapshot both operands and options before input audits or callbacks, using the repair limits `maxSnapshotEntries=4000000` and maximum nesting 64; cyclic data rejects. `cancelled()` is checked through cooperative checkpoints; `checkpoint(record)` receives topology/arrangement/classification progress; `yieldEvery=true` yields at those checkpoints. Construction/classification/reconstruction work, including exact integer operations and any failed native classification attempt, shares the repair work budget. Input/final diagnostic scans retain their own bounded work/test budgets through `intersectionOptions`.

Exact samples can recover sub-resolution side offsets and nearly coincident-layer classification within the arithmetic/work limits. Collapsed native constructions beyond tolerance, ambiguous cut ordering or excessive welding can still reject. Exact sample labels do not prove constant classification throughout a fragment, and a successful native triangulation audit does not prove equality to an exact algebraic solid. The declared approximations, exact-sample reports and measured displacement fields are detailed in the repair guide.

`regularization={method="vertexClusters",distance=d}` optionally moves both joined source operands before arrangement construction and classification. Exact nearest-representative clustering has a certified bound on the changed source surface and rejects uncertified triangle motion. The original attribute maps remain valid. This changes the intended occupied regions and can close gaps or eliminate thin layers; it does not certify equality to the original operands. Representatives use joined stable ID order, so A has priority over B when both contribute possible representatives. See [the source regularization contract](INTERSECTION_REPAIR.md#explicit-source-regularization) for distance limits, reports and conservative rejection. Final output audits remain mandatory.

## BSP method

The default method retains the existing centered polygon BSP clipping, plane tolerance, spatial welding and edge-conforming center fans. Reversed whole-solid winding is normalized by total signed volume; it is not a per-component nesting/winding classifier. Inputs must be closed, valid solids. Empty identities also validate any nonempty operand.

`epsilon` defaults to `max(combinedBoundsDiagonal*1e-6,1e-6)`. `weldEpsilon` defaults to four times epsilon and must be at least epsilon. The clipping limits are `maxWork=2000000`, `maxDepth=256` and `maxPolygons=100000`. `cancelled()` is checked at entry and periodically during clipping; `yieldEvery=true` yields during clipping checkpoints. These limits describe BSP clipping work, not a universal runtime bound for all transfer/validation work.

The result must pass topology validation unless `allowInvalid=true`. Its `complete` field describes valid closed-or-empty topology. A geometric intersection-free claim requires `checkIntersections=true`, which checks both operands and output and rejects any incomplete scan or detected defect. This stronger option is independent of `allowInvalid`.

## Attributes and source maps

Both methods preserve typed sparse vertex, edge, face and corner channels, intrinsic corner fields, materials, skin weights and groups. Same-named channels must have compatible domain, type, interpolation and default schemas; incompatible inputs reject. A channel present on only one operand supplies its default on the other operand. Empty-set results retain the merged schemas.

Vertex and corner channels interpolate through explicit source references using their channel policies. Face channels and material IDs follow the originating source face. Corner interpolation remains local to that face, preserving UV and other seams. Source edge channels follow source edge segments; new cut/triangulation edges use schema defaults. BSP clipping carries references through every intersection and center-fan vertex, rather than reconstructing values by a nearest-surface search.

At welded vertices the BSP method uses the first encountered vertex contributor. It accepts `vertexBlend="first"` and rejects other choices. The arrangement method supports `"first"` or its default `"average"`, averaging one contribution per retained source triangle as in repair. Per-corner seams remain independent of vertex blending. Geometry reversal flips intrinsic normals/tangent signs; typed channels are user data and follow their declared interpolation policy. Arrangement reconstruction recalculates normals; apply the normal/tangent APIs afterward when custom shading is required.

Materials can be numeric IDs or strings. `materialOffsetB` defaults to zero. A nonzero offset requires numeric material IDs on B and shifts them only in the output. It does not modify typed face labels. Native EditableMesh has separate adapter/material-chunk behavior; retaining an authoring material ID is not a claim of native per-face material support.

`report.maps[domain][outputKey]` contains `{joinedSourceKey,weight}` references. `report.inputMaps[domain][joinedSourceKey]` resolves a reference to `{operand="a"|"b", id=originalKey}`. These maps cover vertex, edge, face and corner domains; edge keys use `"minVertex:maxVertex"` and corner keys use `"face:corner"`. Identity fallback is disabled. They support sparse input IDs and remain available for empty-operand identities. First/average interpolation and channel policy determine how multiple references combine.

Every report includes `method`, `operation`, `complete`, `validation`, `empty`, `maps` and `inputMaps`. BSP reports also include its tolerances, clipping `work`, `insertedEdgeVertices`, and optional `inputIntersections`/`intersections`. Arrangement reports include `windingRules`, `arrangement`, `classification`, `conformity`, mandatory final `intersections`, reconstruction counts/maps and `work`; strict per-operand scans appear in `inputIntersections` when requested.

## Verification

The added suite checks analytic spatial/coplanar box volumes, independent rotated-square area formulas, operand identity/reversal, nested winding regions, oriented cavities, self-intersecting operands, regularized contacts, unresolved nonmanifold unions, curved and deterministic oblique volume identities, repeated concave cuts, every typed domain in both methods, corner seams, sparse IDs, missing/incompatible schemas, empty identities, scale/transforms, budgets/cancellation, incomplete final audits and native geometry/UV round trips. `BooleanChannels` is a callable example of audited subtraction with typed vertex/face data.
