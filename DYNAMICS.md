# Convex collision and rigid-body dynamics

`Convex` and `Dynamics` provide a headless collision/physics kernel for reusable authoring workflows. They do not invoke Roblox physics, create instances, download code, or mutate scene objects. The older sphere-based `RigidBody` API remains unchanged.

`Convex` implements incremental 3D hull construction and convex-polyhedron contact manifolds using face-normal and edge-cross separating axes. `Dynamics` implements angular sequential impulses, Coulomb friction, restitution, and a full inertia tensor for each body. These are original Luau implementations; they are not bindings to Blender/Bullet or a claim of full physics-engine parity.

## Geometry and coordinates

A shape has local-space `vertices`, outward planar polygon `faces`, undirected `edges`, local bounds, and an absolute collision `tolerance`. Treat shapes as immutable after construction; several bodies can share one shape. Shapes must be closed, volumetric, convex polyhedra. Concave objects require explicit decomposition into separate convex pieces; this release does not build compound colliders or automatically decompose concavity.

Frames are rigid `CFrame` transforms, without scale. Contact normals point **from A toward B**. Positive penetration is overlap; moving A by `-normal * penetration` or B by `normal * penetration` separates the shapes along the selected axis. For a separated pair, the result supplies a separating-axis gap; **it is not a Euclidean closest-distance query**.

World body `position` is the **center of mass**, and `rotation` is its local-to-world rotation. `world:frame(id)` returns the authoring-shape transform, including its center-of-mass offset. This makes translated/off-center meshes behave correctly without forcing callers to recenter them.

Use one consistent unit system. With geometry in meters, mass in kilograms, and time in seconds, the default gravity is `Vector3.new(0,-9.81,0)`. The modules do not read `workspace.Gravity` or convert between Roblox studs and meters.

## Convex API

| API | Result |
|---|---|
| `Convex.fromMesh(mesh, options?)` | Validates closure, winding, planarity, and convexity; merges coplanar faces into convex planar polygons. Inward-wound meshes are oriented outward. Open, nonplanar, or concave inputs throw errors. |
| `Convex.box(size?)` | Centered box, default full size `(2,2,2)`. Size is not half-extents. |
| `Convex.hull(points, options?)` | Incremental hull of finite `Vector3` points. Removes duplicates/interior points and merges coplanar facets. Rejects coincident, collinear, or coplanar inputs. |
| `Convex.toMesh(shape)` | Produces an original Editable3D authoring mesh, with flat corner normals. |
| `Convex.support(shape, direction, frame?)` | World support point and local vertex-array index in a nonzero direction. Frame defaults to identity. |
| `Convex.bounds(shape, frame?)` | Exact transformed vertex AABB as `lower, upper`. |
| `Convex.massProperties(shape, mass)` | `{volume,mass,center,inertia,inverseInertia}` for uniform volume density. Center and tensors are local-space; tensors are about the center of mass. Mass zero returns zero tensors. |
| `Convex.tensorMultiply(tensor, vector)` | Symmetric tensor-vector multiplication. |
| `Convex.tensorInverse(tensor)` | Inverse of a nonsingular positive-definite inertia tensor. |
| `Convex.contact(shapeA, frameA, shapeB, frameB, options?)` | SAT separation result or a face-clipped/edge contact manifold. Nil frames mean identity. |

Tensors use `{xx,yy,zz,xy,xz,yz}` components, with symmetric off-diagonal entries. Mass properties are derived from signed tetrahedral volume integrals. The integration origin is shifted near the shape to reduce numerical cancellation. Full off-diagonal inertia is retained, including for authoring meshes rotated relative to their local axes.

Collision results:

```lua
-- separated:
{ overlap = false, normal = Vector3, separation = number, axisCount = number }
-- overlapping or touching within tolerance:
{
    overlap = true, normal = Vector3, penetration = number,
    feature = "face" or "edge", axisCount = number,
    contacts = {
        { position = Vector3, pointA = Vector3, pointB = Vector3, penetration = number },
        -- up to maxContacts
    },
}
```

`pointA` and `pointB` are corresponding shape surface points; `position` is their midpoint, used as the common impulse application point. Faces are clipped against reference side planes. Edge-axis contacts use closest points on the supporting edge pair. Duplicate contacts are removed; manifolds larger than the configured budget retain the deepest contact followed by spatially spread points.

Tolerances and budgets:

- Construction `tolerance` defaults to `max(boundsDiagonal,1) * 1e-6` in local units. Hull construction defaults to `maxPoints=512` and `maxFaces=4096`. Increasing those budgets raises computational cost.
- `contact` defaults to the larger shape tolerance, `parallelTolerance=1e-6`, `maxAxes=100000`, and `maxContacts=4`. `parallelTolerance` is the magnitude threshold for nearly parallel edge cross products, approximately an angular threshold in radians.
- Touching/slightly separated shapes within tolerance are reported as contact with nonnegative penetration. This numerical convention must be considered when building exact intersection classifiers.
- Budget exhaustion, invalid geometry, or failure to construct a manifold produces an explicit error. No “success” result is returned for an uncomputed contact. Very thin, nearly parallel, or large-coordinate geometry may require deliberate tolerance choices and rescaling. Roblox `Vector3`/`CFrame` precision limits apply.

## Dynamics API

```lua
local E = require(game.ReplicatedStorage.Editable3D)
local world = E.Dynamics.new({ gravity = Vector3.new(0,-9.81,0) })
local floor = world:addBox(Vector3.new(20,1,20), 0, CFrame.new(0,-0.5,0))
local box = world:addBox(Vector3.one, 2, CFrame.new(0,3,0), {
    friction = 0.6, restitution = 0.2,
})
world:impulse(box, Vector3.new(1,0,0), Vector3.new(0,3.4,0))
for _ = 1, 120 do
    world:step(1/60, { substeps = 4, velocityIterations = 20 })
end
local authoringFrame = world:frame(box)
-- Apply that transform to your authoring mesh or native part explicitly.
```

| API | Behavior |
|---|---|
| `Dynamics.new(options?)` | Creates a world with stable monotonically allocated body IDs. Stores default stepping/collision options. |
| `world:addConvex(shape, mass, frame?, options?)` | Adds an immutable convex shape and returns its ID. Mass zero is static; positive mass is dynamic. |
| `world:addBox(size, mass, frame?, options?)` | Convenience construction using `Convex.box`. |
| `world:remove(id)` | Removes an existing body; unknown IDs are errors. |
| `world:frame(id)` | Current authoring-shape world frame. |
| `world:setFrame(id, frame)` | Teleports the authoring shape while preserving velocities. |
| `world:impulse(id, impulse, worldPoint?)` | Instant linear impulse and its off-center angular impulse. Without point, acts through the center of mass. Static bodies ignore it. |
| `world:angularImpulse(id, impulse)` | Instant world angular impulse. |
| `world:force(id, force, worldPoint?)` | Accumulates a force and optional off-center torque for the next entire `step`. |
| `world:torque(id, torque)` | Accumulates world torque for the next entire `step`. |
| `world:velocityAt(id, worldPoint)` | Linear plus angular velocity at a world point. |
| `world:momentum()` | Total linear momentum and total angular momentum about world origin. |
| `world:energy()` | Kinetic, gravitational potential, and total energy diagnostic. |
| `world:collisions(options?)` | Current manifolds tagged with `bodyA`, `bodyB`; static-static pairs are skipped. |
| `world:step(dt, options?)` | Advances fixed substeps; returns a report. Forces/torques clear after the whole step, not after each substep. |

Per-body options: `friction=0.5`, `restitution=0`, `linearDamping=0`, `angularDamping=0`, and arbitrary `userData`. Restitution must lie in `[0,1]`; friction and damping are finite nonnegative numbers. Bodies are exposed in `world.bodies[id]`; their `velocity` and `angularVelocity` are world-space `Vector3` values. Keep static-body velocities zero. Do not directly alter shape, mass, center, or tensors after construction; remove/recreate the body for those changes.

Step/default-world options:

| Option | Default | Meaning |
|---|---:|---|
| `substeps` | 4 | Equal subdivisions of the requested `dt`. |
| `velocityIterations` | 12 | Sequential normal/friction impulse passes per substep. |
| `positionIterations` | 4 | Separate overlap-correction passes per substep; zero disables correction. |
| `restitutionThreshold` | 0.5 | Closing speed below which contact is inelastic, to reduce resting jitter. |
| `slop` | 0.0005 | Allowed penetration in world units. |
| `positionCorrection` | 0.4 | Fractional correction strength in `(0,1]`. |
| `maxCorrection` | 0.2 | Caps per-contact penetration error before correction scaling. |
| `maxSubsteps` | 1024 | Explicit execution budget. Velocity/position iterations each cap at 1000. |
| `tolerance`, `parallelTolerance`, `maxAxes`, `maxContacts` | See above | Forwarded to convex contact generation. |
| `filter(idA,idB,bodyA,bodyB)` | nil | Pure callback returning false to exclude a pair; may be called multiple times per step. |

`step` reports substeps, iteration counts, accumulated contact-point count, and maximum pre-correction penetration encountered. `world.time` advances by `dt`. `world.lastContacts` describes the final substep's contacts before position correction and includes solved normal/tangent impulses. Use `collisions()` for a fresh post-correction query. Explicit options passed to `collisions()` replace its default collision options; options passed to `step()` override stored defaults.

## Solver behavior and limits

Broad phase checks transformed AABBs over sorted body pairs. Narrow phase builds convex SAT manifolds. The velocity solver accumulates nonnegative normal impulses and clamps the accumulated two-component friction impulse to a Coulomb disk. It retains the tangent effective-mass cross term. Friction combines as the geometric mean; restitution combines as the larger coefficient. Restitution targets are computed from pre-solve velocities once per substep, rather than repeatedly adding bounce energy.

World inertia is rotated from the full local tensor. Free rotation uses a fixed-count midpoint orientation estimate and retains world angular momentum across orientation updates. Applied torques change momentum before the rotation update. Contact impulses change both linear/angular velocities. Positional correction moves and rotates bodies separately without injecting a penetration-correction velocity. As with other discrete iterative solvers, this is approximate; positional correction and finite iterations do not guarantee exact conservation during sustained contact.

The tests cover exact analytic box mass/inertia, rotated tensors, hull topology, separation/containment/touching, face and edge contacts, random transformed contact symmetry and surface-point containment, off-center impulses, torque-free angular momentum/energy, force lifetime, elastic impacts, resting stability, friction, and deterministic three-box stacks. Determinism means identical inputs and iteration order in the same runtime; it does not promise bitwise equality across hardware/runtime versions.

Current limits: convex polyhedra only; no spheres/capsules in this solver (use the separate `RigidBody` API for spheres), concave triangle meshes, compound colliders, collision margins, automatic decomposition, GJK/EPA distance queries, continuous collision detection, speculative contacts, kinematic bodies, joints, motors, sleeping/islands, rolling friction, persistent cross-step warm starting, parallel/GPU execution, or broad-phase tree. Discrete time steps can tunnel through thin obstacles at high speed. Many-body cost is quadratic before narrow-phase work; use modest collision hulls and explicit substeps. Large stacks and extreme mass ratios may require more iterations and are not certified by the small-stack tests. There is no guarantee of numerical matching with Roblox physics or Blender's rigid-body system.

`examples/ConvexStack.luau` simulates three boxes and an original wedge hull, returning a world, collision meshes, and a sampled transform trajectory. It performs no scene mutations.

## Primary references

These references informed mathematical conventions and solver structure; their implementations are not embedded or downloaded into this package:

- [Erin Catto: Sequential Impulses, GDC 2006](https://box2d.org/files/ErinCatto_SequentialImpulses_GDC2006.pdf) — accumulated contact impulses, clipping, friction, and stabilization principles. Our solver implements three-dimensional contacts and full tensors.
- [Box2D simulation documentation](https://box2d.org/documentation/md_simulation.html) — force/impulse semantics, coefficient mixing, substeps, and limitations of iterative restitution.
- [dyn4j: Contact Points Using Clipping](https://dyn4j.org/2011/11/contact-points-using-clipping/) — reference/incident feature clipping principles, generalized here to three-dimensional polygon faces.
- [Brian Mirtich: Computing Polyhedral Mass Properties](https://people.eecs.berkeley.edu/~jfc/mirtich/massProps.html) — volume-based mass, center, and inertia concepts. This implementation instead directly integrates signed tetrahedra with a shifted origin.
- [Real-Time Collision Detection, author’s contents](https://realtimecollisiondetection.net/books/rtcd/toc/) — convex polyhedra, separating-axis tests, and closest-segment geometric primitives.
