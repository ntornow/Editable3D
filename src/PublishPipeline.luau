--!strict
local Budget = require(script.Parent.OperationBudget)
local Transaction = require(script.Parent.PublishTransaction)
local Retry = require(script.Parent.PublishRetry)
-- fingerprint: the content snapshot, or its digest when digested (backend.digest). object: entries made before
-- 0.102 held their source directly; newer entries refer to it weakly (see sources below).
export type LedgerEntry = {
	kind: string,
	id: string,
	fingerprint: unknown,
	digested: boolean?,
	object: unknown?,
}
export type Map = { object: unknown, read: () -> unknown, write: (unknown) -> (), original: unknown }
export type Backend = {
	upload: (unknown, string, unknown) -> string,
	load: (string, string) -> unknown,
	snapshot: (unknown, string, Budget.Budget) -> unknown,
	-- Optional content equivalence (for example tolerant normals); defaults to ==.
	equivalent: ((string, unknown, unknown) -> boolean)?,
	-- Optional compact digest of a snapshot: the resume ledger keeps it instead of the content.
	digest: ((string, unknown) -> string)?,
	destroy: (unknown) -> (),
	backup: (unknown) -> unknown,
	stage: (string, unknown) -> unknown,
	apply: (unknown, unknown) -> (),
	restore: (unknown, unknown) -> (),
	maps: (unknown) -> { Map },
	uri: (string) -> unknown,
	guard: (unknown) -> () -> (),
	sleep: (number) -> (),
}
export type Options = Budget.Options & Retry.Options & { resume: { LedgerEntry }? }
-- A materialsOnly handle has no editable mesh: the part keeps its mesh and only its maps publish.
-- images: standalone images (no part) to publish and verify; their IDs come back in imageIds.
export type Bundle = {
	handles: { { editable: unknown, part: unknown, materialsOnly: boolean? } },
	images: { unknown }?,
}
local P = {}
-- The resume ledger refers to its source objects weakly (entry -> object), so a ledger kept for a whole session
-- does not keep every published editable alive. An entry whose object has been collected can never match again;
-- it is dropped at the start of the next publish (or by P.pruneLedger).
local sources: { [any]: unknown } = setmetatable({}, { __mode = "kv" }) :: any
local function sourceOf(entry: LedgerEntry): unknown
	local object = sources[entry]
	if object == nil then
		object = entry.object
	end
	return object
end
-- Removes the entries whose source objects have been garbage collected; returns how many.
function P.pruneLedger(ledger: { LedgerEntry }): number
	local n, kept = #ledger, 0
	for i = 1, n do
		local entry = ledger[i]
		if sourceOf(entry) ~= nil then
			kept += 1
			ledger[kept] = entry
		end
	end
	for i = n, kept + 1, -1 do
		ledger[i] = nil
	end
	return n - kept
end
function P.run(bundle: Bundle, metadata: unknown, options: Options?, backend: Backend)
	local o: Options = options or {}
	Retry.validate(o)
	local budget = Budget.new(o, "Roblox.publish")
	local ledger: { LedgerEntry } = o.resume or {}
	P.pruneLedger(ledger)
	local assets: { { kind: string, id: string, resumed: boolean } } = {}
	local imageIds: { string } = {}
	local report = Transaction.run(function(context)
		local verified: { LedgerEntry } = {}
		local seenParts: { [unknown]: boolean } = {}
		local actions: { Transaction.Action } = {}
		local guards: { () -> () } = {}
		local function check()
			budget:step()
			budget:check()
		end
		local function same(kind: string, a: unknown, b: unknown): boolean
			local equivalent = backend.equivalent
			if equivalent then
				return equivalent(kind, a, b)
			end
			return a == b
		end
		local function asset(object: unknown, kind: string): string
			for _, entry in verified do
				if entry.object == object then
					return entry.id
				end
			end
			check()
			context.phase("snapshot")
			local fingerprint = backend.snapshot(object, kind, budget)
			local digest = backend.digest
			local stamp: unknown = if digest then digest(kind, fingerprint) else fingerprint
			local id: string? = nil
			for _, entry in ledger do
				if sourceOf(entry) == object then
					local unchanged = if entry.digested
						then digest ~= nil and entry.fingerprint == stamp
						else same(kind, entry.fingerprint, fingerprint)
					if not (entry.kind == kind and unchanged) then
						-- the same object was uploaded earlier with this ledger and has changed since: edited,
						-- or destroyed (a destroyed EditableImage reads as 1x1), e.g. by a sweep of the session
						error(
							"Resume source changed: this "
								.. kind
								.. " was published earlier with this ledger and has changed since (edited or destroyed);"
								.. " publish a new object, or use a fresh resume ledger for new content",
							0
						)
					end
					id = entry.id
					break
				end
			end
			local resumed = id ~= nil
			if not id then
				context.phase("upload")
				check()
				id = backend.upload(object, kind, metadata) -- Never retry an ambiguous asset creation.
				assert(type(id) == "string" and id ~= "", "Upload returned no asset ID")
				local entry: LedgerEntry =
					{ kind = kind, id = id :: string, fingerprint = stamp, digested = digest ~= nil }
				sources[entry] = object
				table.insert(ledger, entry)
			end
			local assetId = id :: string
			table.insert(assets, { kind = kind, id = assetId, resumed = resumed })
			context.phase("readback")
			local copy = Retry.run(function()
				return backend.load(assetId, kind)
			end, o, check, backend.sleep)
			local disposed = false
			context.defer(function()
				if not disposed then
					backend.destroy(copy)
				end
			end)
			local actual = backend.snapshot(copy, kind, budget)
			assert(same(kind, fingerprint, actual), "Published " .. kind .. " content mismatch")
			backend.destroy(copy)
			disposed = true
			table.insert(verified, { object = object, kind = kind, id = assetId, fingerprint = fingerprint })
			return assetId
		end
		for _, handle in bundle.handles do
			check()
			local materialsOnly = handle.materialsOnly == true
			assert(
				handle.part ~= nil and (handle.editable ~= nil) ~= materialsOnly,
				"Incomplete publish handle"
			)
			assert(not seenParts[handle.part], "Duplicate publish part")
			seenParts[handle.part] = true
			table.insert(guards, backend.guard(handle.part))
			if not materialsOnly then
				local backup = backend.backup(handle.part)
				context.defer(function()
					backend.destroy(backup)
				end)
				local id = asset(handle.editable, "Mesh")
				context.phase("stage")
				local staged = Retry.run(function()
					return backend.stage(id, handle.part)
				end, o, check, backend.sleep)
				context.defer(function()
					backend.destroy(staged)
				end)
				table.insert(actions, {
					name = "mesh",
					apply = function()
						backend.apply(handle.part, staged)
					end,
					rollback = function()
						backend.restore(handle.part, backup)
					end,
				})
			end
			local maps = backend.maps(handle.part)
			assert(not materialsOnly or #maps > 0, "Materials-only part has no editable maps")
			for _, map in maps do
				local imageId = asset(map.object, "Image")
				local replacement = backend.uri(imageId)
				table.insert(guards, function()
					assert(map.read() == map.original, "Surface material changed during publishing")
				end)
				table.insert(actions, {
					name = "image",
					apply = function()
						map.write(replacement)
					end,
					rollback = function()
						map.write(map.original)
					end,
				})
			end
		end
		local images: { unknown } = bundle.images or {}
		for index, image in images do
			imageIds[index] = asset(image, "Image")
		end
		return {
			actions = actions,
			validate = function()
				context.phase("validate")
				-- No user callbacks/yields between the final source/scene guard and synchronous commit.
				budget.checkpoint = nil
				budget.cancelled = nil
				budget.onComplete = nil
				for _, entry in verified do
					assert(
						same(
							entry.kind,
							entry.fingerprint,
							backend.snapshot(entry.object, entry.kind, budget)
						),
						"Source changed during publishing"
					)
				end
				for _, guard in guards do
					guard()
				end
			end,
		}
	end, {
		check = function()
			budget:check()
		end,
	})
	return {
		success = report.success,
		committed = report.committed,
		rolledBack = report.rolledBack,
		stage = report.stage,
		error = report.error,
		rollbackErrors = report.rollbackErrors,
		cleanupErrors = report.cleanupErrors,
		assets = assets,
		resumeAvailable = o.resume ~= nil,
		imageIds = imageIds,
		operation = budget:report(),
	}
end
-- Publishes a bundle as consecutive transactions of at most `perTransaction` parts. Each chunk gets its own
-- operation budget (the budget counts total allocations, and every part is snapshotted several times, so
-- one transaction over a large bundle can exceed maxBytes) and all chunks share one resume ledger
-- (options.resume, or a fresh one), so a texture shared by every part uploads once. Each chunk is atomic;
-- a failure stops before the later chunks and the committed ones stay. bundle.images go with the last chunk.
function P.runChunked(
	bundle: Bundle,
	metadata: unknown,
	options: Options?,
	backend: Backend,
	perTransaction: number
)
	assert(
		type(perTransaction) == "number" and perTransaction >= 1 and perTransaction % 1 == 0,
		"Invalid parts per transaction"
	)
	local o: any = table.clone((options or {}) :: any)
	o.resume = o.resume or {}
	local handles = bundle.handles
	local n = #handles
	local count = math.max(1, math.ceil(n / perTransaction))
	local chunks = {}
	local assets: { { kind: string, id: string, resumed: boolean } } = {}
	local rollbackErrors, cleanupErrors = {}, {}
	local committedParts = 0
	local failed = nil
	for k = 1, count do
		local first, last = (k - 1) * perTransaction + 1, math.min(k * perTransaction, n)
		local sub: Bundle = { handles = table.move(handles, first, last, 1, {}) }
		if k == count then
			sub.images = bundle.images
		end
		local r = P.run(sub, metadata, o, backend)
		table.insert(chunks, r)
		for _, a in r.assets do
			table.insert(assets, a)
		end
		for _, e in r.rollbackErrors do
			table.insert(rollbackErrors, e)
		end
		for _, e in r.cleanupErrors do
			table.insert(cleanupErrors, e)
		end
		if not r.success then
			failed = r
			break
		end
		committedParts += last - first + 1
	end
	local final = failed or chunks[#chunks]
	return {
		success = failed == nil,
		committed = failed == nil,
		partial = failed ~= nil and committedParts > 0,
		committedParts = committedParts,
		rolledBack = failed ~= nil and failed.rolledBack,
		stage = final.stage,
		error = failed and failed.error,
		rollbackErrors = rollbackErrors,
		cleanupErrors = cleanupErrors,
		assets = assets,
		resumeAvailable = true,
		resume = o.resume,
		imageIds = failed == nil and final.imageIds or {},
		chunks = chunks,
		operation = final.operation,
	}
end
return table.freeze(P)
