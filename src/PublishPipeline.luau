--!strict
local Budget = require(script.Parent.OperationBudget)
local Transaction = require(script.Parent.PublishTransaction)
local Retry = require(script.Parent.PublishRetry)
export type LedgerEntry = { object: unknown, kind: string, id: string, fingerprint: unknown }
export type Map = { object: unknown, read: () -> unknown, write: (unknown) -> (), original: unknown }
export type Backend = {
	upload: (unknown, string, unknown) -> string,
	load: (string, string) -> unknown,
	snapshot: (unknown, string, Budget.Budget) -> unknown,
	-- Optional content equivalence (for example tolerant normals); defaults to ==.
	equivalent: ((string, unknown, unknown) -> boolean)?,
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
export type Bundle = { handles: { { editable: unknown, part: unknown } } }
local P = {}
function P.run(bundle: Bundle, metadata: unknown, options: Options?, backend: Backend)
	local o: Options = options or {}
	Retry.validate(o)
	local budget = Budget.new(o, "Roblox.publish")
	local ledger: { LedgerEntry } = o.resume or {}
	local assets: { { kind: string, id: string, resumed: boolean } } = {}
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
			local id: string? = nil
			for _, entry in ledger do
				if entry.object == object then
					assert(
						entry.kind == kind and same(kind, entry.fingerprint, fingerprint),
						"Resume source changed"
					)
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
				table.insert(ledger, { object = object, kind = kind, id = id, fingerprint = fingerprint })
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
			assert(handle.part ~= nil and handle.editable ~= nil, "Incomplete publish handle")
			assert(not seenParts[handle.part], "Duplicate publish part")
			seenParts[handle.part] = true
			table.insert(guards, backend.guard(handle.part))
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
			for _, map in backend.maps(handle.part) do
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
		operation = budget:report(),
	}
end
return table.freeze(P)
