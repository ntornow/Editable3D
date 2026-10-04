# Transform constraints and dual-quaternion skinning

`E.Constraints` evaluates ordered **rigid CFrame transforms** as data. No Instances or engine constraint objects are created. It does not implement scale/shear constraints, Blender's complete constraint modes, drivers, or its dependency graph. This defined subset is usable for rigs, aiming, procedural assemblies and reference camera controls.

## Direct operators

Every operator returns a CFrame and leaves inputs unchanged. Angles are radians. `options.influence` defaults to 1 and lies in `[0,1]`; intermediate influence uses CFrame translation/rotation interpolation.

| Function | Options and semantics |
|---|---|
| `copyLocation(owner,target,options?)` | Target is a CFrame or Vector3. `axes={X=true,...}` selects components; omitted axes table means all. `invert` negates selected target components. `offset` is a Vector3 added after selection. Rotation stays unchanged. |
| `copyRotation(owner,target,options?)` | Target is a CFrame. `mix="REPLACE"`, `"BEFORE"` (target*owner) or `"AFTER"` (owner*target). Optional `axes`/`invert` operate on XYZ Euler components. In additive composition, unselected target components are zero. Position stays unchanged. |
| `copyTransform(owner,target,options?)` | Replace with `target * offset`, where optional offset is a CFrame. |
| `limitLocation(owner,options?)` | Optional Vector3 `min` and `max`; clamp position components. |
| `limitRotation(owner,options?)` | Optional Vector3 `min` and `max`; clamp the CFrame's XYZ Euler decomposition. Bounds do not wrap. This has the usual Euler branch/gimbal ambiguity and is not a swing/twist angular limit. |
| `limitDistance(owner,target,options?)` | Nonnegative `distance`; mode `"SURFACE"`, `"INSIDE"` or `"OUTSIDE"`. Coincident points use the owner's right vector or an explicit nonzero Vector3 `fallback`. |
| `floor(owner,options?)` | Keep position above a plane. Vector3 `normal` defaults +Y, `point` defaults origin; numeric `offset` is distance along the unit normal. |
| `trackTo(owner,target,options?)` | Aim local `trackAxis` (default `"-Z"`) at target, with local `upAxis` (default `"Y"`) aligned to the projected world `up` vector. Signed axis names ±X/±Y/±Z are supported and must be perpendicular. A deterministic perpendicular is used at an up singularity. |
| `dampedTrack(owner,target,options?)` | Minimal rotation aligning `trackAxis` to target while retaining the remaining orientation as much as possible. Antipodal alignment uses a deterministic perpendicular axis. No time damping is implied by the name. |
| `lockedTrack(owner,target,options?)` | Rotate only about the owner's local `lockAxis` (default Y), preserving that world axis. Aim the perpendicular `trackAxis` (default -Z) toward the target projected into its plane. A target on the lock axis leaves the transform unchanged. |
| `followPath(owner,path,factor,options?)` | Sample a `Stroke.path` by `factor * path.length`. Optional `pathFrame` maps its points/tangents to the desired space. Align with `trackTo` unless `followRotation=false`; then apply optional CFrame `offset`. Open paths clamp and closed paths wrap. This is not a spline IK solver or parallel-transport roll solver. |
| `setInverse(targetRest)` | Return the inverse rest-target CFrame. |
| `childOf(owner,target,options?)` | Return `target * inverse * owner` before influence mixing. Supplying `inverse=setInverse(targetRest)` prevents a jump at that target's rest pose. |

## Ordered stacks and dependency graph

```lua
local result = E.Constraints.evaluate({
    target = {localFrame=CFrame.new(2, 3, -4)},
    parent = {localFrame=CFrame.new(10, 0, 0)},
    camera = {parent="parent", localFrame=CFrame.new(0, 2, 8), constraints={
        {type="TRACK_TO", target="target", trackAxis="-Z", upAxis="Y"},
        {type="FLOOR", normal=Vector3.yAxis, offset=0.5},
    }},
})
local cameraWorld = result.world.camera
```

Node IDs are uniformly strings or numbers; each node has optional `parent`, `localFrame` and `constraints`. `evaluate(nodes,pose?)` returns `{world,localFrames,order}`. A pose overrides selected node local frames. The sorted traversal recursively evaluates parent and target dependencies and rejects cycles or missing nodes. Stacks run in order. `muted=true` and zero-influence constraints are skipped, including their dependency edges. Unknown types reject.

Constraint `space` is `WORLD` by default, or `LOCAL` relative to the owner's evaluated parent. `target` may be a node ID, fixed CFrame, or a Vector3 for position-only operators. For node targets, `targetSpace` selects their evaluated `WORLD` or `LOCAL` transform. These two choices expose numeric frames deliberately: using a local target with a world owner does not automatically convert between their parents. Use matching spaces or a converted fixed target when that conversion is intended. A FOLLOW_PATH target is a CFrame/node used as its path frame; `factor` and `path` belong to that constraint record.

Stack type names: `COPY_LOCATION`, `COPY_ROTATION`, `COPY_TRANSFORM`, `LIMIT_LOCATION`, `LIMIT_ROTATION`, `LIMIT_DISTANCE`, `FLOOR`, `TRACK_TO`, `DAMPED_TRACK`, `LOCKED_TRACK`, `FOLLOW_PATH`, `CHILD_OF`. Their remaining fields match the direct operator options.

`Constraints.rig(rig,pose?,stacks?)` adapts `Rig` bone IDs, parents and bind-local frames to this evaluator. It returns `(localPose,result)`, usable by `rig:worldTransforms`, `rig:skin`, or `rig:skinDualQuaternion`. `stacks` maps bone IDs to constraint arrays. It does not create Blender pose-bone constraints or native Roblox constraints.

## Dual-quaternion skinning

`rig:skinDualQuaternion(mesh,pose?,options?)` returns a new mesh and `{weightedVertices,method="dualQuaternion"}`. It blends each bone's `posedWorld * inverse(bindWorld)` as a dual quaternion, aligns signs to the largest-weight influence, normalizes the real component and enforces real/dual orthogonality. Finite nonnegative weights need not sum to one. Unweighted vertices remain unchanged.

Corner normals/tangents are rotated by the blended rigid transform. Optional `recalculateNormals=true` recalculates surface normals with `normalAngle`; otherwise existing corner discontinuities survive. The original mesh, weights and rig are unchanged. Bone transforms are CFrames, so scale/shear and two-phase scaled dual-quaternion skinning are outside this implementation. Dual-quaternion blending can produce bulging and shortest-path rotation artifacts; it does not guarantee anatomical deformation quality or match Roblox's native skinning.

The implementation is original Luau. Mathematical reference: [Kavan et al., Geometric Skinning with Approximate Dual Quaternion Blending](https://users.cs.utah.edu/~ladislav/kavan08geometric/kavan08geometric.html). No reference source code or example meshes were copied. Constraint concepts are described in the [Blender constraint manual](https://docs.blender.org/manual/en/4.3/animation/constraints/index.html); this API's coordinate and mixing contracts above are explicit and narrower.

`ConstraintTests` includes independent expected transforms, all six signed track axes, antipodes, oblique plane limits, child-of rest preservation, stack ordering/local-world conversion, dependency cycles, a rig bridge, a twist radius/volume comparison against linear skinning, and bind/normal/hemisphere/translation checks. `ConstrainedRig` is a callable example with no scene mutation.
