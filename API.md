# Editable3D API reference

Public callable signatures for version 0.87.0. See [README.md](README.md) for coordinate, mutation, scope and algorithm contracts.

Typed boundary contracts and resource/publishing options: [PRODUCTION.md](PRODUCTION.md). Development and release workflow: [MAINTAINING.md](MAINTAINING.md).

Constructors use dots (`E.Mesh.new()`); instance methods use colons (`mesh:addVertex(...)`). Ordinary module operators use dots and generally return a new mesh/image.

## ARAP

Source: [src/ARAP.luau](src/ARAP.luau)

- `ARAP.bind(mesh: Mesh, options: BindOptions?): Deformer`
- `ARAP:solve(anchors: { [number]: Vector3 }, options: SolveOptions?): (Mesh, SolveReport)`

## Adaptive

Source: [src/Adaptive.luau](src/Adaptive.luau)

- `Adaptive.refine(mesh: Types.Mesh, targetLength: TargetLength, options: AdaptiveOptions?): (Types.Mesh, RefineReport)`
- `Adaptive.remesh(mesh: Types.Mesh, targetLength: TargetLength, options: AdaptiveOptions?): (Types.Mesh, RemeshReport)`

## Animation

Source: [src/Animation.luau](src/Animation.luau)

- `Animation.track(keys: { Key }, interpolation: string?): Track`
- `Animation.sample(track: Track, time: number): any`
- `Animation.evaluate(tracks: { [string]: Track }, time: number, duration: number?, looped: boolean?): Values`
- `Animation.blend(a: Values, b: Values, weight: number): Values`
- `Animation.bake(tracks: { [string]: Track }, startTime: number, endTime: number, fps: number): { Frame }`

## ArcLength

Source: [src/ArcLength.luau](src/ArcLength.luau)

- `ArcLength.prepare(curve: Curve, options: ArcLengthOptions?): PreparedArcLength`
- `ArcLength.parameter(curve: Curve, distance: number, options: ArcLengthOptions?): ArcLengthResult`
- `ArcLength.sample(curve: Curve, count: number, options: ArcLengthOptions?): ({ Vector3 }, ArcLengthSampling)`

## Attributes

Source: [src/Attributes.luau](src/Attributes.luau)

- `Attributes.create(mesh: Mesh, name: string, domain: string, dataType: string, default: unknown, interpolation: string?): Mesh`
- `Attributes.set(mesh: Mesh, name: string, values: { [any]: unknown }): Mesh`
- `Attributes.get(mesh: Mesh, name: string, key: any): any`
- `Attributes.remove(mesh: Mesh, name: string): Mesh`
- `Attributes.names(mesh: Mesh, domain: string?): { string }`
- `Attributes.transfer(source: Mesh, target: Mesh, maps: any): Mesh`
- `Attributes.convertDomain(mesh: Mesh, name: string, domain: string, options: { [string]: any }?): (Mesh, any)`
- `Attributes.project(source: Mesh, target: Mesh, options: { [string]: any }?): (Mesh, any)`

## BSDF

Source: [src/BSDF.luau](src/BSDF.luau)

- `BSDF.diffuse(color: any?): Material`
- `BSDF.ggx(options: Material?): Material`
- `BSDF.metallicRoughness(options: Material?): Material`
- `BSDF.dielectric(ior: number?, tint: any?): Material`
- `BSDF.mix(a: MaterialInput, b: MaterialInput, weight: any?): Material`
- `BSDF.resolve(input: MaterialInput, context: any?): Resolved`
- `BSDF.fresnelDielectric(cosine: number, etaI: number, etaT: number): number`
- `BSDF.fresnelSchlick(cosine: number, f0: Color3 | Vector3): Vector3`
- `BSDF.distributionGGX(cosine: number, alpha: number): number`
- `BSDF.maskingGGX(cosine: number, alpha: number): number`
- `BSDF.sampleGGX(normal: Vector3, outgoing: Vector3, alpha: number, u: number, v: number): Vector3?`
- `BSDF.evaluate(material: MaterialInput, normal: Vector3, outgoing: Vector3, incoming: Vector3): Vector3`
- `BSDF.pdf(material: MaterialInput, normal: Vector3, outgoing: Vector3, incoming: Vector3): number`
- `BSDF.sample(material: MaterialInput, normal: Vector3, outgoing: Vector3, random: RandomSource?, entering: boolean?): Sample?`
- `BSDF.emission(material: MaterialInput, context: any?, frontFacing: boolean?): Vector3`

## Bake

Source: [src/Bake.luau](src/Bake.luau)

- `Bake.rasterize(mesh: Mesh, width: number, height: number, shader: (Types.BakeContext) -> (Color3, number?), options: BakeOptions?): (Texture, BakeReport)`
- `Bake.dilate(image: Texture, coverage: buffer, iterations: number, options: Types.Limits?): Texture`
- `Bake.normalMap(low: Mesh, high: Mesh, width: number, height: number, options: BakeOptions?): (Texture, BakeReport)`
- `Bake.ambientOcclusion(mesh: Mesh, width: number, height: number, options: BakeOptions?): (Texture, BakeReport)`
- `Bake.project(mesh: Mesh, texture: Texture, camera: Types.Camera, width: number, height: number, options: BakeOptions?): (Texture, BakeReport)`

## Bezier

Source: [src/Bezier.luau](src/Bezier.luau)

- `Bezier.new(points: { Vector3 }, options: BezierOptions?): BezierCurve`
- `Bezier.setPoint(curve: BezierCurve, index: number, position: Vector3): BezierCurve`
- `Bezier.setMode(curve: BezierCurve, index: number, mode: string): BezierCurve`
- `Bezier.setHandle(curve: BezierCurve, index: number, side: string, position: Vector3): BezierCurve`
- `Bezier.split(curve: BezierCurve, segment: number, t: number): BezierCurve`
- `Bezier.reverse(curve: BezierCurve): BezierCurve`
- `Bezier.toNURBS(curve: BezierCurve): N.Curve`
- `Bezier.evaluate(curve: BezierCurve, t: number): Vector3`
- `Bezier.derivatives(curve: BezierCurve, t: number): N.CurveDerivatives`

## Boolean

Source: [src/Boolean.luau](src/Boolean.luau)

- `Boolean.apply(a: Mesh, b: Mesh, operation: string, options: BooleanOptions?): (Mesh, BooleanReport)`
- `Boolean.union(a: Mesh, b: Mesh, options: BooleanOptions?): (Mesh, BooleanReport)`
- `Boolean.intersect(a: Mesh, b: Mesh, options: BooleanOptions?): (Mesh, BooleanReport)`
- `Boolean.subtract(a: Mesh, b: Mesh, options: BooleanOptions?): (Mesh, BooleanReport)`

## Camera

Source: [src/Camera.luau](src/Camera.luau)

- `Camera.new(frame: CFrame, fov: number, width: number, height: number): Camera`
- `Camera.project(camera: Camera, point: Vector3): (Vector2?, number)`
- `Camera.ray(camera: Camera, pixel: Vector2): (Vector3, Vector3)`
- `Camera.compare(camera: Camera, landmarks: { Landmark }): CompareReport`
- `Camera.fit(initial: Camera, landmarks: { Landmark }, options: FitOptions?): (Camera, CompareReport)`

## Conformal

Source: [src/Conformal.luau](src/Conformal.luau)

- `Conformal.lscm(mesh: Mesh, options: Options?): (Mesh, Report)`
- `Conformal.distortion(mesh: Mesh): DistortionReport`

## Connectivity

Source: [src/Connectivity.luau](src/Connectivity.luau)

- `Connectivity.index(mesh: any, options: Options?): Index`
- `Connectivity.analyze(mesh: any, options: Options?): Analysis`
- `Connectivity.boundaries(mesh: any, options: Options?): ({ BoundaryLoop }, BoundaryReport)`

## Constraints

Source: [src/Constraints.luau](src/Constraints.luau)

- `Constraints.copyLocation(owner: CFrame, target: Target, options: Options?): CFrame`
- `Constraints.copyRotation(owner: CFrame, target: CFrame, options: Options?): CFrame`
- `Constraints.copyTransform(owner: CFrame, target: CFrame, options: Options?): CFrame`
- `Constraints.limitLocation(owner: CFrame, options: Options?): CFrame`
- `Constraints.limitRotation(owner: CFrame, options: Options?): CFrame`
- `Constraints.limitDistance(owner: CFrame, target: Target, options: Options?): CFrame`
- `Constraints.floor(owner: CFrame, options: Options?): CFrame`
- `Constraints.trackTo(owner: CFrame, target: Target, options: Options?): CFrame`
- `Constraints.dampedTrack(owner: CFrame, target: Target, options: Options?): CFrame`
- `Constraints.lockedTrack(owner: CFrame, target: Target, options: Options?): CFrame`
- `Constraints.followPath(owner: CFrame, path: PathLike, factor: number, options: Options?): CFrame`
- `Constraints.setInverse(targetRest: CFrame): CFrame`
- `Constraints.childOf(owner: CFrame, target: CFrame, options: Options?): CFrame`
- `Constraints.evaluate(nodes: { [NodeId]: Node }, pose: { [NodeId]: CFrame }?): Result`
- `Constraints.rig(rig: RigLike, pose: { [NodeId]: CFrame }?, stacks: { [number]: { Constraint } }?): ({ [NodeId]: CFrame }, Result)`

## Convex

Source: [src/Convex.luau](src/Convex.luau)

- `Convex.fromMesh(mesh: Mesh, options: ShapeOptions?): Shape`
- `Convex.box(size: Vector3): Shape`
- `Convex.toMesh(shape: Shape): Mesh`
- `Convex.hull(points: { Vector3 }, options: HullOptions?): Shape`
- `Convex.support(shape: Shape, direction: Vector3, frame: CFrame?): (Vector3, number)`
- `Convex.bounds(shape: Shape, frame: CFrame?): (Vector3, Vector3)`
- `Convex.tensorMultiply(t: Tensor, v: Vector3): Vector3`
- `Convex.tensorInverse(t: Tensor): Tensor`
- `Convex.massProperties(shape: Shape, mass: number): MassProperties`
- `Convex.contact(shapeA: Shape, frameA: CFrame?, shapeB: Shape, frameB: CFrame?, options: ContactOptions?): Contact`

## Curves

Source: [src/Curves.luau](src/Curves.luau)

- `Curves.bezier<T>(points: { T }): Curve<T>`
- `Curves.catmullRom<T>(points: { T }, closed: boolean?): Curve<T>`
- `Curves.nurbs(points: { Vector3 }, degree: number, knots: { number }?, weights: { number }?): Curve<Vector3>`
- `Curves.sample<T>(curve: Curve<T>, segments: number): { T }`
- `Curves.resample<T>(points: { T }, count: number): { T }`
- `Curves.circle(radius: number, segments: number): { Vector2 }`
- `Curves.loft(rings: { { Vector3 } }, caps: boolean?, options: LoftOptions?): Mesh`
- `Curves.sweep(profile: SweepProfile, path: { Vector3 }, options: SweepOptions?): Mesh`
- `Curves.lathe(profile: { Vector2 }, segments: number): Mesh`
- `Curves.bezierSurface(control: { { Vector3 } }, uSegments: number, vSegments: number): Mesh`
- `Curves.stroke2D(points: { Vector2 }, width: number, options: Stroke2DOptions?): Mesh`

## Cyclic

Source: [src/Cyclic.luau](src/Cyclic.luau)

- `Cyclic.curve(points: { Vector3 }, degree: number, options: CyclicCurveOptions?): CyclicCurve`
- `Cyclic.toNURBS(curve: CyclicCurve): Curve`
- `Cyclic.evaluate(curve: CyclicCurve, t: number): Vector3`
- `Cyclic.derivatives(curve: CyclicCurve, t: number): N.CurveDerivatives`
- `Cyclic.rotateSeam(curve: CyclicCurve, offset: number): CyclicCurve`
- `Cyclic.reverse(curve: CyclicCurve): CyclicCurve`
- `Cyclic.insertKnot(curve: CyclicCurve, t: number, count: number?): CyclicCurve`
- `Cyclic.surface(control: { { Vector3 } }, degreeU: number, degreeV: number, options: CyclicSurfaceOptions?): CyclicSurface`
- `Cyclic.surfaceToNURBS(surface: CyclicSurface): Surface`
- `Cyclic.evaluateSurface(surface: CyclicSurface, u: number, v: number): Vector3`
- `Cyclic.surfaceDerivatives(surface: CyclicSurface, u: number, v: number): N.SurfaceDerivatives`
- `Cyclic.insertSurfaceKnot(surface: CyclicSurface, axis: string, t: number, count: number?): CyclicSurface`
- `Cyclic.reverseSurface(surface: CyclicSurface, axis: string): CyclicSurface`
- `Cyclic.rotateSurfaceSeam(surface: CyclicSurface, axis: string, offset: number): CyclicSurface`
- `Cyclic.elevateDegree(curve: CyclicCurve, count: number?, options: any)`
- `Cyclic.removeKnot(curve: CyclicCurve, t: number, count: number?, options: any)`
- `Cyclic.elevateSurfaceDegree(surface: CyclicSurface, axis: string, count: number?, options: any)`
- `Cyclic.removeSurfaceKnot(surface: CyclicSurface, axis: string, t: number, count: number?, options: any)`

## Deform

Source: [src/Deform.luau](src/Deform.luau)

- `Deform.masked(mesh: Mesh, operation: any, options: any?)`
- `Deform.map(mesh: Mesh, callback: (Vector3, number) -> Vector3, mask: Mask?): Mesh`
- `Deform.transform(mesh: Mesh, frame: CFrame, scale: Vector3?, options: TransformOptions?): Mesh`
- `Deform.twist(mesh: Mesh, radians: number, lo: number, hi: number, mask: Mask?): Mesh`
- `Deform.taper(mesh: Mesh, bottom: number, top: number, lo: number, hi: number, mask: Mask?): Mesh`
- `Deform.bend(mesh: Mesh, curvature: number, mask: Mask?): Mesh`
- `Deform.lattice(mesh: Mesh, lo: Vector3, hi: Vector3, controls: { Vector3 }, mask: Mask?): Mesh`
- `Deform.shrinkwrap(mesh: Mesh, target: Mesh, offset: number?, mask: Mask?, maxDistance: number?): Mesh`
- `Deform.contact(mesh: Mesh, field: (Vector3) -> number, clearance: number?, mask: Mask?, iterations: number?): Mesh`
- `Deform.rbf(mesh: Mesh, handles: { Handle }, radius: number, mask: Mask?): Mesh`
- `Deform.simple(mesh: Mesh, mode: string, amount: number, options: any?)`
- `Deform.shear(mesh: Mesh, factor: number, options: any?)`
- `Deform.cast(mesh: Mesh, shape: string, options: any?)`
- `Deform.warp(mesh: Mesh, from: CFrame, to: CFrame, options: any?)`
- `Deform.taperProfile(mesh: Mesh, profile: any, options: any?)`
- `Deform.curve(mesh: Mesh, curve: any, options: any?)`
- `Deform:sample(p: Vector2): number?`
- `Deform:blurred(radius: number): Envelope`
- `Deform.envelope(mesh: Mesh, view: CFrame, step: number, fill: number?): Envelope`
- `Deform.relief(mesh: Mesh, view: CFrame, target: (Vector2, number) -> number?, options: ReliefOptions?): Mesh`

## Dynamics

Source: [src/Dynamics.luau](src/Dynamics.luau)

- `Dynamics.new(options: DynamicsOptions?): Dynamics`
- `Dynamics:addConvex(shape: Shape, mass: number, frame: CFrame?, options: BodyOptions?): number`
- `Dynamics:addBox(size: Vector3, mass: number, frame: CFrame?, options: BodyOptions?): number`
- `Dynamics:remove(id: number)`
- `Dynamics:frame(id: number): CFrame`
- `Dynamics:setFrame(id: number, frame: CFrame)`
- `Dynamics:impulse(id: number, impulse: Vector3, point: Vector3?)`
- `Dynamics:angularImpulse(id: number, impulse: Vector3)`
- `Dynamics:force(id: number, force: Vector3, point: Vector3?)`
- `Dynamics:torque(id: number, torque: Vector3)`
- `Dynamics:velocityAt(id: number, point: Vector3): Vector3`
- `Dynamics:momentum(): (Vector3, Vector3)`
- `Dynamics:energy(): Energy`
- `Dynamics:collisions(options: DynamicsOptions?): { Manifold }`
- `Dynamics:step(dt: number, options: DynamicsOptions?): StepReport`

## Fields

Source: [src/Fields.luau](src/Fields.luau)

- `Fields.sphere(center: Vector3, radius: number): Field`
- `Fields.box(center: Vector3, halfSize: Vector3): Field`
- `Fields.capsule(a: Vector3, b: Vector3, radius: number): Field`
- `Fields.torus(center: Vector3, major: number, minor: number): Field`
- `Fields.plane(point: Vector3, normal: Vector3): Field`
- `Fields.union(a: Field, b: Field): Field`
- `Fields.intersect(a: Field, b: Field): Field`
- `Fields.subtract(a: Field, b: Field): Field`
- `Fields.smoothUnion(a: Field, b: Field, radius: number): Field`
- `Fields.offset(field: Field, amount: number): Field`
- `Fields.shell(field: Field, thickness: number): Field`
- `Fields.transform(field: Field, frame: CFrame, scale: number?): Field`
- `Fields.fromMesh(mesh: Types.Mesh): Field`

## Fluid

Source: [src/Fluid.luau](src/Fluid.luau)

- `Fluid.new(options: FluidOptions?): Fluid`
- `Fluid:add(position: Vector3, velocity: Vector3?): number`
- `Fluid:step(dt: number, substeps: number?): Fluid`
- `Fluid:field(radius: number?): (Vector3) -> number`

## GLTF

Source: [src/GLTF.luau](src/GLTF.luau)

- `GLTF.readAccessor(doc: Doc, sources: Sources?, accessorIndex: number): { Tuple }`
- `GLTF.worldMatrices(scene: Scene, pose: any?): { [number]: Matrix }`
- `GLTF.sampleAnimation(scene: Scene, animationIndex: number, time: number, options: any?): Pose`
- `GLTF.fromDocument(doc: Doc, sources: Sources?): Scene`
- `GLTF.fromJSON(json: string, sources: Sources?): Scene`
- `GLTF.fromGLB(data: buffer | string, sources: Sources?): Scene`
- `GLTF.meshAt(scene: Scene, nodeIndex: number, pose: any?): Mesh`
- `GLTF.fromMesh(mesh: Mesh, options: ExportOptions?): Scene`
- `GLTF.fromRig(mesh: Mesh, rig: RigLike, options: ExportOptions?): Scene`
- `GLTF.toDocument(scene: Scene): (Doc, { buffer })`
- `GLTF.toJSON(scene: Scene, bufferURI: string?): (string, { buffer })`
- `GLTF.toGLB(scene: Scene): buffer`

## Geometry

Source: [src/Geometry.luau](src/Geometry.luau)

- `Geometry.scatter(mesh: Mesh, count: number, seed: number?, density: ((Vector3) -> number)?): ({ ScatterPoint }, ScatterReport)`
- `Geometry.instance(mesh: Mesh, transforms: { CFrame }): Mesh`
- `Geometry.assignMaterial(mesh: Mesh, faces: { [number]: boolean }, slot: number): Mesh`
- `Geometry.vertexColors(mesh: Mesh, field: (Vector3, number) -> (Color3, number?)): Mesh`
- `Geometry.group(mesh: Mesh, name: string, mask: { [number]: number }): Mesh`
- `Geometry.parametric(fn: (number, number) -> Vector3, uSegments: number, vSegments: number, wrapU: boolean?, wrapV: boolean?): Mesh`
- `Geometry.principalAxes(mesh: Mesh): PrincipalAxes`

## Graph

Source: [src/Graph.luau](src/Graph.luau)

- `Graph.new(): Graph`
- `Graph:add(operation: Operation, inputs: { [any]: number }?, parameters: { [any]: any }?): number`
- `Graph:connect(node: number, slot: any, source: number)`
- `Graph:order(output: number): { number }`
- `Graph:evaluate(output: number, context: any?): any`

## History

Source: [src/History.luau](src/History.luau)

- `History.new(mesh: Mesh, limit: number?): History`
- `History:current(): Mesh`
- `History:apply(label: string, operation: (Mesh) -> Mesh): Mesh`
- `History:undo(): Mesh`
- `History:redo(): Mesh`

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

- `Integrator.powerHeuristic(a: number, b: number): number`
- `Integrator.prepare(mesh: Types.Mesh, materials: { [number]: B.MaterialInput }?, options: IntegratorOptions?): Scene`
- `Integrator.trace(scene: Scene, origin: Vector3, direction: Vector3, options: IntegratorOptions?, random: Random?): (Vector3, TraceStats)`
- `Integrator.render(mesh: Types.Mesh, camera: Types.Camera, materials: { [number]: B.MaterialInput }?, options: IntegratorOptions?): (Types.Texture?, RenderReport)`
- `Integrator.toneMap(image: Types.Texture, exposure: number?, method: string?): Types.Texture`

## Intersections

Source: [src/Intersections.luau](src/Intersections.luau)

- `Intersections.segmentTriangle(a: Vector3, b: Vector3, triangle: { Vector3 }): IntersectionResult`
- `Intersections.triangles(a: { Vector3 }, b: { Vector3 }): IntersectionResult`
- `Intersections.mesh(mesh: Mesh, options: { [string]: any }?): ({ IntersectionResult }, ScanReport)`
- `Intersections.between(a: Mesh, b: Mesh, options: { [string]: any }?): ({ IntersectionResult }, ScanReport)`

## Jobs

Source: [src/Jobs.luau](src/Jobs.luau)

- `Jobs.start(operation: (Context) -> any): Job`
- `Jobs.await(job: Job, timeout: number?): (any, string?)`

## Laplacian

Source: [src/Laplacian.luau](src/Laplacian.luau)

- `Laplacian.bind(mesh: Mesh, options: BindOptions?): Graph`
- `Laplacian:solve(anchors: { [number]: Vector3 }, options: SolveOptions?): (Mesh, SolveReport)`

## Lighting

Source: [src/Lighting.luau](src/Lighting.luau)

- `Lighting.surface(mesh: Types.Mesh, hit: Hit): SurfaceContext`
- `Lighting.point(position: Vector3, intensity: Color3 | Vector3): PointLight`
- `Lighting.directional(direction: Vector3, radiance: Color3 | Vector3): DirectionalLight`
- `Lighting.environment(source: any?): EnvironmentLight`
- `Lighting.environmentRadiance(env: EnvironmentLight, direction: Vector3): Vector3`
- `Lighting.environmentPDF(env: EnvironmentLight, direction: Vector3): number`
- `Lighting.sampleEnvironment(env: EnvironmentLight, random: Random): LightSample`
- `Lighting.new(mesh: Types.Mesh, materials: { [number]: B.MaterialInput }, options: LightingOptions?): LightSet`
- `Lighting:environmentRadiance(direction: Vector3): Vector3`
- `Lighting:sample(point: Vector3, random: Random): LightSample?`
- `Lighting:pdf(point: Vector3, direction: Vector3, hit: Hit?): number`

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

- `MeshRepair.splitIntersections(mesh: Mesh, options: ArrangementOptions?): (Mesh, RepairReport)`
- `MeshRepair.resolveIntersections(mesh: Mesh, options: ArrangementOptions?): (Mesh, RepairReport)`
- `MeshRepair.clean(mesh: Mesh, options: CleanOptions?): (Mesh, RepairReport)`
- `MeshRepair.orient(mesh: Mesh, options: OrientOptions?): (Mesh, RepairReport)`
- `MeshRepair.audit(mesh: Mesh, options: AuditOptions?): AuditReport`
- `MeshRepair.unfold(mesh: Mesh, options: UnfoldOptions?): (Mesh, RepairReport)`

## Modifiers

Source: [src/Modifiers.luau](src/Modifiers.luau)

- `Modifiers.bevel(mesh: Mesh, width: number, options: BevelOptions?): (Mesh, { [string]: any })`
- `Modifiers.array(mesh: Mesh, count: number, step: CFrame): Mesh`
- `Modifiers.mirror(mesh: Mesh, axis: string, weldTolerance: number?): Mesh`
- `Modifiers.solidify(mesh: Mesh, thickness: number, options: any?)`
- `Modifiers.shell(mesh: Mesh, thickness: number, options: any?)`
- `Modifiers.clipPlane(mesh: Mesh, point: Vector3, normal: Vector3, cap: boolean?, options: { [string]: any }?)`
- `Modifiers.bevelConvex(mesh: Mesh, width: number): Mesh`
- `Modifiers.stack(mesh: Mesh, operations: { (Mesh) -> Mesh }): Mesh`

## Morph

Source: [src/Morph.luau](src/Morph.luau)

- `Morph.fromMeshes(base: Mesh, target: Mesh, name: string?): Shape`
- `Morph.evaluate(base: Mesh, targets: { [number]: Shape }, weights: { [number]: number }?, options: EvaluateOptions?): Mesh`
- `Morph.transfer(sourceBase: Mesh, targetBase: Mesh, target: Shape, options: TransferOptions?): (Shape, TransferReport)`

## NURBS

Source: [src/NURBS.luau](src/NURBS.luau)

- `NURBS.curve(points: { Vector3 }, degree: number, options: CurveOptions?): Curve`
- `NURBS.surface(control: { { Vector3 } }, degreeU: number, degreeV: number, options: SurfaceOptions?): Surface`
- `NURBS.evaluate(curve: Curve, t: number): Vector3`
- `NURBS.derivatives(curve: Curve, t: number): CurveDerivatives`
- `NURBS.compileCurve(curve: Curve): CurveEvaluator`
- `NURBS.basisWeights(curve: Curve, t: number): { number }`
- `NURBS.clamp(curve: Curve): Curve`
- `NURBS.insertKnot(curve: Curve, t: number, count: number?): Curve`
- `NURBS.split(curve: Curve, t: number): (Curve, Curve)`
- `NURBS.reverse(curve: Curve): Curve`
- `NURBS.evaluateSurface(surface: Surface, u: number, v: number): Vector3`
- `NURBS.surfaceDerivatives(surface: Surface, u: number, v: number): SurfaceDerivatives`
- `NURBS.compileSurface(surface: Surface): SurfaceEvaluator`
- `NURBS.clampSurface(surface: Surface, axis: string): Surface`
- `NURBS.insertSurfaceKnot(surface: Surface, axis: string, t: number, count: number?): Surface`
- `NURBS.splitSurface(surface: Surface, axis: string, t: number): (Surface, Surface)`
- `NURBS.reverseSurface(surface: Surface, axis: string): Surface`
- `NURBS.isoCurve(surface: Surface, axis: string, t: number): Curve`
- `NURBS.bezierSegments(curve: Curve): { BezierSegment }`
- `NURBS.bezierPatches(surface: Surface): { BezierPatch }`
- `NURBS.elevateDegree(curve: Curve, count: number?): Curve`
- `NURBS.elevateSurfaceDegree(surface: Surface, axis: string, count: number?): Surface`
- `NURBS.removeKnot(curve: Curve, t: number, count: number?, options: RemovalOptions?): (Curve, RemovalReport)`
- `NURBS.removeSurfaceKnot(surface: Surface, axis: string, t: number, count: number?, options: RemovalOptions?): (Surface, RemovalReport)`
- `NURBS.tessellate(surface: Surface, uSegments: number, vSegments: number, options: TessellateOptions?): (Types.Mesh, TessellateReport)`

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
- `Normals.unify(meshes: { Mesh }, options: UnifyOptions?): { Mesh }`
- `Normals.tangents(mesh: Mesh, options: Options?)`

## Particles

Source: [src/Particles.luau](src/Particles.luau)

- `Particles.new(seed: number?): Particles`
- `Particles:emit(count: number, initializer: (Random, number) -> ParticleInit): { number }`
- `Particles:step(dt: number, force: ((Particle, number) -> Vector3)?, drag: number?): Particles`
- `Particles:instances(mesh: Mesh, scale: number?): Mesh`

## PathTrace

Source: [src/PathTrace.luau](src/PathTrace.luau)

- `PathTrace.render(mesh: Types.Mesh, camera: Types.Camera, materials: { [number]: PathMaterial }, options: PathTraceOptions?): (Types.Texture?, PathTraceReport)`

## Pattern

Source: [src/Pattern.luau](src/Pattern.luau)

- `Pattern.hash(i: number, j: number?, k: number?, seed: number?): number`
- `Pattern.smoothstep(edge0: number, edge1: number, x: number): number`
- `Pattern.fbm(p: Vector3, options: FbmOptions?): number`
- `Pattern.panels(p: Vector3, options: PanelOptions): PanelSample`
- `Pattern.streaks(p: Vector3, normal: Vector3, options: StreakOptions?): number`

## Planar

Source: [src/Planar.luau](src/Planar.luau)

- `Planar.intersections(loops: { Loop }, options: Options?): ({ Hit }, HitStatus)`
- `Planar.triangulate(outer: Loop, holes: { Loop }?, options: Options?): Domain`
- `Planar.toMesh(domain: Domain, frame: CFrame?): Mesh.Mesh`
- `Planar.constrain(outer: Loop, holes: { Loop }?, paths: any, options: any?)`
- `Planar.outlineContains(points: { Vector2 }, p: Vector2): boolean`
- `Planar.outlineDistance(points: { Vector2 }, p: Vector2): number`
- `Planar.offsetOutline(points: { Vector2 }, distance: number): ({ Vector2 }, { Vector2 })`

## Predicates

Source: [src/Predicates.luau](src/Predicates.luau)

- `Predicates.orient2D(a: Vector2, b: Vector2, c: Vector2): (number, number, ...boolean)`
- `Predicates.orient3D(a: Vector3, b: Vector3, c: Vector3, d: Vector3): (number, number, ...boolean)`
- `Predicates.inCircle(a: Vector2, b: Vector2, c: Vector2, d: Vector2): (number, number, ...boolean)`
- `Predicates.inSphere(a: Vector3, b: Vector3, c: Vector3, d: Vector3, e: Vector3): (number, number, ...boolean)`
- `Predicates.polygonOrientation(points: { Vector2 }): (number, number)`
- `Predicates.onSegment2D(point: Vector2, a: Vector2, b: Vector2): boolean`
- `Predicates.pointInPolygon2D(point: Vector2, points: { Vector2 }): (string, number)`
- `Predicates.intersectSegments2D(a: Vector2, b: Vector2, c: Vector2, d: Vector2): Intersection`

## Primitives

Source: [src/Primitives.luau](src/Primitives.luau)

- `Primitives.grid(nx: number, nz: number, size: Vector2?): Mesh`
- `Primitives.box(size: Vector3?): Mesh`
- `Primitives.sphere(radius: number?, segments: number?, rings: number?): Mesh`
- `Primitives.cylinder(radius: number?, height: number?, segments: number?, topRadius: number?): Mesh`
- `Primitives.torus(major: number?, minor: number?, segments: number?, sides: number?): Mesh`
- `Primitives.prism(polygon: { Vector2 }, y0: number, y1: number, options: { bottomScale: number? }?): Mesh`
- `Primitives.stairs(width: number, depth: number, height: number, steps: number): Mesh`
- `Primitives.tree(options: TreeOptions?): Mesh`

## Quaternion

Source: [src/Quaternion.luau](src/Quaternion.luau)

- `Quaternion.new(x: number, y: number, z: number, w: number): Quat`
- `Quaternion.dot(a: Quat, b: Quat): number`
- `Quaternion.normalize(q: Quat): Quat`
- `Quaternion.conjugate(q: Quat): Quat`
- `Quaternion.inverse(q: Quat): Quat`
- `Quaternion.multiply(a: Quat, b: Quat): Quat`
- `Quaternion.fromAxisAngle(axis: Vector3, angle: number): Quat`
- `Quaternion.toAxisAngle(q: Quat): (Vector3, number)`
- `Quaternion.fromCFrame(cf: CFrame): Quat`
- `Quaternion.toCFrame(q: Quat, position: Vector3?): CFrame`
- `Quaternion.rotate(q: Quat, v: Vector3): Vector3`
- `Quaternion.slerp(a: Quat, b: Quat, t: number): Quat`
- `Quaternion.rotationVector(q: Quat): Vector3`
- `Quaternion.fromRotationVector(v: Vector3): Quat`
- `Quaternion.integrate(q: Quat, angularVelocity: Vector3, dt: number, localSpace: boolean?): Quat`
- `Quaternion.squad(a: Quat, controlA: Quat, controlB: Quat, b: Quat, t: number): Quat`

## Registration

Source: [src/Registration.luau](src/Registration.luau)

- `Registration.rotation(source: { Vector3 }, target: { Vector3 }, options: Options?): (CFrame, RotationReport)`
- `Registration.fit(source: { Vector3 }, target: { Vector3 }, options: Options?): FitResult`
- `Registration.translation(source: any, target: any, options: { quantum: number?, limit: number? }?): (Vector3?, number)`
- `Registration.icp(source: any, target: any, options: ICPOptions?): (CFrame, ICPReport)`

## Remesh

Source: [src/Remesh.luau](src/Remesh.luau)

- `Remesh.quads(mesh: Mesh, targetLength: number, options: { [string]: any }?): (Mesh, any)`
- `Remesh.fromField(field: ScalarField, lo: Vector3, hi: Vector3, cellSize: number, options: RemeshOptions?): Mesh`
- `Remesh.voxel(mesh: Mesh, cellSize: number, options: RemeshOptions?): (Mesh, RemeshReport)`
- `Remesh.boolean(a: Mesh, b: Mesh, operation: string, cellSize: number, options: RemeshOptions?): (Mesh, RemeshReport)`

## Render

Source: [src/Render.luau](src/Render.luau)

- `Render.render(mesh: Types.Mesh, camera: Types.Camera, options: RenderOptions?): (Types.Texture, buffer)`
- `Render.silhouette(mesh: Types.Mesh, camera: Types.Camera): (Types.Texture, buffer)`
- `Render.compareSilhouettes(a: Types.Texture, b: Types.Texture, threshold: number?): SilhouetteComparison`

## Rig

Source: [src/Rig.luau](src/Rig.luau)

- `Rig.new(): Rig`
- `Rig:addBone(name: string, parentId: number?, bindLocal: CFrame?): number`
- `Rig:worldTransforms(pose: Pose?): Pose`
- `Rig:skin(mesh: Mesh, pose: Pose?): Mesh`
- `Rig:skinDualQuaternion(mesh: Mesh, pose: Pose?, options: SkinOptions?): (Mesh, SkinReport)`
- `Rig:automaticWeights(mesh: Mesh, influences: number?, power: number?): Mesh`
- `Rig.normalizeWeights(mesh: Mesh, influences: number?): Mesh`
- `Rig.fabrik(points: { Vector3 }, target: Vector3, iterations: number?, tolerance: number?): { Vector3 }`
- `Rig.blendShapes(base: Mesh, shapes: { [string]: Mesh }, weights: { [string]: number }): Mesh`
- `Rig:solveIK(pose: Pose?, chain: { number }, target: Vector3, options: IKOptions?): (Pose, IKReport)`

## RigidBody

Source: [src/RigidBody.luau](src/RigidBody.luau)

- `RigidBody.new(options: WorldOptions?): World`
- `RigidBody:addSphere(radius: number, mass: number, frame: CFrame?, options: SphereOptions?): number`
- `RigidBody:addCollider(field: Field)`
- `RigidBody:impulse(id: number, impulse: Vector3, point: Vector3?)`
- `RigidBody:frame(id: number): CFrame`
- `RigidBody:step(dt: number, substeps: number?, iterations: number?): World`

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
- `Roblox.release(bundle: Disposable)`
- `Roblox.destroy(bundle: Disposable, options: DestroyOptions?)`
- `Roblox.fromPart(part: MeshPart, options: FromPartOptions?): Mesh`
- `Roblox.publishMaterials(parts: { MeshPart }, metadata: unknown, options: Types.PublishOptions?): Types.PublishReport`
- `Roblox.publishImages(images: { EditableImage }, metadata: unknown, options: Types.PublishOptions?): Types.PublishReport`
- `Roblox.publish(bundle: Bundle, metadata: unknown, options: Types.PublishOptions?): Types.PublishReport`
- `Roblox.rebake(parts: { MeshPart }, shader: (Vector3, Vector3, MeshPart) -> (Color3, number?), options: RebakeOptions?): Rebake`
- `Roblox.fillTerrain(terrain: Terrain, outline: { Vector2 }, options: TerrainFillOptions): number`

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

- `Simulation.new(options: SimOptions?): Simulation`
- `Simulation:addParticle(position: Vector3, mass: number?): number`
- `Simulation:pin(id: number, position: Vector3?)`
- `Simulation:addDistance(a: number, b: number, compliance: number?, restLength: number?): DistanceConstraint`
- `Simulation:addVolume(a: number, b: number, c: number, d: number, compliance: number?): VolumeConstraint`
- `Simulation:addCollider(field: Field, clearance: number?)`
- `Simulation:step(dt: number, substeps: number?, iterations: number?): Simulation`
- `Simulation.fromMesh(mesh: Mesh, options: SimOptions?): Simulation`
- `Simulation:toMesh(): Mesh`

## Spatial

Source: [src/Spatial.luau](src/Spatial.luau)

- `Spatial.new(mesh: Types.Mesh): Index`
- `Spatial:closest(point: Vector3, maxDistance: number?): Hit?`
- `Spatial:raycast(origin: Vector3, direction: Vector3, maxDistance: number?): Hit?`
- `Spatial:contains(point: Vector3): boolean`
- `Spatial:signedDistance(point: Vector3): number`
- `Spatial.coincident(a: Types.Mesh, b: any, options: CoincidentOptions?): Coincidence`
- `Spatial.coincidentPairs(meshes: { Types.Mesh }, options: (CoincidentOptions & { minFraction: number? })?): { CoincidentPair }`
- `Spatial.trimCoincident(mesh: Types.Mesh, keepers: { any }, options: CoincidentOptions?): (Types.Mesh, number)`
- `Spatial.closestTriangle(point, a, b, c)`

## SplineFit

Source: [src/SplineFit.luau](src/SplineFit.luau)

- `SplineFit.curve(points: { Vector3 }, degree: number, controlCount: number, options: CurveFitOptions?): (N.Curve, FitReport)`
- `SplineFit.interpolateCurve(points: { Vector3 }, degree: number, options: CurveFitOptions?): (N.Curve, FitReport)`
- `SplineFit.surface(grid: { { Vector3 } }, degreeU: number, degreeV: number, controlsU: number, controlsV: number, options: SurfaceFitOptions?): (N.Surface, FitReport)`
- `SplineFit.interpolateSurface(grid: { { Vector3 } }, degreeU: number, degreeV: number, options: SurfaceFitOptions?): (N.Surface, FitReport)`
- `SplineFit.refineCurve(initial: any, points: { Vector3 }, options: any)`
- `SplineFit.refineSurface(initial: any, points: { Vector3 }, options: any)`

## SplineQuery

Source: [src/SplineQuery.luau](src/SplineQuery.luau)

- `SplineQuery.intersectCurveSurface(curve: Curve, surface: Surface, options: any): any`
- `SplineQuery.intersectSurfaces(surfaceA: Surface, surfaceB: Surface, options: any): any`
- `SplineQuery.length(curve: Curve, options: QueryOptions?): LengthReport`
- `SplineQuery.sample(curve: Curve, options: SampleOptions?): ({ Vector3 }, SampleReport)`
- `SplineQuery.closestCurve(curve: Curve, point: Vector3, options: QueryOptions?): CurveClosest`
- `SplineQuery.closestSurface(surface: Surface, point: Vector3, options: QueryOptions?): SurfaceClosest`

## Stroke

Source: [src/Stroke.luau](src/Stroke.luau)

- `Stroke.path(points: { Vector3 }, closed: boolean?): Path`
- `Stroke:closest(point: Vector3, normal: Vector3?, maxDistance: number?): Hit?`
- `Stroke:sample(arc: number): (Vector3, Vector3)`
- `Stroke.profile(distance: number, radius: number, kind: string?): number`
- `Stroke.field(path: Path, point: Vector3, normal: Vector3?, options: FieldOptions?): (number, Hit?)`
- `Stroke.sculpt(mesh: Mesh, path: Path, options: SculptOptions?): (Mesh, SculptReport)`

## Subdivision

Source: [src/Subdivision.luau](src/Subdivision.luau)

- `Subdivision.crease(mesh: Mesh, edges: { [string]: number }?, vertices: { [number]: number }?): Mesh`
- `Subdivision.prepareLimit(mesh: Mesh, options: LimitOptions?): any`
- `Subdivision.limit(mesh: Mesh, face: number, u: number, v: number, options: LimitOptions?): any`
- `Subdivision.catmullClark(mesh: Mesh, levels: number?, options: Options?): Mesh`
- `Subdivision.multires(mesh: Mesh, levels: number, options: Options?): Multires`

## SurfaceAdaptive

Source: [src/SurfaceAdaptive.luau](src/SurfaceAdaptive.luau)

- `SurfaceAdaptive.bound(surface: Surface): PatchBound`
- `SurfaceAdaptive.tessellate(surface: Surface, options: AdaptiveOptions?): (Types.Mesh, AdaptiveReport)`

## SurfaceDeform

Source: [src/SurfaceDeform.luau](src/SurfaceDeform.luau)

- `SurfaceDeform.bind(mesh: Mesh, target: Mesh, options: BindOptions?): (Binding, BindReport)`
- `SurfaceDeform:evaluate(target: Mesh, options: EvaluateOptions?): (Mesh, EvaluateReport)`

## SurfaceEdit

Source: [src/SurfaceEdit.luau](src/SurfaceEdit.luau)

- `SurfaceEdit.select(surface: Surface, selector: any, options: Options)`
- `SurfaceEdit.map(surface: Surface, operation: (Vector3, number, number, number) -> (Vector3, number?), options: Options)`
- `SurfaceEdit.transform(surface: Surface, frame: CFrame, options: Options)`
- `SurfaceEdit.setWeights(surface: Surface, values: any, options: Options)`
- `SurfaceEdit.smooth(surface: Surface, iterations: number?, options: Options)`
- `SurfaceEdit.deform(surface: Surface, operation: (...any) -> ...any, options: Options)`
- `SurfaceEdit.duplicate(surface: Surface, uRange: any, vRange: any, options: Options)`
- `SurfaceEdit.transpose(surface: Surface, options: Options)`
- `SurfaceEdit.setCyclic(surface: Surface, axis: string, enabled: boolean, options: Options)`
- `SurfaceEdit.extrude(surface: Surface, boundary: string, steps: number?, operation: any, options: Options)`
- `SurfaceEdit.split(surface: Surface, axis: string, index: number, options: Options)`
- `SurfaceEdit.deleteRows(surface: Surface, axis: string, indices: any, options: Options)`
- `SurfaceEdit.deleteSegments(surface: Surface, axis: string, first: number, last: number, options: Options)`
- `SurfaceEdit.boundaryCurve(surface: Surface, boundary: string, options: Options)`
- `SurfaceEdit.spin(surface: Surface, boundary: string, origin: Vector3, axis: Vector3, angle: number, options: Options)`

## SurfaceTrim

Source: [src/SurfaceTrim.luau](src/SurfaceTrim.luau)

- `SurfaceTrim.surface(surface: Surface, outer: Loop, holes: { Loop }?, options: D.Options?): TrimmedSurface`
- `SurfaceTrim.regions(surface: Surface, regions: any, options: RegionOptions?): (TrimmedSurfaceSet, any)`
- `SurfaceTrim.classify(trimmed: Trimmed, uv: Vector2): string`
- `SurfaceTrim.evaluate(trimmed: Trimmed, u: number, v: number): Vector3`
- `SurfaceTrim.fromCurves(surface: Surface, outerCurve: Curve, holeCurves: { Curve }?, options: FromCurvesOptions?): (TrimmedSurface, FromCurvesReport)`
- `SurfaceTrim.tessellate(trimmed: Trimmed, options: TessellateOptions?): (Types.Mesh, TessellationReport)`
- `SurfaceTrim.adaptive(trimmed: Trimmed, options: AdaptiveTrimOptions?): (Types.Mesh, any)`

## Surfaces

Source: [src/Surfaces.luau](src/Surfaces.luau)

- `Surfaces.join(surfaceA: Surface, boundaryA: any, surfaceB: Surface, boundaryB: any, options: any): any`
- `Surfaces.arc(frame: CFrame, radius: number, startAngle: number, endAngle: number): Curve`
- `Surfaces.compatible(curves: { Curve }, options: CompatibleOptions?): { Curve }`
- `Surfaces.extrude(curve: Curve, displacement: Vector3): Surface`
- `Surfaces.ruled(first: Curve, second: Curve, options: CompatibleOptions?): Surface`
- `Surfaces.loft(sections: { Curve }, degree: number?, options: LoftOptions?): (Surface, any)`
- `Surfaces.revolve(curve: Curve, origin: Vector3, axis: Vector3, angle: number, options: RevolveOptions?): Surface`
- `Surfaces.coons(bottom: Curve, top: Curve, left: Curve, right: Curve, options: any): (Surface, any)`
- `Surfaces.plane(frame: CFrame, size: Vector2): Surface`
- `Surfaces.cylinder(frame: CFrame, radius: number, height: number): Surface`
- `Surfaces.cone(frame: CFrame, radius: number, height: number): Surface`
- `Surfaces.sphere(frame: CFrame, radius: number): Surface`
- `Surfaces.torus(frame: CFrame, majorRadius: number, minorRadius: number): Surface`

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
- `Texture:guided(guide: Texture, radius: number, eps: number, options: Limits?): Texture`
- `Texture:normalFromHeight(strength: number?, options: Limits?): Texture`
- `Texture:paint(center: Vector2, radius: number, color: Color3, opacity: number?, options: Limits?): Texture`
- `Texture:toRGBA8(srgb: boolean?, options: Limits?): buffer`
- `Texture.fromRGBA8(width: number, height: number, bytes: buffer, srgb: boolean?, options: Limits?): Texture`
- `Texture.noise(width: number, height: number, frequency: number?, octaves: number?, seed: number?, options: Limits?): Texture`
- `Texture:tiles(size: number, options: Limits?): { Types.Tile }`

## Timeline

Source: [src/Timeline.luau](src/Timeline.luau)

- `Timeline.channel(path: string, times: { number }, values: { Tuple }, options: ChannelOptions?): Channel`
- `Timeline.sampleChannel(channel: Channel, time: number): Tuple`
- `Timeline.clip(channels: { Channel }, name: string?): Clip`
- `Timeline.sample(clip: ClipInput, time: number, options: SampleOptions?): (Pose, number)`
- `Timeline.layer(base: Pose, overlay: Pose, weight: number, additive: boolean?): Pose`

## Topology

Source: [src/Topology.luau](src/Topology.luau)

- `Topology.triangulate(mesh: Mesh): Mesh`
- `Topology.join(meshes: { Mesh }): Mesh`
- `Topology.extract(mesh: Mesh, faces: FaceSet): Mesh`
- `Topology.components(mesh: Mesh): { Mesh }`
- `Topology.reverse(mesh: Mesh): Mesh`
- `Topology.weld(mesh: Mesh, tolerance: number): (Mesh, { [number]: number })`
- `Topology.extrude(mesh: Mesh, selected: FaceSet, offset: Vector3): (Mesh, { [number]: number })`
- `Topology.insetFaces(mesh: Mesh, selected: FaceSet, fraction: number): Mesh`
- `Topology.bridge(mesh: Mesh, loopA: { number }, loopB: { number }): Mesh`
- `Topology.fill(mesh: Mesh, loop: { number }): Mesh`
- `Topology.splitEdge(mesh: Mesh, a: number, b: number, t: number?): (Mesh, number)`
- `Topology.dissolveEdge(mesh: Mesh, a: number, b: number): Mesh`
- `Topology.snap(meshes: { Mesh }, tolerance: number): ({ Mesh }, number, number)`

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
- `UV.cylindrical(mesh: Mesh, center: Vector3?, height: number, options: CylindricalOptions?): Mesh`
- `UV.box(mesh: Mesh, frame: CFrame?, options: BoxOptions?): (Mesh, BoxReport)`
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
