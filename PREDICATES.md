# Robust predicates and planar domains

`E.Predicates` uses an ordinary determinant filter, then floating-point expansions when cancellation makes the sign uncertain. The fallback uses error-free sum/product transforms and retains low-order terms rather than comparing a determinant to a modeling epsilon. It is an original Luau implementation, informed by the arithmetic approach described in [Shewchuk's robust-predicate research](https://www.cs.cmu.edu/~quake/robust.html); no third-party implementation was incorporated.

## Predicate contracts

Inputs are finite native `Vector2` or `Vector3` values. Under IEEE binary64 evaluation of the arithmetic, the fallback computes the exact sign for those stored float32 coordinates. This does not recover detail already lost when a Vector2/Vector3 was created. Lua tables with arbitrary double coordinates are deliberately excluded; the native exponent range keeps the degree-five determinant expansion away from binary64 overflow and underflow.

Each determinant predicate returns `(sign,estimate,usedExpansion)`. `sign` is -1, 0 or 1; `estimate` is a rounded determinant value, not an exact magnitude. The Boolean `usedExpansion` exposes whether the filtered fast path was insufficient.

| Function | Positive-sign convention |
| --- | --- |
| `orient2D(a,b,c)` | Counterclockwise triangle / C left of directed AB |
| `orient3D(a,b,c,d)` | The frame (B-A,C-A,D-A) is right-handed |
| `inCircle(a,b,c,d)` | D inside the circumcircle of counterclockwise ABC; sign reverses with triangle orientation |
| `inSphere(a,b,c,d,e)` | E inside the circumsphere of positively oriented ABCD; sign reverses with tetrahedron orientation |

Exact collinearity, coplanarity and cocircularity/cosphericity return zero. Degenerate defining triangles or tetrahedra still yield the algebraic determinant; do not interpret an inside/outside result without first checking their orientation.

`polygonOrientation(points)` returns `(sign,signedArea)` using an expansion sum of the shoelace terms. The area is rounded; the sign retains exact cancellation. Loops must have at least three finite points. This function alone does not certify that a polygon is simple.

`onSegment2D(point,a,b)` uses exact collinearity and inclusive coordinate bounds. `pointInPolygon2D(point,points)` returns `"inside"`, `"outside"` or `"boundary"`, plus the nonzero winding count for interior points. It uses half-open Y crossings and exact orientation signs, without tolerance snapping. Self-intersecting loops follow the nonzero winding rule; use Planar validation before treating them as simple domains.

`intersectSegments2D(a,b,c,d)` returns one of:

- `{kind="none"}`.
- `{kind="point",point,coordinates={x,y},t,u,proper}`. `proper` means both segment interiors cross. Parameters t/u are rounded numbers along AB/CD. `point` is a native Vector2; `coordinates` retain binary64 quotients. Endpoint contacts preserve the original endpoint.
- `{kind="overlap",points={first,last},rangeA={t0,t1},rangeB={u0,u1}}`. Endpoints are lexicographically ordered; parameter ranges may therefore run backward on a reversed segment.

Zero-length segments are supported. Intersection classification uses exact signs; constructed coordinates are rounded. Proper intersections use expansion-based homogeneous coordinate numerators rather than evaluating A+t*(B-A), which can erase a small positional offset when t rounds to one half. Exact signs do not turn all subsequent coordinate construction into exact arithmetic.

## Planar triangulation with holes

`Planar.intersections(loops,options)` returns `(hits,report)`. Each hit identifies `loopA`, `edgeA`, `loopB`, `edgeB` and the segment intersection record. The ordinary shared endpoint of adjacent edges in one loop is omitted; overlapping adjacent edges are reported. `maxIntersections` defaults to 10,000. Reaching it returns a partial list with `report.complete=false` and a reason; a completed search has `complete=true`.

`Planar.triangulate(outer,holes={},options)` accepts one simple outer Vector2 loop and disjoint simple hole loops. A duplicated closing point is removed from the copied input. Consecutive duplicate vertices, intersections, touching boundaries, zero-area loops, outside holes and nested hole loops reject explicitly. Disconnected regions and nested islands require separate domains. Either winding is accepted: output boundaries are normalized to CCW for the exterior and CW for holes.

Visibility-tested bridges connect holes to the current contour. Original ear clipping then triangulates the weakly simple contour. Collinear source vertices are reinserted where a spanning edge would otherwise omit them. The final check requires every original boundary edge with the correct winding, opposite pairs for all internal edges, positive triangle orientation and the expected Euler triangle count. It therefore does not silently return a partially filled hole or an interior crack.

The return value contains copied `points`, `triangles` (three point indices each), `boundaryLoops` (point-index loops), `area` and `holes`. No Steiner points are introduced. `Planar.toMesh(domain,frame=CFrame.identity)` places the triangulation in a frame's XY plane, with source coordinates as UVs and a +Z normal. It creates authoring mesh data, not instances. Extremely thin planar domains may be representable by predicates yet unsuitable for the native mesh validator's geometric tolerances.

Planar operations default to `maxVertices=2000` and `maxWork=5000000`. Exhaustion throws. `checkpoint(progress)` runs every 256 counted intersection/ear work units and may yield or throw; original loops remain intact. Hole bridging and ear clipping are bounded but are not Delaunay triangulation, automatic repair or polygon Boolean operations. `Planar.constrain` adds bounded crossing/overlapping segment arrangements and constrained edge recovery; see [KNIFE_NETWORKS.md](KNIFE_NETWORKS.md). Highly degenerate representable configurations can still fail to find a usable bridge and report that failure explicitly.

## Verification and limits

`tools/predicate_fixtures.py` generates 227 fixtures using independent Python `Fraction` arithmetic. Twenty-four disagree with naive binary64 determinants; the Luau signs match the exact oracle. Tests include exponent limits, orientation conventions, overlap and zero-length segments, cancellation during coordinate construction, thin domains, multiple concave holes, collinear vertices, work limits and cancellation. The fixture source is packaged with the Studio tests; no Python runtime is required by consumers.

The existing BSP Boolean implementation remains tolerance-based. It has not been converted into an exact Boolean kernel merely because these predicates are now available. [INTERSECTIONS.md](INTERSECTIONS.md) documents exact 3D triangle classification, homogeneous constructions and bounded mesh diagnostics. Challenging Boolean construction and intersection repair remain tracked work.
