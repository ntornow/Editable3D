# glTF 2.0 interchange

`Editable3D.GLTF` is an original Luau reader/writer for a defined subset of [Khronos glTF 2.0](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html). It operates entirely on supplied strings, buffers, authoring meshes, and scene tables. It never fetches a URI, downloads a model, edits Studio, or publishes an asset. It is not a complete glTF implementation or a full schema validator.

```lua
local E = require(game.ReplicatedStorage.Editable3D)
local scene = E.GLTF.fromMesh(myOriginalMesh)
local glb = E.GLTF.toGLB(scene) -- Roblox buffer containing a GLB file
local restored = E.GLTF.fromGLB(glb)
local worldMesh = E.GLTF.meshAt(restored, 1)
```

## Functions

| Function | Result |
|---|---|
| `fromDocument(document, sources?)` | Import a decoded glTF JSON table into a scene. |
| `fromJSON(json, sources?)` | Decode and import a JSON string. |
| `fromGLB(bufferOrString, sources?)` | Parse a binary GLB and import its scene. |
| `toDocument(scene)` | Return a decoded glTF table and a one-element array of binary buffers. |
| `toJSON(scene, bufferURI?)` | Return JSON and buffers. Without a URI, buffer bytes are embedded as base64. With a URI, the caller must store the returned buffer at that URI. |
| `toGLB(scene)` | Return a self-contained GLB buffer, including supplied image bytes. |
| `fromMesh(mesh, options?)` | Clone one authoring mesh into a scene. Options: `name`, `materials`. Omitted materials are synthesized from face material slots. |
| `fromRig(mesh, rig, options?)` | Create a scene from an `Editable3D.Rig`, remapping arbitrary bone IDs to skin slots and generating inverse bind matrices. |
| `worldMatrices(scene, pose?)` | Evaluate all node transforms. A pose maps node indices to replacement local matrices. |
| `meshAt(scene, nodeIndex, pose?)` | Evaluate one mesh instance in world coordinates, including linear blend skinning. |
| `sampleAnimation(scene, animationIndex, seconds, options?)` | Return `{transforms, weights, time}` for `meshAt`/`worldMatrices`. Options: `loop`, `pingPong`. |
| `readAccessor(document, sources, zeroBasedAccessorIndex)` | Decode one accessor as an array of numeric tuples; useful for low-level interchange. |

`sources` may contain one-based buffer entries (`sources[1]`) or external-URI keys (`sources["geometry.bin"]`). Values are Roblox buffers or binary strings. Data URIs are decoded directly. Images with external URIs must also be supplied under their URI keys. No callback is invoked, and no network access takes place.

## Scene representation

All scene array references use **one-based indices**. Raw glTF JSON and copied material/texture/sampler/camera descriptors retain their standard **zero-based indices**. Distinguishing the two prevents accidental off-by-one errors.

```lua
{
    meshes = { authoringMesh }, -- Editable3D.Mesh instances, local geometry
    meshNames = { "Mesh" },
    nodes = {
        { name = "Instance", mesh = 1, skin = nil,
          matrix = { 1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1 }, children = {} },
    },
    skins = {},
    scenes = { { nodes = { 1 } } }, scene = 1,
    materials = {}, textures = {}, samplers = {}, cameras = {},
    images = { -- optional; raw PNG/JPEG bytes, not decoded raster pixels
        -- { name = "Albedo", mimeType = "image/png", data = pngBuffer }
    },
    warnings = {},
}
```

Matrices are sixteen-number **column-major** affine arrays. Values follow glTF's right-handed, Y-up convention and metre units. There is no implicit unit conversion, axis reflection, or UV flip. Convert units deliberately when passing world geometry to the Roblox backend.

Each skin is `{joints = {nodeIndex, ...}, inverseBindMatrices = {matrix, ...}, skeleton = nodeIndex?}`. Authoring mesh weights in a GLTF scene are keyed by **one-based skin-joint slot**, not node index or arbitrary Rig bone ID. `fromRig` performs this mapping. Multiple nodes may share a mesh; `meshAt` evaluates the requested instance.

`meshAt` uses `jointWorld * inverseBindMatrix` for skinning in world coordinates; this matches glTF's cancellation of the skinned mesh node transform. Ordinary unskinned normals use the inverse transpose. Negative-determinant unskinned transforms reverse face winding and tangent handedness. Skinned normals use the inverse transpose of each vertex's blended affine matrix; singular blends reject. Tangents are removed after skin deformation because they require regeneration. Exported/restored vertex IDs need not match source IDs.

## Supported data

- JSON `.gltf` with in-memory external buffers, base64 data URIs, or binary GLB version 2.
- Bounds-checked typed accessors: signed/unsigned bytes and shorts, unsigned integers, floats, normalization, byte stride, sparse replacements, column-major matrix padding, and optional final matrix padding.
- Indexed/unindexed triangles, triangle strips, and triangle fans. Degenerate repeated-index triangles are skipped. Exports are indexed triangles; simple polygons use the existing mesh triangulator.
- `POSITION`, `NORMAL`, `TANGENT`, `TEXCOORD_0`, `TEXCOORD_1`, `COLOR_0`, `JOINTS_0/1`, and `WEIGHTS_0/1`. Corner fields are `normal`, `tangent`, `tangentSign`, `uv`, `uv1`, `color`, and `alpha`.
- Per-corner discontinuities become separate glTF attribute vertices. Material slots split primitives. Mesh face material `0` denotes glTF's unspecified default material; positive slots correspond to `scene.materials`.
- Node hierarchy, instancing, matrix/TRS transforms, general affine world evaluation, skin joints and inverse bind matrices, and up to eight exported influences per vertex. `fromRig` normalizes weights explicitly. Import normalizes small integer-quantization errors and rejects substantial non-unit weight sums.
- Core PBR material descriptors, texture/sampler descriptors, camera descriptors, and raw PNG/JPEG payload preservation. Image data is opaque; this module is not a PNG/JPEG codec or material renderer.
- Sparse/dense morph deltas for position, normal, tangent, UV sets 0/1 and color 0, mesh defaults and per-node weights; shape keys evaluate before skin/world transforms. Export includes morph corner differences when splitting attribute vertices.
- Translation, rotation, scale and morph-weight animation, with STEP, LINEAR and CUBICSPLINE interpolation. Rotation LINEAR uses shortest-arc quaternion SLERP. Cubic tangents are derivatives per second; rotation results are normalized. Float output and normalized byte/short rotation or weight output are supported.
- Deterministic vertex/face/material traversal and four-byte-aligned GLB output.

If some corners lack UVs or colors where other corners have them, export supplies `(0,0)` UVs and white color with alpha one. Missing normals within a normal-bearing primitive use face normals. Partial tangent attributes reject because inventing tangent frames would be misleading.

## Explicit boundaries

Draco, Meshopt, required extensions, non-triangle primitives, unknown/custom vertex attributes, additional UV/color sets, more than eight influences on export, and image types other than PNG/JPEG reject. Implementations are not represented by placeholder successes.

Optional extensions are not evaluated. Import records their names in `scene.warnings`; copied material/texture/camera descriptors may retain extension metadata, but this is **not lossless extension round-tripping**. Unknown node/mesh extras and extension structures are not preserved. `extensionsUsed` names are retained for surviving metadata. Use a dedicated extension implementation before depending on its visual or geometric semantics.

This module does not infer `Editable3D.Rig` objects from arbitrary imported joint graphs; it preserves those graphs and evaluates their skinning directly. It does not automatically merge disconnected vertices, reconstruct quads, decode textures, build Roblox Instances, transfer skin weights to Roblox bones, or publish assets. `meshAt` rejects singular transforms. Local node matrices containing shear reject on import/export, as glTF requires local transforms to be decomposable into TRS; composed world matrices can contain shear. Numerical output is float32 geometry, as specified by glTF.

## Verification

`scene.morphTargets[meshIndex]` contains `Morph` delta records; `scene.meshWeights[meshIndex]` and `node.weights` provide defaults. `scene.animations` contains `Timeline.clip` records with channels whose `node` is a one-based scene index. Imported nodes retain their rest TRS in `node.trs` alongside `node.matrix`. Matrix edits take precedence when the two differ. Animated export emits TRS, preserving reflected scales; zero-scale animated nodes require explicit matching TRS. glTF inputs that animate matrix-defined nodes reject as required by the core format. Channels without target nodes are ignored with a recorded warning.

```lua
local pose = E.GLTF.sampleAnimation(scene, 1, 0.5)
local posed = E.GLTF.meshAt(scene, 1, pose)
```

Legacy node-to-matrix pose tables still work. `meshAt` normalizes morphed normals/tangents and supplies flat normals when absent. Skinning still clears tangents for rebaking. No animation runs on its own, and no Roblox Animation asset is created. See [MOTION.md](MOTION.md) for authoring channels and shape keys.

`tests/GLTFTests.luau` runs on demand with the Editable3D API. It includes byte fixtures authored independently of the exporter, malformed inputs, accessor padding/normalization/sparse cases, transform and strip winding checks, corner/material round trips, opaque image preservation, and an independently calculated rig-motion expectation. Run:

```lua
local report = require(package.GLTFTests)(require(package))
assert(report.failed == 0)
```

`GLTFMotionTests` adds independent binary and analytic cases for all interpolation modes, integer quaternion output, flattened multi-target cubic weights, morph-before-skin behavior, corner seams, reflected transforms, and invalid animations/morphs. The test module's placement depends on how the package is installed; requiring it with the API table is the stable interface. `examples/GLTFRoundtrip.luau` and `examples/AnimatedMorph.luau` return original procedural geometry and GLB data without changing the scene.
