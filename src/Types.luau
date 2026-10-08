--!strict
-- Public boundary contracts. Engine value types come from the Roblox API definitions.
local Budget = require(script.Parent.OperationBudget)
local Publishing = require(script.Parent.PublishPipeline)
export type Limits = Budget.Options
export type Progress = Budget.Progress
-- Aliases kept for existing callers; they are the engine types.
export type Vector2Value = Vector2
export type Vector3Value = Vector3
export type Color = Color3
export type Frame = CFrame
export type Corner = {
	uv: Vector2Value?,
	normal: Vector3Value?,
	color: Color?,
	alpha: number?,
	uv1: Vector2Value?,
	tangent: Vector3Value?,
	tangentSign: number?,
}
export type Face = { vertices: { number }, corners: { Corner }, material: number }
export type Channel = {
	domain: string,
	dataType: string,
	default: unknown,
	interpolation: string?,
	values: { [any]: unknown },
}
export type TriangulationOptions = {
	maxVertices: number?,
	maxWork: number?,
	validateSimple: boolean?,
	checkpoint: ((fraction: number) -> ())?,
	_visit: (() -> ())?,
}
export type ValidateOptions = { minimumFaceArea: number? }
export type ValidationReport = {
	valid: boolean,
	errors: { string },
	vertices: number,
	faces: number,
	boundaryEdges: number,
	nonmanifoldEdges: number,
	nonmanifoldVertices: number,
	duplicateFaces: number,
	zeroLengthEdges: number,
	looseVertices: number,
	eulerCharacteristic: number?,
	surfaceComponents: number?,
	windingErrors: number,
	degenerateFaces: number,
	closed: boolean,
}
-- Edge keys are "smallerId:largerId" (see Util.edge). directions holds +1/-1 per adjacent face.
export type TopologyEdge = { a: number, b: number, faces: { number }, directions: { number } }
export type MeshTopology = {
	edges: { [string]: TopologyEdge },
	neighbors: { [number]: { [number]: boolean } },
	vertexFaces: { [number]: { number } },
}
-- Three vertex IDs at [1..3], plus the source face and its corner indices.
export type Triangle = { [number]: number, face: number, corners: { number } }
export type Mesh = {
	vertices: { [number]: Vector3Value },
	faces: { [number]: Face },
	weights: { [number]: { [number]: number } },
	groups: { [string]: { [number]: number } },
	attributes: { [string]: Channel },
	nextVertex: number,
	nextFace: number,
	revision: number,
	addVertex: (Mesh, Vector3Value) -> number,
	addFace: (Mesh, { number }, { Corner }?, number?) -> number,
	setPosition: (Mesh, number, Vector3Value) -> (),
	removeFace: (Mesh, number) -> (),
	removeUnused: (Mesh) -> Mesh,
	clone: (Mesh) -> Mesh,
	bounds: (Mesh) -> (Vector3Value, Vector3Value),
	faceNormal: (Mesh, number) -> (Vector3Value, number),
	faceTriangles: (Mesh, number, TriangulationOptions?) -> { { number } },
	triangles: (Mesh) -> { Triangle },
	volume: (Mesh, Vector3Value?) -> number,
	validate: (Mesh, ValidateOptions?) -> ValidationReport,
	recalculateNormals: (Mesh, number?, { [string]: boolean }?) -> Mesh,
	topology: (Mesh) -> MeshTopology,
}
export type Texture = {
	width: number,
	height: number,
	pixels: buffer,
	set: (Texture, number, number, Color, number?) -> (),
	get: (Texture, number, number) -> (Color, number),
	clone: (Texture, Limits?) -> Texture,
	sample: (Texture, Vector2Value, boolean?, boolean?) -> (Color, number),
	map: (Texture, (Color, number, Vector2Value, number, number) -> (Color, number?), Limits?) -> Texture,
	resize: (Texture, number, number, Limits?) -> Texture,
	blend: (Texture, Texture, number?, Limits?) -> Texture,
	blur: (Texture, number, number?, Limits?) -> Texture,
	guided: (Texture, Texture, number, number, Limits?) -> Texture,
	normalFromHeight: (Texture, number?, Limits?) -> Texture,
	paint: (Texture, Vector2Value, number, Color, number?, Limits?) -> Texture,
	toRGBA8: (Texture, boolean?, Limits?) -> buffer,
	tiles: (Texture, number, Limits?) -> { Tile },
}
export type Tile = {
	texture: Texture,
	x: number,
	y: number,
	width: number,
	height: number,
	uvOffset: Vector2Value,
	uvScale: Vector2Value,
}
export type TextureLibrary = {
	new: (number, number, Color?, number?, Limits?) -> Texture,
	generate: (number, number, (Vector2Value, number, number) -> (Color, number?), Limits?) -> Texture,
	fromRGBA8: (number, number, buffer, boolean?, Limits?) -> Texture,
	noise: (number, number, number?, number?, number?, Limits?) -> Texture,
}
export type BakeOptions = Limits & {
	padding: number?,
	maxTriangles: number?,
	maxDistance: number?,
	samples: number?,
	distance: number?,
	bias: number?,
	occluder: Mesh?,
	occlusion: boolean?,
	facingThreshold: number?,
}
export type BakeContext = {
	position: Vector3Value,
	normal: Vector3Value,
	tangent: Vector3Value,
	bitangent: Vector3Value,
	uv: Vector2Value,
	face: number,
	barycentric: Vector3Value,
}
export type BakeReport = {
	coveredPixels: number,
	totalPixels: number,
	coverage: buffer,
	operation: Progress,
	-- rasterize only: faces skipped because they could not be triangulated
	skippedFaces: number?,
}
export type Camera = { frame: Frame, fov: number, width: number, height: number, principal: Vector2Value }
export type BakeLibrary = {
	rasterize: (
		Mesh,
		number,
		number,
		(BakeContext) -> (Color, number?),
		BakeOptions?
	) -> (Texture, BakeReport),
	dilate: (Texture, buffer, number, Limits?) -> Texture,
	normalMap: (Mesh, Mesh, number, number, BakeOptions?) -> (Texture, BakeReport),
	ambientOcclusion: (Mesh, number, number, BakeOptions?) -> (Texture, BakeReport),
	vertexOcclusion: (Mesh, BakeOptions?) -> ({ [number]: number }, Progress),
	pointSampler: ({ Vector3 }, { number }, number, { Vector3 }?) -> (Vector3, Vector3?) -> number?,
	heightOcclusion: ({ { number } }, any?) -> { { number } },
	slopeFit: ({ { number } }, { { Vector3? } }, any?) -> ({ { number } }, any),
	project: (Mesh, Texture, Camera, number, number, BakeOptions?) -> (Texture, BakeReport),
}
export type PublishOptions = Publishing.Options
export type PublishLedger = { Publishing.LedgerEntry }
export type PublishReport = {
	success: boolean,
	committed: boolean,
	rolledBack: boolean,
	stage: string,
	error: string?,
	rollbackErrors: { string },
	cleanupErrors: { string },
	assets: { { kind: string, id: string, resumed: boolean } },
	resumeAvailable: boolean,
	operation: Progress,
	-- publishImages / bundle.images: asset IDs of the standalone images, in input order
	imageIds: { string }?,
}
export type API = {
	Version: string,
	Texture: TextureLibrary,
	Bake: BakeLibrary,
	Mesh: { new: () -> Mesh },
	Roblox: { publish: (Publishing.Bundle, unknown, PublishOptions?) -> PublishReport, [string]: any },
	[string]: any, -- Legacy namespaces are explicitly not yet strict contracts.
}
return table.freeze({})
