# Production contracts

Version 0.76.0 adds bounded texture/bake operations, typed public boundaries and transactional publishing. These contracts apply to the documented authoring scope, not complete Blender feature parity. Other geometry, rendering and simulation operators retain the limits in their individual guides.

## Typed callers

`src/Types.luau` exports mesh, texture, bake, limit and publishing contracts. The package root lists every namespace explicitly, so a strict caller gets each namespace's real type, and re-exports `Mesh`, `Corner`, `Face`, `Texture`, `Limits`, `BakeOptions`, `PublishOptions`, `PublishReport`, `ValidationReport` and `API`. Use a statically resolved require in a strict caller:

```lua
--!strict
local E = require(game.ReplicatedStorage.Editable3D)
local mesh: E.Mesh = E.Subdivision.catmullClark(E.Primitives.box(Vector3.new(4, 4, 4)), 2)
local report: E.ValidationReport = mesh:validate()
local texture: E.Texture = E.Texture.new(256, 256)
local options: E.Limits = {maxPixels = 1024 * 1024, maxSeconds = 5}
local resized: E.Texture = texture:resize(512, 512, options)
```

Every public namespace is strict, along with the contracts, the resource budget and the publishing pipeline (76 modules; `STRICT_MODULES` in `tools/check_types.py`). Public functions have parameter and return types, and `Roblox` uses the engine classes (`EditableMesh`, `MeshPart`, `Model`, `SurfaceAppearance`). Where a namespace forwards options or results to an internal module that is not strict yet (for example the exact-arithmetic intersection, trimming and solver helpers), those tables are typed as open tables or `any`, so some report fields are untyped. The internal helpers themselves are type-checked in nonstrict mode with real Roblox types.

The validation gate type-checks the whole package against the Roblox API definitions and rejects a set of invalid usages (for example a number passed as a vertex position, or a number to `IO.encode`). See [MAINTAINING.md](MAINTAINING.md).

## Texture and bake limits

Every allocating or iterative `Texture` operation accepts an optional trailing limits table. Existing argument order and return values are preserved. `get`, `set` and `sample` are constant-size operations without a budget. `Bake` merges limits into its existing options; `Bake.dilate` adds a fourth options argument.

| Field | Default | Contract |
| --- | ---: | --- |
| `maxWork` | 100,000,000 | Counted pixel, kernel, triangle and sample work; positive integer |
| `maxBytes` | 268,435,456 | Cumulative accounted buffer/scratch allocations, checked before allocation |
| `maxPixels` | 16,777,216 | Maximum pixels in each allocated image |
| `maxSeconds` | 60 | Cooperative elapsed-time limit, including callback/yield time |
| `checkpointEvery` | 4,096 | Counted work between checkpoints |
| `cancelled` | nil | Callback returning true to cancel |
| `checkpoint` | nil | Callback receiving `{operation, work, allocatedBytes, elapsedSeconds}`; may yield |
| `onComplete` | nil | One callback for successful outer texture/bake operation |
| `maxTriangles` (Bake only) | 250,000 | Input triangle bound before triangulation/spatial construction |

Limits must be finite and positive; integer counts cannot be fractional. Work charges are operation-specific and deterministic, not CPU instruction counts. `maxBytes` covers explicit image buffers and estimated scratch records; it is **not a hard process-memory or peak-heap cap**. Lua tables, engine allocations and callbacks may consume additional memory. Progress operation names identify the budget owner; simple wrappers can report `Texture.generate` or `Texture.clone`. Nested operations share a budget, so blur passes, tiles, padding and AO rays cannot reset limits. `_budget` is reserved for internal calls.

Exceeded limits, cancellation and callback failures raise errors. Texture/bake inputs remain unchanged by the library; no partial output is returned. Caller callbacks must not mutate inputs if that guarantee is needed. Catch errors with `pcall`. `Bake` reports include `operation` counters alongside the existing coverage data.

```lua
local cancelled = false
local ok, output = pcall(function()
    return source:blur(4, 2, {
        maxWork = 2000000,
        maxBytes = 8 * 1024 * 1024,
        cancelled = function() return cancelled end,
        checkpoint = function(progress)
            -- Update a progress display here; yielding permits cancellation input.
            task.wait()
        end,
    })
end)
```

Cancellation is cooperative. It cannot interrupt an engine request, a single callback, triangulation or a BVH construction already executing. Bake input limits bound those stages, and budgets are checked before and after them. Shader callbacks and individual spatial queries must finish before cancellation takes effect. Time limits do not provide hard real-time preemption.

## Publishing transaction

`Roblox.publish(bundle, metadata, options?)` snapshots sources, creates assets, independently reloads their content, stages replacement MeshParts, then validates sources and scene references before a synchronous commit. No asset is created merely by requiring the library or building a bundle. Base-part `TextureContent` and all five SurfaceAppearance image maps participate in the same transaction. Existing URI textures are preserved while mesh content is replaced. The adapter preserves fidelity settings because [Roblox ApplyMesh copies both geometry and texture/fidelity properties](https://create.roblox.com/docs/reference/engine/classes/MeshPart#ApplyMesh).

The native verifier compares positions, triangle winding, corner UVs/normals/colors/alpha, vertex incidence, bone hierarchy/bind frames/virtual state/weights, and exact image bytes. IDs and enumeration order may change. Finite values are compared as exact float32 values. A backend that quantizes or changes content fails verification even when counts agree. FACS poses and ambiguous duplicate bone paths are rejected before their upload because their equivalence is not covered by this verifier. Coincident symmetric topology cannot be distinguished in every graph-isomorphism case by the canonical incidence representation; this is content validation, not a formal isomorphism proof.

Options include the resource limits above plus:

| Field | Default | Contract |
| --- | --- | --- |
| `attempts` | 3 | 1–10 attempts for idempotent readback/staging only |
| `retryDelay` | 0.25 | Nonnegative finite seconds; exponential backoff |
| `resume` | nil | Caller-owned in-memory ledger; retain it after a failed attempt |

Asset creation is never automatically retried because an ambiguous response could otherwise create duplicates. A returned ID enters the resume ledger immediately. Retrying with that same ledger reuses the ID only if its source fingerprint still matches, then verifies the readback again. The ledger contains native object references and binary fingerprints; do not JSON-serialize it. The report's `assets` list is serializable. An upload which succeeds remotely but returns no ID cannot be recovered automatically. Created assets remain in the account after a later failure; rollback concerns scene references, not deletion of uploaded assets.

```lua
local ledger = {}
local report = E.Roblox.publish(bundle, metadata, {
    resume = ledger,
    attempts = 3,
    cancelled = function() return cancelRequested end,
})
if not report.success then
    warn(report.stage, report.error, report.rollbackErrors)
    -- Retain source objects and ledger for inspection or a deliberate retry.
end
```

Preparation failures leave live references unchanged. Failed commit actions, including one that partially changed a part, roll back in reverse order. Original mesh content, texture, fidelity settings, size, CFrame and touched surface maps are restored when rollback succeeds. Parts must be Archivable to create rollback backups. Temporary readbacks, backups and staged parts are always scheduled for cleanup. `success`, `committed`, `rolledBack`, `stage`, `error`, `rollbackErrors`, `cleanupErrors`, `assets`, `resumeAvailable` and `operation` make partial outcomes explicit. A cleanup failure can coexist with a successful commit; inspect `cleanupErrors`. A rollback failure is reported instead of claiming restoration.

Invalid options and cancellation before preparation raise before external effects. Failures after preparation begins return a failure report. Progress/cancellation callbacks are used during preparation; they are disabled for the final source/scene guard and synchronous commit so user code cannot yield between validation and mutation. Publishing returns counters directly and does not invoke `onComplete`.

Readback/staging are tested with fault-injection adapters and native in-memory Roblox content. Automated tests **do not create remote assets**. Service permissions, moderation, ownership and remote availability still require a release-specific publishing smoke test when an actual asset publication is authorized.
