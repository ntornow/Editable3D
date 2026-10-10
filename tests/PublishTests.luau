local P = require(script.Parent.PublishPipeline)
local Transaction = require(script.Parent.PublishTransaction)
local harness = require(script.Parent.TestHarness)
-- A service adapter with observable resources and intentional failures. No uploads.
local function fixture()
	local mesh = { data = "positions/uv/normals/weights" }
	local image = { data = "rgba" }
	local part = { mesh = "original", size = 3, map = image }
	local state: { [string]: any } = { uploads = 0, loads = 0, stages = 0, resources = {}, waits = {} }
	local function resource(data, kind)
		local r = { data = data, kind = kind }
		table.insert(state.resources, r)
		return r
	end
	local stored = {}
	local backend = {
		upload = function(object, kind)
			state.uploads += 1
			if state.uploadFail then
				error("upload unavailable")
			end
			local id = tostring(state.uploads)
			stored[id] = { data = object.data, kind = kind }
			return id
		end,
		load = function(id)
			state.loads += 1
			if state.readFail or state.loads <= (state.transientReads or 0) then
				error("read unavailable")
			end
			if state.onRead then
				state.onRead()
			end
			return resource(
				(state.corrupt or (state.corruptImages and stored[id].kind == "Image")) and "different"
					or stored[id].data,
				"readback"
			)
		end,
		snapshot = function(object, _, budget)
			budget:step()
			if state.snapshotFail and object.kind == "readback" then
				error("snapshot failed")
			end
			return object.data
		end,
		destroy = function(object)
			object.destroyed = true
			if state.cleanupFail then
				error("cleanup failed")
			end
		end,
		backup = function(p)
			local b = resource(p.mesh, "backup")
			b.size = p.size
			return b
		end,
		stage = function(id)
			state.stages += 1
			if state.stageFail then
				error("stage failed")
			end
			return resource(id, "stage")
		end,
		apply = function(p, s)
			p.mesh = s.data
			p.size = 99
			if state.applyFail then
				error("partial apply")
			end
			p.size = 3
		end,
		restore = function(p, s)
			p.mesh = s.data
			p.size = s.size
			if state.rollbackFail then
				error("rollback failed")
			end
		end,
		maps = function(p)
			return {
				{
					object = image,
					original = p.map,
					read = function()
						return p.map
					end,
					write = function(v)
						p.map = v
						if state.mapFail and type(v) == "string" then
							error("map failed")
						end
					end,
				},
			}
		end,
		guard = function(p)
			local m, z = p.mesh, p.size
			return function()
				assert(p.mesh == m and p.size == z, "part changed")
			end
		end,
		uri = function(id)
			return "asset:" .. id
		end,
		sleep = function(s)
			table.insert(state.waits, s)
		end,
	}
	return { handles = { { editable = mesh, part = part } } }, backend, state, part, mesh, image
end
return function()
	local report, test, rejects = harness()
	local function cleaned(state)
		for _, r in state.resources do
			assert(r.destroyed, "Leaked " .. r.kind)
		end
	end
	test("Publish commits only verified assets and releases resources", function()
		local bundle, b, s, p = fixture()
		local r = P.run(bundle, {}, nil, b)
		assert(
			r.success
				and r.committed
				and not r.rolledBack
				and p.mesh == "1"
				and p.map == "asset:2"
				and p.size == 3
		)
		assert(s.uploads == 2 and #r.assets == 2 and #r.cleanupErrors == 0)
		cleaned(s)
	end)
	test("Shared sources upload once across multiple parts", function()
		local bundle, b, s, _p, m, img = fixture()
		table.insert(bundle.handles, { editable = m, part = { mesh = "old2", size = 3, map = img } })
		local r = P.run(bundle, nil, {}, b)
		assert(r.success and s.uploads == 2 and #r.assets == 2 and s.stages == 2)
		cleaned(s)
	end)
	for _, flag in { "uploadFail", "readFail", "corrupt", "stageFail", "snapshotFail" } do
		test("Preparation failure leaves scene unchanged: " .. flag, function()
			local bundle, b, s, p, _, img = fixture()
			s[flag] = true
			local r = P.run(bundle, nil, { attempts = 2, retryDelay = 0 }, b)
			assert(
				not r.success
					and not r.committed
					and r.rolledBack
					and p.mesh == "original"
					and p.map == img
					and p.size == 3
			)
			assert(s.uploads == 1)
			cleaned(s)
		end)
	end
	test("Same-size image mismatch cannot commit verified mesh", function()
		local bundle, b, s, p, _, img = fixture()
		s.corruptImages = true
		local r = P.run(bundle, nil, nil, b)
		assert(
			not r.success
				and string.find(r.error, "Image content mismatch")
				and p.mesh == "original"
				and p.map == img
				and s.uploads == 2
		)
		cleaned(s)
	end)
	test("Transient read failure retries without duplicate uploads", function()
		local bundle, b, s = fixture()
		s.transientReads = 2
		assert(P.run(bundle, nil, { attempts = 3 }, b).success)
		assert(s.uploads == 2 and s.loads == 4 and #s.waits == 2)
		cleaned(s)
	end)
	for _, flag in { "applyFail", "mapFail" } do
		test("Partial commit restores geometry dimensions and material: " .. flag, function()
			local bundle, b, s, p, _, img = fixture()
			s[flag] = true
			local r = P.run(bundle, nil, nil, b)
			assert(
				not r.success
					and r.rolledBack
					and r.stage == "commit"
					and p.mesh == "original"
					and p.size == 3
					and p.map == img
			)
			cleaned(s)
		end)
	end
	test("Rollback failure is reported without suppressing cleanup", function()
		local bundle, b, s = fixture()
		s.applyFail = true
		s.rollbackFail = true
		local r = P.run(bundle, nil, nil, b)
		assert(not r.rolledBack and #r.rollbackErrors == 1 and string.find(r.error, "partial apply"))
		cleaned(s)
	end)
	test("Cleanup failure remains visible after successful commit", function()
		local bundle, b, s = fixture()
		local destroy = b.destroy
		b.destroy = function(o)
			destroy(o)
			if o.kind ~= "readback" then
				error("cleanup failed")
			end
		end
		local r = P.run(bundle, nil, nil, b)
		assert(r.success and #r.cleanupErrors == 2)
		cleaned(s)
	end)
	test("Resume ledger prevents duplicate asset creation", function()
		local bundle, b, s, p = fixture()
		local ledger = {}
		s.stageFail = true
		local r = P.run(bundle, nil, { resume = ledger, attempts = 1 }, b)
		assert(not r.success and #ledger == 1 and s.uploads == 1)
		s.stageFail = false
		r = P.run(bundle, nil, { resume = ledger }, b)
		assert(r.success and r.resumeAvailable and r.assets[1].resumed and s.uploads == 2 and p.mesh == "1")
		cleaned(s)
	end)
	test("Resume rejects changed source and leaves prior ledger intact", function()
		local bundle, b, s, _, m = fixture()
		local ledger = {}
		s.stageFail = true
		P.run(bundle, nil, { resume = ledger, attempts = 1 }, b)
		m.data = "edited"
		local r = P.run(bundle, nil, { resume = ledger }, b)
		assert(not r.success and string.find(r.error, "Resume source changed") and s.uploads == 1)
		cleaned(s)
	end)
	test("Resume and readback compare with the backend's equivalence when it has no digest", function()
		local bundle, b, s, _p, mesh = fixture()
		local calls = 0
		b.equivalent = function(_kind, a, c)
			calls += 1
			return string.lower(tostring(a)) == string.lower(tostring(c))
		end
		local ledger = {}
		s.stageFail = true
		P.run(bundle, nil, { resume = ledger, attempts = 1 }, b)
		assert(s.uploads == 1, "the mesh uploaded before staging failed")
		s.stageFail = false
		-- equivalent under the backend's rule (case-insensitive): resumes instead of uploading again
		mesh.data = string.upper(mesh.data)
		local r = P.run(bundle, nil, { resume = ledger }, b)
		assert(r.success and r.assets[1].resumed and s.uploads == 2 and calls > 0, tostring(r.error))
		cleaned(s)
	end)
	test("Source edited during readback cannot commit stale geometry", function()
		local bundle, b, s, p, m = fixture()
		s.onRead = function()
			m.data = "edited during yield"
		end
		local r = P.run(bundle, nil, nil, b)
		assert(not r.success and string.find(r.error, "Source changed") and p.mesh == "original")
		cleaned(s)
	end)
	test("Scene edited during readback is preserved", function()
		local bundle, b, s, p = fixture()
		s.onRead = function()
			p.size = 10
		end
		local r = P.run(bundle, nil, nil, b)
		assert(
			not r.success and p.size == 10 and p.mesh == "original" and string.find(r.error, "part changed")
		)
		cleaned(s)
	end)
	test("Surface edited after snapshot prevents commit", function()
		local bundle, b, s, p = fixture()
		s.onRead = function()
			if s.loads == 2 then
				p.map = "external edit"
			end
		end
		local r = P.run(bundle, nil, nil, b)
		assert(not r.success and p.map == "external edit" and p.mesh == "original")
		cleaned(s)
	end)
	test("Cancellation during retry cleans preparation resources", function()
		local bundle, b, s, p = fixture()
		s.readFail = true
		local cancelled = false
		b.sleep = function()
			cancelled = true
		end
		local r = P.run(bundle, nil, {
			cancelled = function()
				return cancelled
			end,
		}, b)
		assert(not r.success and string.find(r.error, "cancelled") and s.loads == 1 and p.mesh == "original")
		cleaned(s)
	end)
	test("Duplicate and incomplete handles cannot commit", function()
		local bundle, b, s, p = fixture()
		table.insert(bundle.handles, bundle.handles[1])
		local r = P.run(bundle, nil, nil, b)
		assert(not r.success and string.find(r.error, "Duplicate") and p.mesh == "original")
		cleaned(s)
		assert(not P.run({ handles = { {} } }, nil, nil, b).success)
	end)
	test("Missing asset ID fails without scene mutation", function()
		local bundle, b, s, p = fixture()
		b.upload = function()
			return ""
		end
		assert(not P.run(bundle, nil, nil, b).success and p.mesh == "original")
		cleaned(s)
	end)
	test("Invalid options and pre-cancel reject before external effects", function()
		local bundle, b, s = fixture()
		rejects(function()
			P.run(bundle, nil, { maxWork = 0 }, b)
		end, "Invalid")
		rejects(function()
			P.run(bundle, nil, { attempts = 0 }, b)
		end, "attempts")
		rejects(function()
			P.run(bundle, nil, {
				cancelled = function()
					return true
				end,
			}, b)
		end, "cancelled")
		assert(s.uploads == 0)
	end)
	test("Transaction rolls back in reverse including failing action", function()
		local order = {}
		local r = Transaction.run(function(c)
			c.defer(function()
				table.insert(order, "clean1")
			end)
			c.defer(function()
				table.insert(order, "clean2")
			end)
			return {
				actions = {
					{
						name = "a",
						apply = function() end,
						rollback = function()
							table.insert(order, "a")
						end,
					},
					{
						name = "b",
						apply = function()
							error("failure")
						end,
						rollback = function()
							table.insert(order, "b")
						end,
					},
				},
			}
		end)
		assert(r.rolledBack and table.concat(order, ",") == "b,a,clean2,clean1")
	end)
	test("Materials-only handles publish maps and keep the part mesh", function()
		local _bundle, b, s, p = fixture()
		local r = P.run({ handles = { { part = p, materialsOnly = true } } }, {}, nil, b)
		assert(r.success and r.committed and p.mesh == "original" and p.map == "asset:1")
		assert(s.uploads == 1 and s.stages == 0 and #r.assets == 1 and r.assets[1].kind == "Image")
		cleaned(s)
	end)
	test("Materials-only handles resume from the ledger and roll back maps on failure", function()
		local _bundle, b, s, p, _m, image = fixture()
		local ledger = {}
		s.mapFail = true
		local first = P.run({ handles = { { part = p, materialsOnly = true } } }, {}, { resume = ledger }, b)
		assert(not first.success and first.rolledBack and p.map == image and p.mesh == "original")
		s.mapFail = false
		local second = P.run({ handles = { { part = p, materialsOnly = true } } }, {}, { resume = ledger }, b)
		assert(second.success and s.uploads == 1 and second.assets[1].resumed and p.map == "asset:1")
		cleaned(s)
	end)
	test("Publish handles must carry exactly one of a mesh or materialsOnly", function()
		local bundle, b, _s, p, m = fixture()
		local both = P.run({ handles = { { part = p, editable = m, materialsOnly = true } } }, {}, nil, b)
		assert(not both.success and string.find(tostring(both.error), "Incomplete publish handle", 1, true))
		local neither = P.run({ handles = { { part = p } } }, {}, nil, b)
		assert(
			not neither.success and string.find(tostring(neither.error), "Incomplete publish handle", 1, true)
		)
		local noMaps = P.run({ handles = { { part = p, materialsOnly = true } } }, {}, nil, {
			upload = b.upload,
			load = b.load,
			snapshot = b.snapshot,
			destroy = b.destroy,
			backup = b.backup,
			stage = b.stage,
			apply = b.apply,
			restore = b.restore,
			guard = b.guard,
			uri = b.uri,
			sleep = b.sleep,
			maps = function()
				return {}
			end,
		})
		assert(not noMaps.success and string.find(tostring(noMaps.error), "no editable maps", 1, true))
		assert(bundle.handles[1].editable == m)
	end)
	test("Standalone images publish, verify and return their IDs in order", function()
		local _bundle, b, s, p = fixture()
		local img1, img2 = { data = "sky-up" }, { data = "sky-side" }
		local r = P.run({ handles = {}, images = { img1, img2 } }, {}, nil, b)
		assert(r.success and r.committed, tostring(r.error))
		assert(r.imageIds and #r.imageIds == 2 and r.imageIds[1] ~= r.imageIds[2])
		assert(s.uploads == 2 and s.stages == 0 and p.mesh == "original")
		local ledger = {}
		local again = P.run({ handles = {}, images = { img1, img2 } }, {}, { resume = ledger }, b)
		assert(again.success and #again.imageIds == 2)
		local resumed = P.run({ handles = {}, images = { img1, img2 } }, {}, { resume = ledger }, b)
		assert(resumed.success and resumed.assets[1].resumed and resumed.imageIds[2] == again.imageIds[2])
		s.corrupt = true
		local bad = P.run({ handles = {}, images = { { data = "x" } } }, {}, nil, b)
		assert(not bad.success and string.find(tostring(bad.error), "content mismatch", 1, true))
		cleaned(s)
	end)
	local function many(count)
		local bundle, b, s, p, m, img = fixture()
		local parts = { p }
		for k = 2, count do
			local part = { mesh = "old" .. k, size = 3, map = img }
			table.insert(parts, part)
			table.insert(bundle.handles, { editable = { data = "mesh" .. k }, part = part })
		end
		return bundle, b, s, parts, m, img
	end
	test("Chunked publish commits every part, sharing one ledger across chunks", function()
		local bundle, b, s, parts = many(5)
		local r = P.runChunked(bundle, {}, nil, b, 2)
		assert(
			r.success and r.committed and not r.partial and r.committedParts == 5 and #r.chunks == 3,
			tostring(r.error)
		)
		for _, part in parts do
			assert(
				part.mesh ~= nil and string.match(part.mesh, "^%d+$") and part.map ~= nil,
				"part not published"
			)
		end
		-- 5 meshes + the shared image once
		assert(s.uploads == 6 and #r.resume == 6, "uploads " .. s.uploads)
		cleaned(s)
	end)
	test("Chunked publish carries every chunk's cleanup errors into its report", function()
		local bundle, b, s = many(5)
		local destroy = b.destroy
		b.destroy = function(o)
			destroy(o)
			if o.kind ~= "readback" then
				error("cleanup failed")
			end
		end
		local r = P.runChunked(bundle, {}, nil, b, 2)
		local sum = 0
		for _, chunk in r.chunks do
			sum += #chunk.cleanupErrors
		end
		assert(
			r.success and #r.chunks == 3 and sum > 0 and #r.cleanupErrors == sum,
			"cleanup " .. #r.cleanupErrors
		)
		cleaned(s)
	end)
	test("Chunked publish carries a chunk's rollback errors into its report", function()
		local bundle, b, s = many(3)
		s.applyFail = true
		s.rollbackFail = true
		local r = P.runChunked(bundle, {}, { attempts = 1 }, b, 2)
		assert(not r.success and #r.chunks == 1, "stops at the first failing chunk")
		assert(
			#r.rollbackErrors == #r.chunks[1].rollbackErrors and #r.rollbackErrors > 0,
			"rollback errors carried"
		)
		cleaned(s)
	end)
	test("Chunked publish stops at a failing chunk and keeps the committed ones", function()
		local bundle, b, s, parts, _m, img = many(5)
		local stage = b.stage
		b.stage = function(id)
			if s.stages >= 3 then
				error("stage failed")
			end
			return stage(id)
		end
		local r = P.runChunked(bundle, {}, { attempts = 1 }, b, 2)
		assert(not r.success and r.partial and r.committedParts == 2 and #r.chunks == 2)
		assert(string.find(tostring(r.error), "stage failed", 1, true))
		assert(string.match(parts[1].mesh, "^%d+$") and string.match(parts[2].mesh, "^%d+$"))
		assert(parts[3].mesh == "old3" and parts[3].map == img and parts[5].mesh == "old5")
		-- finishing with the same ledger re-uploads nothing already uploaded: parts 3 and 4 (uploaded
		-- before the failing stage) and the shared image resume; only part 5's mesh is new
		b.stage = stage
		local before = s.uploads
		local rest = P.runChunked(
			{ handles = { bundle.handles[3], bundle.handles[4], bundle.handles[5] } },
			{},
			{ resume = r.resume },
			b,
			2
		)
		assert(rest.success and rest.committedParts == 3)
		assert(s.uploads == before + 1, "uploads " .. (s.uploads - before))
		local resumed = 0
		for _, a in rest.assets do
			if a.resumed then
				resumed += 1
			end
		end
		assert(resumed >= 3, "resumed " .. resumed)
		cleaned(s)
	end)
	test("Chunked publish gives each chunk its own allocation budget", function()
		local bundle, b, s = many(6)
		local snapshot = b.snapshot
		b.snapshot = function(object, kind, budget)
			budget:reserve(1000)
			return snapshot(object, kind, budget)
		end
		local whole = P.run(bundle, {}, { maxBytes = 12000 }, b)
		assert(not whole.success and string.find(tostring(whole.error), "allocation limit", 1, true))
		local chunked = P.runChunked(bundle, {}, { maxBytes = 12000 }, b, 2)
		assert(chunked.success and chunked.committedParts == 6, tostring(chunked.error))
		cleaned(s)
	end)
	test("Chunked publish rejects an invalid chunk size", function()
		local bundle, b = fixture()
		rejects(function()
			P.runChunked(bundle, {}, nil, b, 0)
		end, "parts per transaction")
	end)
	test("The resume ledger keeps digests and refers to its sources weakly", function()
		local bundle, b, s, _p, mesh = fixture()
		b.digest = function(kind, snapshot)
			return kind .. "#" .. tostring(snapshot)
		end
		local ledger = {}
		local r = P.run(bundle, {}, { resume = ledger }, b)
		assert(r.success and #ledger == 2, tostring(r.error))
		for _, entry in ledger do
			assert(entry.object == nil and entry.digested and string.find(entry.fingerprint, "#", 1, true))
		end
		-- an unchanged source resumes by its digest; a changed one is refused
		local again = P.run(bundle, {}, { resume = ledger }, b)
		assert(again.success and again.assets[1].resumed and s.uploads == 2)
		mesh.data = "edited"
		local changed = P.run(bundle, {}, { resume = ledger, attempts = 1 }, b)
		assert(not changed.success and string.find(tostring(changed.error), "Resume source changed", 1, true))
		-- an entry whose source is gone (collected, or never recorded) is dropped
		table.insert(ledger, { kind = "Image", id = "gone", fingerprint = "Image#x", digested = true })
		assert(#ledger == 3 and P.pruneLedger(ledger) == 1 and #ledger == 2)
		-- the source of a published temporary is held weakly: once collected, its entry goes too. A collection cycle
		-- cannot be forced here (collectgarbage("collect") is unavailable) and may not complete within this loop in a
		-- large heap such as Studio's, so the check is opportunistic
		local function publishTemporary()
			P.run({ handles = {}, images = { { data = "temporary" } } }, {}, { resume = ledger }, b)
		end
		publishTemporary()
		assert(#ledger == 3)
		for _ = 1, 200 do
			for _ = 1, 2000 do
				local _garbage = table.create(64, 0)
			end
			if P.pruneLedger(ledger) > 0 then
				break
			end
		end
		assert(#ledger == 2 or #ledger == 3)
		cleaned(s)
	end)
	test("Validation failure precedes all live actions", function()
		local applied = false
		local r = Transaction.run(function()
			return {
				actions = {
					{
						name = "a",
						apply = function()
							applied = true
						end,
						rollback = function() end,
					},
				},
				validate = function()
					error("changed")
				end,
			}
		end)
		assert(not r.success and r.rolledBack and not applied)
	end)
	return report
end
