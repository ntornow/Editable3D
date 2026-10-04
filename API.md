# Editable3D API reference

Public callable signatures for version 0.76.0. See [README.md](README.md) for coordinate, mutation, scope and algorithm contracts.

Typed boundary contracts and resource/publishing options: [PRODUCTION.md](PRODUCTION.md). Development and release workflow: [MAINTAINING.md](MAINTAINING.md).

Constructors use dots (`E.Mesh.new()`); instance methods use colons (`mesh:addVertex(...)`). Ordinary module operators use dots and generally return a new mesh/image.

## ARAP

Source: [src/ARAP.luau](src/ARAP.luau)

- `ARAP.bind(mesh, options)`
- `ARAP:solve(anchors, options)`

## Adaptive

Source: [src/Adaptive.luau](src/Adaptive.luau)

- `Adaptive.refine(mesh, targetLength, options)`
- `Adaptive.remesh(mesh, targetLength, options)`

## Animation

Source: [src/Animation.luau](src/Animation.luau)

- `Animation.track(keys, interpolation)`
- `Animation.sample(track, time)`
- `Animation.evaluate(tracks, time, duration, looped)`
- `Animation.blend(a, b, weight)`
- `Animation.bake(tracks, startTime, endTime, fps)`

## ArcLength

Source: [src/ArcLength.luau](src/ArcLength.luau)

- `ArcLength.prepare(curve, options)`
- `ArcLength.parameter(curve, distance, options)`
- `ArcLength.sample(curve, count, options)`

## Attributes

Source: [src/Attributes.luau](src/Attributes.luau)

- `Attributes.create(mesh, name, domain, dataType, default, interpolation)`
- `Attributes.set(mesh, name, values)`
- `Attributes.get(mesh, name, key)`
- `Attributes.remove(mesh, name)`
- `Attributes.names(mesh, domain)`
- `Attributes.transfer(source, target, maps)`
- `Attributes.convertDomain(mesh, name, domain, options)`
- `Attributes.project(source, target, options)`

## BSDF

Source: [src/BSDF.luau](src/BSDF.luau)

- `BSDF.diffuse(color)`
- `BSDF.ggx(options)`
- `BSDF.metallicRoughness(options)`
- `BSDF.dielectric(ior, tint)`
- `BSDF.mix(a, b, weight)`
- `BSDF.resolve(material, context)`
- `BSDF.fresnelDielectric(cosine, etaI, etaT)`
- `BSDF.fresnelSchlick(cosine, f0)`
- `BSDF.distributionGGX(cosine, alpha)`
- `BSDF.maskingGGX(cosine, alpha)`
- `BSDF.sampleGGX(normal, outgoing, alpha, u, v)`
- `BSDF.evaluate(material, normal, outgoing, incoming)`
- `BSDF.pdf(material, normal, outgoing, incoming)`
- `BSDF.sample(material, normal, outgoing, random, entering)`
- `BSDF.emission(material, context, frontFacing)`

## Bake

Source: [src/Bake.luau](src/Bake.luau)

- `Bake.rasterize(mesh: Mesh, width: number, height: number, shader: (Types.BakeContext) -> (Color3, number?), options: BakeOptions?): (Texture, BakeReport)`
- `Bake.dilate(image: Texture, coverage: buffer, iterations: number, options: Types.Limits?): Texture`
- `Bake.normalMap(low: Mesh, high: Mesh, width: number, height: number, options: BakeOptions?): (Texture, BakeReport)`
- `Bake.ambientOcclusion(mesh: Mesh, width: number, height: number, options: BakeOptions?): (Texture, BakeReport)`
- `Bake.project(mesh: Mesh, texture: Texture, camera: Types.Camera, width: number, height: number, options: BakeOptions?): (Texture, BakeReport)`

## Bezier

Source: [src/Bezier.luau](src/Bezier.luau)

- `Bezier.new(points, options)`
- `Bezier.setPoint(curve, index, position)`
- `Bezier.setMode(curve, index, mode)`
- `Bezier.setHandle(curve, index, side, position)`
- `Bezier.split(curve, segment, t)`
- `Bezier.reverse(curve)`
- `Bezier.toNURBS(curve)`
- `Bezier.evaluate(curve, t)`
- `Bezier.derivatives(curve, t)`

## Boolean

Source: [src/Boolean.luau](src/Boolean.luau)

- `Boolean.apply(a, b, operation, options)`
- `Boolean.union(a, b, options)`
- `Boolean.intersect(a, b, options)`
- `Boolean.subtract(a, b, options)`

## Camera

Source: [src/Camera.luau](src/Camera.luau)

- `Camera.new(frame, fov, width, height)`
- `Camera.project(camera, point)`
- `Camera.ray(camera, pixel)`
- `Camera.compare(camera, landmarks)`
- `Camera.fit(initial, landmarks, options)`

## Conformal

Source: [src/Conformal.luau](src/Conformal.luau)

- `Conformal.lscm(mesh, options)`
- `Conformal.distortion(mesh)`

## Connectivity

Source: [src/Connectivity.luau](src/Connectivity.luau)

- `Connectivity.index(mesh, options)`
- `Connectivity.analyze(mesh, options)`
- `Connectivity.boundaries(mesh, options)`

## Constraints

Source: [src/Constraints.luau](src/Constraints.luau)

- `Constraints.copyLocation(owner, target, options)`
- `Constraints.copyRotation(owner, target, options)`
- `Constraints.copyTransform(owner, target, options)`
- `Constraints.limitLocation(owner, options)`
- `Constraints.limitRotation(owner, options)`
- `Constraints.limitDistance(owner, target, options)`
- `Constraints.floor(owner, options)`
- `Constraints.trackTo(owner, target, options)`
- `Constraints.dampedTrack(owner, target, options)`
- `Constraints.lockedTrack(owner, target, options)`
- `Constraints.followPath(owner, path, factor, options)`
- `Constraints.setInverse(targetRest)`
- `Constraints.childOf(owner, target, options)`
- `Constraints.evaluate(nodes, pose)`
- `Constraints.rig(rig, pose, stacks)`

## Convex

Source: [src/Convex.luau](src/Convex.luau)

- `Convex.fromMesh(mesh, options)`
- `Convex.box(size)`
- `Convex.toMesh(shape)`
- `Convex.hull(points, options)`
- `Convex.support(shape, direction, frame)`
- `Convex.bounds(shape, frame)`
- `Convex.tensorMultiply(t, v)`
- `Convex.tensorInverse(t)`
- `Convex.massProperties(shape, mass)`
- `Convex.contact(shapeA, frameA, shapeB, frameB, options)`

## Curves

Source: [src/Curves.luau](src/Curves.luau)

- `Curves.bezier(points)`
- `Curves.catmullRom(points, closed)`
- `Curves.nurbs(points, degree, knots, weights)`
- `Curves.sample(curve, segments)`
- `Curves.resample(points, count)`
- `Curves.circle(radius, segments)`
- `Curves.loft(rings, caps)`
- `Curves.sweep(profile, path, options)`
- `Curves.lathe(profile, segments)`
- `Curves.bezierSurface(control, uSegments, vSegments)`
- `Curves.stroke2D(points, width, options)`

## Cyclic

Source: [src/Cyclic.luau](src/Cyclic.luau)

- `Cyclic.curve(points, degree, options)`
- `Cyclic.toNURBS(curve)`
- `Cyclic.evaluate(curve, t)`
- `Cyclic.derivatives(curve, t)`
- `Cyclic.rotateSeam(curve, offset)`
- `Cyclic.reverse(curve)`
- `Cyclic.insertKnot(curve, t, count)`
- `Cyclic.surface(control, degreeU, degreeV, options)`
- `Cyclic.surfaceToNURBS(surface)`
- `Cyclic.evaluateSurface(surface, u, v)`
- `Cyclic.surfaceDerivatives(surface, u, v)`
- `Cyclic.insertSurfaceKnot(surface, axis, t, count)`
- `Cyclic.reverseSurface(surface, axis)`
- `Cyclic.rotateSurfaceSeam(surface, axis, offset)`
- `Cyclic.elevateDegree(curve, count, options)`
- `Cyclic.removeKnot(curve, t, count, options)`
- `Cyclic.elevateSurfaceDegree(surface, axis, count, options)`
- `Cyclic.removeSurfaceKnot(surface, axis, t, count, options)`

## Deform

Source: [src/Deform.luau](src/Deform.luau)

- `Deform.masked(mesh, operation, options)`
- `Deform.map(mesh, callback, mask)`
- `Deform.transform(mesh, frame, scale)`
- `Deform.twist(mesh, radians, lo, hi, mask)`
- `Deform.taper(mesh, bottom, top, lo, hi, mask)`
- `Deform.bend(mesh, curvature, mask)`
- `Deform.lattice(mesh, lo, hi, controls, mask)`
- `Deform.shrinkwrap(mesh, target, offset, mask, maxDistance)`
- `Deform.contact(mesh, field, clearance, mask, iterations)`
- `Deform.rbf(mesh, handles, radius, mask)`
- `Deform.simple(mesh, mode, amount, options)`
- `Deform.shear(mesh, factor, options)`
- `Deform.cast(mesh, shape, options)`
- `Deform.warp(mesh, from, to, options)`
- `Deform.taperProfile(mesh, profile, options)`
- `Deform.curve(mesh, curve, options)`

## Dynamics

Source: [src/Dynamics.luau](src/Dynamics.luau)

- `Dynamics.new(options)`
- `Dynamics:addConvex(shape, mass, frame, options)`
- `Dynamics:addBox(size, mass, frame, options)`
- `Dynamics:remove(id)`
- `Dynamics:frame(id)`
- `Dynamics:setFrame(id, frame)`
- `Dynamics:impulse(id, impulse, point)`
- `Dynamics:angularImpulse(id, impulse)`
- `Dynamics:force(id, force, point)`
- `Dynamics:torque(id, torque)`
- `Dynamics:velocityAt(id, point)`
- `Dynamics:momentum()`
- `Dynamics:energy()`
- `Dynamics:collisions(options)`
- `Dynamics:step(dt, options)`

## Fields

Source: [src/Fields.luau](src/Fields.luau)

- `Fields.sphere(center, radius)`
- `Fields.box(center, halfSize)`
- `Fields.capsule(a, b, radius)`
- `Fields.torus(center, major, minor)`
- `Fields.plane(point, normal)`
- `Fields.union(a, b)`
- `Fields.intersect(a, b)`
- `Fields.subtract(a, b)`
- `Fields.smoothUnion(a, b, radius)`
- `Fields.offset(field, amount)`
- `Fields.shell(field, thickness)`
- `Fields.transform(field, frame, scale)`
- `Fields.fromMesh(mesh)`

## Fluid

Source: [src/Fluid.luau](src/Fluid.luau)

- `Fluid.new(options)`
- `Fluid:add(position, velocity)`
- `Fluid:step(dt, substeps)`
- `Fluid:field(radius)`

## GLTF

Source: [src/GLTF.luau](src/GLTF.luau)

- `GLTF.readAccessor(doc, sources, accessorIndex)`
- `GLTF.worldMatrices(scene, pose)`
- `GLTF.sampleAnimation(scene, animationIndex, time, options)`
- `GLTF.fromDocument(doc, sources)`
- `GLTF.fromJSON(json, sources)`
- `GLTF.fromGLB(data, sources)`
- `GLTF.meshAt(scene, nodeIndex, pose)`
- `GLTF.fromMesh(mesh, options)`
- `GLTF.fromRig(mesh, rig, options)`
- `GLTF.toDocument(scene)`
- `GLTF.toJSON(scene, bufferURI)`
- `GLTF.toGLB(scene)`

## Geometry

Source: [src/Geometry.luau](src/Geometry.luau)

- `Geometry.scatter(mesh, count, seed, density)`
- `Geometry.instance(mesh, transforms)`
- `Geometry.assignMaterial(mesh, faces, slot)`
- `Geometry.vertexColors(mesh, field)`
- `Geometry.group(mesh, name, mask)`
- `Geometry.parametric(fn, uSegments, vSegments, wrapU, wrapV)`

## Graph

Source: [src/Graph.luau](src/Graph.luau)

- `Graph.new()`
- `Graph:add(operation, inputs, parameters)`
- `Graph:connect(node, slot, source)`
- `Graph:order(output)`
- `Graph:evaluate(output, context)`

## History

Source: [src/History.luau](src/History.luau)

- `History.new(mesh, limit)`
- `History:current()`
- `History:apply(label, operation)`
- `History:undo()`
- `History:redo()`

## IO

Source: [src/IO.luau](src/IO.luau)

- `IO.toTable(mesh: Mesh): MeshDocument`
- `IO.fromTable(data: MeshDocument): Mesh`
- `IO.encode(mesh: Mesh): string`
- `IO.decode(json: string): Mesh`
- `IO.toOBJ(mesh: Mesh): string`
- `IO.fromOBJ(text: string): Mesh`

## Integrator

Source: [src/Integrator.luau](src/Integrator.luau)

- `Integrator.powerHeuristic(a, b)`
- `Integrator.prepare(mesh, materials, options)`
- `Integrator.trace(scene, origin, direction, options, random)`
- `Integrator.render(mesh, camera, materials, options)`
- `Integrator.toneMap(image, exposure, method)`

## Intersections

Source: [src/Intersections.luau](src/Intersections.luau)

- `Intersections.segmentTriangle(a, b, triangle)`
- `Intersections.triangles(a, b)`
- `Intersections.mesh(mesh, options)`
- `Intersections.between(a, b, options)`

## Jobs

Source: [src/Jobs.luau](src/Jobs.luau)

- `Jobs.start(operation)`
- `Jobs.await(job, timeout)`

## Laplacian

Source: [src/Laplacian.luau](src/Laplacian.luau)

- `Laplacian.bind(mesh, options)`
- `Laplacian:solve(anchors, options)`

## Lighting

Source: [src/Lighting.luau](src/Lighting.luau)

- `Lighting.surface(mesh, hit)`
- `Lighting.point(position, intensity)`
- `Lighting.directional(direction, radiance)`
- `Lighting.environment(source)`
- `Lighting.environmentRadiance(env, direction)`
- `Lighting.environmentPDF(env, direction)`
- `Lighting.sampleEnvironment(env, random)`
- `Lighting.new(mesh, materials, options)`
- `Lighting:environmentRadiance(direction)`
- `Lighting:sample(point, random)`
- `Lighting:pdf(point, direction, hit)`

## Mesh

Source: [src/Mesh.luau](src/Mesh.luau)

- `Mesh.new(): Mesh`
- `Mesh:addVertex(position: Vector3): number`
- `Mesh:addFace(vertices: { number }, corners: { Corner }?, material: number?): number`
- `Mesh:setPosition(id: number, p: Vector3)`
- `Mesh:removeFace(id: number)`
- `Mesh:removeUnused(): Mesh`
- `Mesh:clone(): Mesh`
- `Mesh:bounds(): (Vector3, Vector3)`
- `Mesh:faceNormal(id: number): (Vector3, number)`
- `Mesh:topology(): Types.MeshTopology`
- `Mesh:faceTriangles(fid: number, options: Types.TriangulationOptions?): { { number } }`
- `Mesh:triangles(): { Types.Triangle }`
- `Mesh:volume(origin: Vector3?): number`
- `Mesh:validate(options: Types.ValidateOptions?): Types.ValidationReport`
- `Mesh:recalculateNormals(angle: number?, sharpEdges: { [string]: boolean }?): Mesh`

## MeshEdit

Source: [src/MeshEdit.luau](src/MeshEdit.luau)

- `MeshEdit.bevelEdges(mesh: Mesh, selected: Selection, width: number, options: EditOptions?): (Mesh, EditReport)`
- `MeshEdit.bevelVertices(mesh: Mesh, selected: Selection, width: number, options: EditOptions?): (Mesh, EditReport)`
- `MeshEdit.knife(mesh: Mesh, strokes: { any }, options: EditOptions?): (Mesh, EditReport)`
- `MeshEdit.knifeNetwork(mesh: Mesh, strokes: { any }, options: EditOptions?): (Mesh, EditReport)`
- `MeshEdit.bisect(mesh: Mesh, origin: Vector3, normal: Vector3, options: EditOptions?): (Mesh, EditReport)`
- `MeshEdit.gridFill(mesh: Mesh, boundary: { number }, span: number, options: EditOptions?): (Mesh, EditReport)`
- `MeshEdit.spin(mesh: Mesh, profile: { number }, origin: Vector3, axis: Vector3, angle: number, steps: number, options: EditOptions?): (Mesh, EditReport)`
- `MeshEdit.screw(mesh: Mesh, profile: { number }, origin: Vector3, axis: Vector3, turns: number, pitch: number, steps: number, options: EditOptions?): (Mesh, EditReport)`
- `MeshEdit.insetRegion(mesh: Mesh, selected: Selection, width: number, options: EditOptions?): (Mesh, EditReport)`
- `MeshEdit.extrudeFaces(mesh: Mesh, selected: Selection, distance: number, options: EditOptions?): (Mesh, EditReport)`
- `MeshEdit.poke(mesh: Mesh, selected: Selection, options: PokeOptions?): (Mesh, EditReport)`
- `MeshEdit.loopCut(mesh: Mesh, edgeKey: string, cuts: (number | { number })?, options: EditOptions?): (Mesh, EditReport)`
- `MeshEdit.slideVertices(mesh: Mesh, targets: { [number]: number }, factor: number, options: EditOptions?): (Mesh, EditReport)`
- `MeshEdit.trianglesToQuads(mesh: Mesh, selected: Selection, options: QuadOptions?): (Mesh, EditReport)`

## MeshRepair

Source: [src/MeshRepair.luau](src/MeshRepair.luau)

- `MeshRepair.splitIntersections(mesh, options)`
- `MeshRepair.resolveIntersections(mesh, options)`
- `MeshRepair.clean(mesh, options)`
- `MeshRepair.orient(mesh, options)`

## Modifiers

Source: [src/Modifiers.luau](src/Modifiers.luau)

- `Modifiers.bevel(mesh, width, options)`
- `Modifiers.array(mesh, count, step)`
- `Modifiers.mirror(mesh, axis, weldTolerance)`
- `Modifiers.solidify(mesh, thickness, options)`
- `Modifiers.shell(mesh, thickness, options)`
- `Modifiers.clipPlane(mesh, point, normal, cap, options)`
- `Modifiers.bevelConvex(mesh, width)`
- `Modifiers.stack(mesh, operations)`

## Morph

Source: [src/Morph.luau](src/Morph.luau)

- `Morph.fromMeshes(base, target, name)`
- `Morph.evaluate(base, targets, weights, options)`
- `Morph.transfer(sourceBase, targetBase, target, options)`

## NURBS

Source: [src/NURBS.luau](src/NURBS.luau)

- `NURBS.curve(points, degree, options)`
- `NURBS.surface(control, degreeU, degreeV, options)`
- `NURBS.evaluate(curve, t)`
- `NURBS.derivatives(curve, t)`
- `NURBS.compileCurve(curve)`
- `NURBS.basisWeights(curve, t)`
- `NURBS.clamp(curve)`
- `NURBS.insertKnot(curve, t, count)`
- `NURBS.split(curve, t)`
- `NURBS.reverse(curve)`
- `NURBS.evaluateSurface(surface, u, v)`
- `NURBS.surfaceDerivatives(surface, u, v)`
- `NURBS.compileSurface(surface)`
- `NURBS.clampSurface(surface, axis)`
- `NURBS.insertSurfaceKnot(surface, axis, t, count)`
- `NURBS.splitSurface(surface, axis, t)`
- `NURBS.reverseSurface(surface, axis)`
- `NURBS.isoCurve(surface, axis, t)`
- `NURBS.bezierSegments(curve)`
- `NURBS.bezierPatches(surface)`
- `NURBS.elevateDegree(curve, count)`
- `NURBS.elevateSurfaceDegree(surface, axis, count)`
- `NURBS.removeKnot(curve, t, count, options)`
- `NURBS.removeSurfaceKnot(surface, axis, t, count, options)`
- `NURBS.tessellate(surface, uSegments, vSegments, options)`

## Normals

Source: [src/Normals.luau](src/Normals.luau)

- `Normals.recalculate(mesh: Mesh, options: Options?)`
- `Normals.average(mesh: Mesh, options: Options?)`
- `Normals.set(mesh: Mesh, values: { [any]: Vector3 }, options: Options?)`
- `Normals.direction(mesh: Mesh, direction: Vector3, options: Options?)`
- `Normals.point(mesh: Mesh, target: Vector3, options: Options?)`
- `Normals.rotate(mesh: Mesh, rotation: CFrame, options: Options?)`
- `Normals.flip(mesh: Mesh, options: Options?)`
- `Normals.markSharp(mesh: Mesh, edges: { [string]: boolean }, options: Options?)`
- `Normals.tangents(mesh: Mesh, options: Options?)`

## Particles

Source: [src/Particles.luau](src/Particles.luau)

- `Particles.new(seed)`
- `Particles:emit(count, initializer)`
- `Particles:step(dt, force, drag)`
- `Particles:instances(mesh, scale)`

## PathTrace

Source: [src/PathTrace.luau](src/PathTrace.luau)

- `PathTrace.render(mesh, camera, materials, options)`

## Planar

Source: [src/Planar.luau](src/Planar.luau)

- `Planar.intersections(loops, options)`
- `Planar.triangulate(outer, holes, options)`
- `Planar.toMesh(domain, frame)`
- `Planar.constrain(outer, holes, paths, options)`

## Predicates

Source: [src/Predicates.luau](src/Predicates.luau)

- `Predicates.orient2D(a, b, c)`
- `Predicates.orient3D(a, b, c, d)`
- `Predicates.inCircle(a, b, c, d)`
- `Predicates.inSphere(a, b, c, d, e)`
- `Predicates.polygonOrientation(points)`
- `Predicates.onSegment2D(point, a, b)`
- `Predicates.pointInPolygon2D(point, points)`
- `Predicates.intersectSegments2D(a, b, c, d)`

## Primitives

Source: [src/Primitives.luau](src/Primitives.luau)

- `Primitives.grid(nx: number, nz: number, size: Vector2?): Mesh`
- `Primitives.box(size: Vector3?): Mesh`
- `Primitives.sphere(radius: number?, segments: number?, rings: number?): Mesh`
- `Primitives.cylinder(radius: number?, height: number?, segments: number?, topRadius: number?): Mesh`
- `Primitives.torus(major: number?, minor: number?, segments: number?, sides: number?): Mesh`

## Quaternion

Source: [src/Quaternion.luau](src/Quaternion.luau)

- `Quaternion.new(x, y, z, w)`
- `Quaternion.dot(a, b)`
- `Quaternion.normalize(q)`
- `Quaternion.conjugate(q)`
- `Quaternion.inverse(q)`
- `Quaternion.multiply(a, b)`
- `Quaternion.fromAxisAngle(axis, angle)`
- `Quaternion.toAxisAngle(q)`
- `Quaternion.fromCFrame(cf)`
- `Quaternion.toCFrame(q, position)`
- `Quaternion.rotate(q, v)`
- `Quaternion.slerp(a, b, t)`
- `Quaternion.rotationVector(q)`
- `Quaternion.fromRotationVector(v)`
- `Quaternion.integrate(q, angularVelocity, dt, localSpace)`
- `Quaternion.squad(a, controlA, controlB, b, t)`

## Registration

Source: [src/Registration.luau](src/Registration.luau)

- `Registration.rotation(source, target, options)`
- `Registration.fit(source, target, options)`

## Remesh

Source: [src/Remesh.luau](src/Remesh.luau)

- `Remesh.quads(mesh, targetLength, options)`
- `Remesh.fromField(field, lo, hi, cellSize, options)`
- `Remesh.voxel(mesh, cellSize, options)`
- `Remesh.boolean(a, b, operation, cellSize, options)`

## Render

Source: [src/Render.luau](src/Render.luau)

- `Render.render(mesh, camera, options)`
- `Render.silhouette(mesh, camera)`
- `Render.compareSilhouettes(a, b, threshold)`

## Rig

Source: [src/Rig.luau](src/Rig.luau)

- `Rig.new()`
- `Rig:addBone(name, parentId, bindLocal)`
- `Rig:worldTransforms(pose)`
- `Rig:skin(mesh, pose)`
- `Rig:skinDualQuaternion(mesh, pose, options)`
- `Rig:automaticWeights(mesh, influences, power)`
- `Rig.normalizeWeights(mesh, influences)`
- `Rig.fabrik(points, target, iterations, tolerance)`
- `Rig.blendShapes(base, shapes, weights)`
- `Rig:solveIK(pose, chain, target, options)`

## RigidBody

Source: [src/RigidBody.luau](src/RigidBody.luau)

- `RigidBody.new(options)`
- `RigidBody:addSphere(radius, mass, frame, options)`
- `RigidBody:addCollider(field)`
- `RigidBody:impulse(id, impulse, point)`
- `RigidBody:frame(id)`
- `RigidBody:step(dt, substeps, iterations)`

## Roblox

Source: [src/Roblox.luau](src/Roblox.luau)

- `Roblox.fromEditable(editable: EditableMesh): (Mesh, { [number]: number }, any)`
- `Roblox.partition(mesh: Mesh, triangleLimit: number?): { Chunk }`
- `Roblox.toEditable(mesh: Mesh, options: EditableOptions?): Handle`
- `Roblox.createPart(handle: Handle, options: PartOptions?): MeshPart`
- `Roblox.createBones(handle: Handle): { [any]: Bone }`
- `Roblox.applyPose(handle: Handle, pose: { [any]: CFrame }): Handle`
- `Roblox.update(handle: Handle, mesh: Mesh): Handle`
- `Roblox.refreshCollision(handle: Handle)`
- `Roblox.toModel(mesh: Mesh, options: ModelOptions?): Bundle`
- `Roblox.toEditableImage(texture: Texture, srgb: boolean?): EditableImage`
- `Roblox.fromEditableImage(image: EditableImage, srgb: boolean?): Texture`
- `Roblox.material(maps: MaterialMaps): (SurfaceAppearance, { [string]: EditableImage })`
- `Roblox.applyMaterial(bundle: Bundle, maps: MaterialMaps, slot: number?): { [string]: EditableImage }`
- `Roblox.toTexturedModel(mesh: Mesh, maps: MaterialMaps, options: TexturedModelOptions?): Bundle`
- `Roblox.destroy(bundle: { model: Model?, handles: { Handle }?, images: { EditableImage }? })`
- `Roblox.publish(bundle: Bundle, metadata: unknown, options: Types.PublishOptions?): Types.PublishReport`

## Sculpt

Source: [src/Sculpt.luau](src/Sculpt.luau)

- `Sculpt.stroke(mesh: Mesh, samples: { { [string]: any } }, options: Options?)`
- `Sculpt.brush(mesh: Mesh, center: Vector3, options: Options?)`
- `Sculpt.fair(mesh: Mesh, selection: { [any]: any }?, options: Options?)`
- `Sculpt.move(mesh: Mesh, mask: Mask?, delta: Vector3): Mesh`
- `Sculpt.inflate(mesh: Mesh, mask: Mask?, amount: number): Mesh`
- `Sculpt.flatten(mesh: Mesh, mask: Mask?, point: Vector3, normal: Vector3, strength: number?): Mesh`
- `Sculpt.smooth(mesh: Mesh, mask: Mask?, iterations: number?, options: SmoothOptions?): Mesh`
- `Sculpt.crease(mesh: Mesh, mask: Mask?, point: Vector3, normal: Vector3, width: number, depth: number, pinch: number?): Mesh`
- `Sculpt.displace(mesh: Mesh, field: (position: Vector3, id: number) -> Vector3, mask: Mask?): Mesh`
- `Sculpt.symmetrize(mesh: Mesh, axis: ("X" | "Y" | "Z")?, sourcePositive: boolean?, tolerance: number?): Mesh`

## Selection

Source: [src/Selection.luau](src/Selection.luau)

- `Selection.all(mesh: Mesh): Mask`
- `Selection.sphere(mesh: Mesh, center: Vector3, radius: number, falloff: boolean?): Mask`
- `Selection.box(mesh: Mesh, lo: Vector3, hi: Vector3): Mask`
- `Selection.boundary(mesh: Mesh): Mask`
- `Selection.geodesic(mesh: Mesh, seeds: { [any]: any }, radius: number, options: Options?)`
- `Selection.shortestPath(mesh: Mesh, startId: any, endId: any, options: Options?)`
- `Selection.linked(mesh: Mesh, seeds: { [any]: any }, options: Options?)`
- `Selection.regionBoundary(mesh: Mesh, selected: { [number]: any }, options: Options?)`
- `Selection.edgeLoop(mesh: Mesh, edgeKey: string, options: Options?)`
- `Selection.edgeRing(mesh: Mesh, edgeKey: string, options: Options?)`
- `Selection.faceLoop(mesh: Mesh, edgeKey: string, options: Options?)`
- `Selection.combine(a: Mask, b: Mask, operation: "union" | "intersect" | "subtract"): Mask`
- `Selection.invert(mesh: Mesh, mask: Mask?): Mask`
- `Selection.convertDomain(mesh: Mesh, mask: { [any]: number | boolean }, sourceDomain: string, targetDomain: string, options: Options?)`

## Simplify

Source: [src/Simplify.luau](src/Simplify.luau)

- `Simplify.planar(mesh: Mesh, angleLimit: number, options: Options?)`
- `Simplify.unsubdivide(mesh: Mesh, iterations: number, options: Options?)`
- `Simplify.decimate(mesh: Mesh, targetFaces: number, options: Options?)`

## Simulation

Source: [src/Simulation.luau](src/Simulation.luau)

- `Simulation.new(options)`
- `Simulation:addParticle(position, mass)`
- `Simulation:pin(id, position)`
- `Simulation:addDistance(a, b, compliance, restLength)`
- `Simulation:addVolume(a, b, c, d, compliance)`
- `Simulation:addCollider(field, clearance)`
- `Simulation:step(dt, substeps, iterations)`
- `Simulation.fromMesh(mesh, options)`
- `Simulation:toMesh()`

## Spatial

Source: [src/Spatial.luau](src/Spatial.luau)

- `Spatial.new(mesh)`
- `Spatial:closest(point, maxDistance)`
- `Spatial:raycast(origin, direction, maxDistance)`
- `Spatial:contains(point)`
- `Spatial:signedDistance(point)`
- `Spatial.closestTriangle(point, a, b, c)`

## SplineFit

Source: [src/SplineFit.luau](src/SplineFit.luau)

- `SplineFit.curve(points, degree, controlCount, options)`
- `SplineFit.interpolateCurve(points, degree, options)`
- `SplineFit.surface(grid, degreeU, degreeV, controlsU, controlsV, options)`
- `SplineFit.interpolateSurface(grid, degreeU, degreeV, options)`
- `SplineFit.refineCurve(initial, points, options)`
- `SplineFit.refineSurface(initial, points, options)`

## SplineQuery

Source: [src/SplineQuery.luau](src/SplineQuery.luau)

- `SplineQuery.intersectCurveSurface(curve, surface, options)`
- `SplineQuery.intersectSurfaces(surfaceA, surfaceB, options)`
- `SplineQuery.length(curve, options)`
- `SplineQuery.sample(curve, options)`
- `SplineQuery.closestCurve(curve, point, options)`
- `SplineQuery.closestSurface(surface, point, options)`

## Stroke

Source: [src/Stroke.luau](src/Stroke.luau)

- `Stroke.path(points, closed)`
- `Stroke:closest(point, normal, maxDistance)`
- `Stroke:sample(arc)`
- `Stroke.profile(distance, radius, kind)`
- `Stroke.field(path, point, normal, options)`
- `Stroke.sculpt(mesh, path, options)`

## Subdivision

Source: [src/Subdivision.luau](src/Subdivision.luau)

- `Subdivision.crease(mesh: Mesh, edges: { [string]: number }?, vertices: { [number]: number }?): Mesh`
- `Subdivision.prepareLimit(mesh: Mesh, options: LimitOptions?): any`
- `Subdivision.limit(mesh: Mesh, face: number, u: number, v: number, options: LimitOptions?): any`
- `Subdivision.catmullClark(mesh: Mesh, levels: number?, options: Options?): Mesh`
- `Subdivision.multires(mesh: Mesh, levels: number, options: Options?): Multires`

## SurfaceAdaptive

Source: [src/SurfaceAdaptive.luau](src/SurfaceAdaptive.luau)

- `SurfaceAdaptive.bound(surface)`
- `SurfaceAdaptive.tessellate(surface, options)`

## SurfaceDeform

Source: [src/SurfaceDeform.luau](src/SurfaceDeform.luau)

- `SurfaceDeform.bind(mesh, target, options)`
- `SurfaceDeform:evaluate(target, options)`

## SurfaceEdit

Source: [src/SurfaceEdit.luau](src/SurfaceEdit.luau)

- `SurfaceEdit.select(surface, selector, options)`
- `SurfaceEdit.map(surface, operation, options)`
- `SurfaceEdit.transform(surface, frame, options)`
- `SurfaceEdit.setWeights(surface, values, options)`
- `SurfaceEdit.smooth(surface, iterations, options)`
- `SurfaceEdit.deform(surface, operation, options)`
- `SurfaceEdit.duplicate(surface, uRange, vRange, options)`
- `SurfaceEdit.transpose(surface, options)`
- `SurfaceEdit.setCyclic(surface, axis, enabled, options)`
- `SurfaceEdit.extrude(surface, boundary, steps, operation, options)`
- `SurfaceEdit.split(surface, axis, index, options)`
- `SurfaceEdit.deleteRows(surface, axis, indices, options)`
- `SurfaceEdit.deleteSegments(surface, axis, first, last, options)`
- `SurfaceEdit.boundaryCurve(surface, boundary, options)`
- `SurfaceEdit.spin(surface, boundary, origin, axis, angle, options)`

## SurfaceTrim

Source: [src/SurfaceTrim.luau](src/SurfaceTrim.luau)

- `SurfaceTrim.surface(surface, outer, holes, options)`
- `SurfaceTrim.regions(surface, regions, options)`
- `SurfaceTrim.classify(trimmed, uv)`
- `SurfaceTrim.evaluate(trimmed, u, v)`
- `SurfaceTrim.fromCurves(surface, outerCurve, holeCurves, options)`
- `SurfaceTrim.tessellate(trimmed, options)`
- `SurfaceTrim.adaptive(trimmed, options)`

## Surfaces

Source: [src/Surfaces.luau](src/Surfaces.luau)

- `Surfaces.join(surfaceA, boundaryA, surfaceB, boundaryB, options)`
- `Surfaces.arc(frame, radius, startAngle, endAngle)`
- `Surfaces.compatible(curves, options)`
- `Surfaces.extrude(curve, displacement)`
- `Surfaces.ruled(first, second, options)`
- `Surfaces.loft(sections, degree, options)`
- `Surfaces.revolve(curve, origin, axis, angle, options)`
- `Surfaces.coons(bottom, top, left, right, options)`
- `Surfaces.plane(frame, size)`
- `Surfaces.cylinder(frame, radius, height)`
- `Surfaces.cone(frame, radius, height)`
- `Surfaces.sphere(frame, radius)`
- `Surfaces.torus(frame, majorRadius, minorRadius)`

## Texture

Source: [src/Texture.luau](src/Texture.luau)

- `Texture.new(width: number, height: number, color: Color3?, alpha: number?, options: Limits?): Texture`
- `Texture:set(x: number, y: number, color: Color3, alpha: number?)`
- `Texture:get(x: number, y: number): (Color3, number)`
- `Texture:clone(options: Limits?): Texture`
- `Texture:sample(uv: Vector2, wrap: boolean?, wrapV: boolean?): (Color3, number)`
- `Texture.generate(width: number, height: number, fn: (Vector2, number, number) -> (Color3, number?), options: Limits?): Texture`
- `Texture:map(fn: (Color3, number, Vector2, number, number) -> (Color3, number?), options: Limits?): Texture`
- `Texture:resize(width: number, height: number, options: Limits?): Texture`
- `Texture:blend(other: Texture, opacity: number?, options: Limits?): Texture`
- `Texture:blur(radius: number, sigma: number?, options: Limits?): Texture`
- `Texture:normalFromHeight(strength: number?, options: Limits?): Texture`
- `Texture:paint(center: Vector2, radius: number, color: Color3, opacity: number?, options: Limits?): Texture`
- `Texture:toRGBA8(srgb: boolean?, options: Limits?): buffer`
- `Texture.fromRGBA8(width: number, height: number, bytes: buffer, srgb: boolean?, options: Limits?): Texture`
- `Texture.noise(width: number, height: number, frequency: number?, octaves: number?, seed: number?, options: Limits?): Texture`
- `Texture:tiles(size: number, options: Limits?): { Types.Tile }`

## Timeline

Source: [src/Timeline.luau](src/Timeline.luau)

- `Timeline.channel(path, times, values, options)`
- `Timeline.sampleChannel(channel, time)`
- `Timeline.clip(channels, name)`
- `Timeline.sample(clip, time, options)`
- `Timeline.layer(base, overlay, weight, additive)`

## Topology

Source: [src/Topology.luau](src/Topology.luau)

- `Topology.triangulate(mesh)`
- `Topology.join(meshes)`
- `Topology.extract(mesh, faces)`
- `Topology.components(mesh)`
- `Topology.reverse(mesh)`
- `Topology.weld(mesh, tolerance)`
- `Topology.extrude(mesh, selected, offset)`
- `Topology.insetFaces(mesh, selected, fraction)`
- `Topology.bridge(mesh, loopA, loopB)`
- `Topology.fill(mesh, loop)`
- `Topology.splitEdge(mesh, a, b, t)`
- `Topology.dissolveEdge(mesh, a, b)`

## UV

Source: [src/UV.luau](src/UV.luau)

- `UV.islands(mesh: Mesh, options: UVOptions?): ({ any }, UVReport)`
- `UV.analyze(mesh: Mesh, options: UVOptions?): UVReport`
- `UV.transformIslands(mesh: Mesh, transforms: any, options: UVOptions?): (Mesh, UVReport)`
- `UV.equalizeDensity(mesh: Mesh, options: UVOptions?): (Mesh, UVReport)`
- `UV.packIslands(mesh: Mesh, options: UVOptions?): (Mesh, UVReport)`
- `UV.relax(mesh: Mesh, options: UVOptions?): (Mesh, UVReport)`
- `UV.seamsFromIslands(mesh: Mesh, options: UVOptions?): (Mesh, SeamReport)`
- `UV.planar(mesh: Mesh, frame: CFrame?, scale: Vector2?): Mesh`
- `UV.cylindrical(mesh: Mesh, center: Vector3?, height: number): Mesh`
- `UV.spherical(mesh: Mesh, center: Vector3?): Mesh`
- `UV.faceCharts(mesh: Mesh, padding: number?): Mesh`
- `UV.transform(mesh: Mesh, scale: Vector2 | number, offset: Vector2, angle: number?): Mesh`
- `UV.validate(mesh: Mesh): UVValidation`
- `UV.splitTiles(mesh: Mesh, columns: number, rows: number, options: TileOptions?): { Tile }`

## Unwrap

Source: [src/Unwrap.luau](src/Unwrap.luau)

- `Unwrap.autoSeams(mesh: Mesh, options: Options?)`
- `Unwrap.angleBased(mesh: Mesh, options: Options?)`
- `Unwrap.harmonic(mesh: Mesh, options: HarmonicOptions?): (Mesh, HarmonicReport)`
- `Unwrap.unwrap(mesh: Mesh, seams: Seams?, options: Options?)`
- `Unwrap.sharpSeams(mesh: Mesh, angle: number?): Seams`

## Additional returned objects

- `Subdivision.multires(mesh, levels, options)` returns `get()`, `select(level)`, and `commit(editedMesh)` methods.
- `Jobs.start(operation)` returns a job with `cancel()`, `status`, `progress`, `result`, and `error`.

- `ArcLength.prepare(curve, options)` returns `atLength(distance)`, `atFraction(fraction)` and `sample(count)` dot-call functions with immutable length bounds.

## Native handle ownership

`Roblox.toEditable` returns an editable handle; destroy its `part` (if created) and `editable` when finished. `Roblox.toModel` and `toTexturedModel` return a bundle; use `Roblox.destroy(bundle)` for cleanup. Native content is ephemeral until explicitly published or reconstructed from a source checkpoint.
