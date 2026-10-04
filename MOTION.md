# Motion, shape keys and curve sculpting

These are reusable headless APIs. They do not start a clock, animate Instances, publish assets, or modify the current place when required. They implement defined algorithms rather than Blender's complete animation/constraint catalog.

## Quaternion

`E.Quaternion` uses four-number arrays `{x, y, z, w}` and Hamilton multiplication: `multiply(a,b)` applies `b` first. It provides normalization, conjugate/inverse, CFrame and axis-angle conversion, vector rotation, shortest-arc SLERP, SQUAD, rotation vectors, and angular-velocity integration. `integrate(q, omega, dt, localSpace?)` takes radians per second. World angular velocity is the default; `localSpace=true` right-multiplies the increment. Translation is supplied separately to `toCFrame(q, position?)`. `identity` is a frozen constant; functions return new arrays.

## Timeline

```lua
local T = E.Timeline
local movement = T.channel("translation", {0, 2}, {{0, 0, 0}, {4, 0, 0}}, {
    node = 1, interpolation = "CUBICSPLINE",
    inTangents = {{0, 0, 0}, {0, 0, 0}},
    outTangents = {{2, 0, 0}, {0, 0, 0}},
})
local clip = T.clip({movement}, "Move")
local sampled, effectiveTime = T.sample(clip, 1)
-- sampled[1].translation == {2.5, 0, 0}
```

Paths are `translation`/`scale` (three numbers), `rotation` (unit quaternion), `weights`, or generic `value` (fixed nonempty numeric tuple). Key times must be finite and strictly increasing. `channel` copies and validates inputs. STEP switches at the key itself. LINEAR uses component interpolation except rotation, which uses shortest-arc SLERP. CUBICSPLINE is cubic Hermite with separate incoming/outgoing derivatives per second; segment duration scales those tangents. Rotation cubic interpolation is component Hermite followed by normalization, as in glTF. It does not apply the SLERP antipodal sign correction to cubic keys/tangents. A cubic quaternion curve that reaches zero is undefined and rejects.

`sampleChannel(channel,time)` clamps outside the channel's time range. `clip(channels,name?)` enforces unique node/path pairs and records its time range; omitted channel nodes map to 1. `sample(clip,time,{loop=true,pingPong=true})` returns a node/path/value table and the effective time. Looping is optional and applies to the whole clip range; channels with shorter ranges clamp. Exact loop endpoints wrap to the start. No implicit playback speed or system clock is used.

`layer(baseSample,overlaySample,weight,additive?)` returns a new sample. Override layers interpolate matching paths. Additive translation/weight/value paths add weighted deltas; scale multiplies by an interpolated identity-relative factor; rotation post-multiplies by a quaternion interpolated from identity. Missing paths start from zero, identity scale, or identity rotation. Weight may extrapolate. Supply validated channel samples; this is an explicit layer operator, not Blender NLA strip evaluation.

## Morph

`Morph.fromMeshes(base,target,name?)` requires matching stable vertex IDs and face topology. It returns sparse-compatible data:

```lua
{ name = "Shape", positions = { [vertexId] = Vector3.new(...) },
  corners = { [faceId] = { {normal=delta, uv=delta, color=rgbDelta, alpha=delta}, ... } } }
```

Position/normal/tangent deltas use Vector3; UV deltas use Vector2; RGB color deltas use Vector3, not Color3. `Morph.evaluate(base,targets,weights,options?)` clones the base and adds weighted deltas. Weights are not normalized or clamped and may be negative. Unspecified weights/deltas are zero. Normals/tangents are normalized after accumulation, and colors/alpha are clamped. `options.recalculateNormals=true` recalculates the result's normals, with optional `normalAngle`. Changing topology after constructing targets invalidates their correspondence.

`Morph.transfer(sourceBase,targetBase,target,{maxDistance=...})` uses nearest source triangles and barycentric interpolation to transfer **position deltas only** onto another topology. It returns `(targetDelta, report)`; inspect `maxSourceDistance`. This is geometric nearest-surface transfer, so nearby unrelated surfaces can produce wrong semantic correspondences. It does not infer facial anatomy or transfer corner deltas across UV seams.

The older `Rig.blendShapes` API remains available. The new `Morph` records provide per-corner attributes and glTF interchange. `GLTF.sampleAnimation` returns a pose consumed by `GLTF.meshAt`, which applies morphs before skinning; see [GLTF.md](GLTF.md).

## Stroke

`Stroke.path(points,closed?)` builds an arc-length polyline with an AABB tree over its segments. It ignores zero-length consecutive edges and rejects a path with no length. Input points are copied. `path:sample(arcLength)` returns position and tangent; open paths clamp, closed paths wrap. `path:closest(point,normal?,maxDistance?)` returns position, distance, tangent, segment, segment parameter `t`, arc length, and fraction. A supplied normal defines signed lateral distance using `normal:Cross(tangent)`; the sign is undefined when those vectors are parallel, in which case the implementation reports zero.

`Stroke.profile(distance,radius,kind)` supplies compact-support `ridge`, `crease`, or `fold` profiles. `Stroke.field(path,point,normal,options)` returns value and nearest hit. Options: `radius`, profile name or callback `(normalizedDistance,hit)`, `signedProfile`, `fadeStart`, `fadeEnd`, `width(fraction)` in `(0,1]`, and `amplitude(fraction)`. The field is zero at/outside its support and fades at open endpoints by default. Closed paths do not fade.

`Stroke.sculpt(mesh,path,{radius=1,height=.2,profile="fold",mask=...,direction=...})` displaces a copy and returns `(mesh,report)`. Direction may be a Vector3 or callback `(position,id)`; omitted directions use area-weighted mesh vertex normals. `mask` uses stable vertex IDs with scalar weights in `[0,1]`. The report records affected vertices and maximum displacement. Smooth curves should first be sampled densely from `Curves.catmullRom`/Bezier or another source; the distance geometry is a polyline, not an exact spline. It does not add topology automatically.

## Verification

`MotionTests` checks quaternion transforms against CFrames, angular integration, nearest-curve analytic distances, field support and endpoint fades, masked sculpt immutability, morph deltas/corner attributes and barycentric transfer, cubic time derivatives, layer semantics and malformed input. `GLTFMotionTests` tests independent binary fixtures and evaluated geometry in addition to round trips. These checks do not prove arbitrary-input robustness or full Blender parity.
