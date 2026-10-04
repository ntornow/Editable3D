--!strict
-- Public boundary contracts. Roblox supplies the native value types in Studio.
local Budget = require(script.Parent.OperationBudget)
local Publishing = require(script.Parent.PublishPipeline)
export type Limits = Budget.Options
export type Progress = Budget.Progress
export type Vector2Value = typeof(Vector2.new())
export type Vector3Value = typeof(Vector3.new())
export type Color = typeof(Color3.new())
export type Frame = typeof(CFrame.new())
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
	faceNormal: (Mesh, number) -> Vector3Value,
	triangles: (Mesh) -> { any },
	validate: (Mesh, any?) -> { [string]: any },
	recalculateNormals: (Mesh, number?, { [string]: boolean }?) -> Mesh,
	volume: (Mesh, Vector3Value?) -> number,
	topology: (Mesh) -> { [string]: any },
	faceTriangles: (Mesh, number, any?) -> { any },
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
export type BakeReport = { coveredPixels: number, totalPixels: number, coverage: buffer, operation: Progress }
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
