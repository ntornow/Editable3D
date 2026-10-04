return function(E)
	local C, S = E.Connectivity, E.Selection
	local report = { passed = 0, failed = 0, results = {}, skipped = 0 }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function edge(a, b)
		return a < b and a .. ":" .. b or b .. ":" .. a
	end
	local function count(t)
		local n = 0
		for _ in t do
			n += 1
		end
		return n
	end
	local function near(a, b)
		assert(math.abs(a - b) < 1e-6, tostring(a) .. " ~= " .. tostring(b))
	end
	local function mesh(points, faces)
		local m = { vertices = {}, faces = {} }
		for i, p in points do
			m.vertices[i] = p
		end
		for i, vs in faces do
			m.faces[i] = { vertices = table.clone(vs) }
		end
		return m
	end
	local function grid(nx, ny)
		local points, faces = {}, {}
		local function id(i, j)
			return j * (nx + 1) + i + 1
		end
		for j = 0, ny do
			for i = 0, nx do
				table.insert(points, Vector3.new(i, j, 0))
			end
		end
		for j = 0, ny - 1 do
			for i = 0, nx - 1 do
				table.insert(faces, { id(i, j), id(i + 1, j), id(i + 1, j + 1), id(i, j + 1) })
			end
		end
		return mesh(points, faces), id
	end
	local function torus(nx, ny)
		local points, faces = {}, {}
		local function id(i, j)
			return (j % ny) * nx + (i % nx) + 1
		end
		for j = 0, ny - 1 do
			local v = j * 2 * math.pi / ny
			for i = 0, nx - 1 do
				local u = i * 2 * math.pi / nx
				table.insert(
					points,
					Vector3.new((3 + math.cos(v)) * math.cos(u), math.sin(v), (3 + math.cos(v)) * math.sin(u))
				)
			end
		end
		for j = 0, ny - 1 do
			for i = 0, nx - 1 do
				table.insert(faces, { id(i, j), id(i + 1, j), id(i + 1, j + 1), id(i, j + 1) })
			end
		end
		return mesh(points, faces), id
	end
	test("Directed corner index preserves next previous twin and source ownership invariants", function()
		local m = grid(3, 2)
		local index = C.index(m)
		assert(count(index.vertices) == 12 and count(index.edges) == 17 and count(index.corners) == 24)
		for ck, h in index.corners do
			assert(index.corners[h.next].previous == ck and index.corners[h.previous].next == ck)
			assert(index.corners[h.next].vertex == h.to)
			if h.twin then
				local twin = index.corners[h.twin]
				assert(twin.twin == ck and twin.vertex == h.to and twin.to == h.vertex)
			end
		end
		m.vertices[1] = Vector3.new(10, 10, 10)
		m.faces[1].vertices[1] = 99
		assert(index.vertices[1].position == Vector3.zero and index.faces[1].vertices[1] == 1)
	end)
	test("Connectivity reports disk and torus Euler characteristics and genera", function()
		local a = C.analyze((grid(3, 2)))
		assert(a.valid and not a.closed and a.eulerCharacteristic == 1 and a.components[1].genus == 0)
		assert(a.boundaryEdges == 10 and #a.boundaryLoops == 1 and #a.boundaryLoops[1].edges == 10)
		a = C.analyze((torus(7, 5)))
		assert(a.valid and a.closed and a.eulerCharacteristic == 0 and a.components[1].genus == 1)
		assert(#a.components == 1 and a.boundaryEdges == 0 and next(a.nonmanifoldVertices) == nil)
	end)
	test("Boundary walks retain directed winding and separate an annulus's two loops", function()
		local m, id = grid(3, 3)
		m.faces[5] = nil
		local loops, r = C.boundaries(m)
		assert(r.complete and #loops == 2)
		local length = {}
		local index = C.index(m)
		for _, loop in loops do
			table.insert(length, #loop.edges)
			for i, k in loop.edges do
				local h = index.corners[loop.corners[i]]
				assert(
					h.vertex == loop.vertices[i]
						and h.to == loop.vertices[i % #loop.vertices + 1]
						and h.edge == k
				)
			end
		end
		table.sort(length)
		assert(length[1] == 4 and length[2] == 12)
		local a = C.analyze(m)
		assert(
			a.eulerCharacteristic == 0 and a.components[1].genus == 0 and a.components[1].boundaryLoops == 2
		)
		assert(id(1, 1) == 6)
	end)
	test("Touching surface fans and branched boundaries are diagnosed instead of called manifold", function()
		local m = mesh(
			{ Vector3.zero, Vector3.xAxis, Vector3.yAxis, Vector3.new(-1, 0, 0), Vector3.new(0, -1, 0) },
			{ { 1, 2, 3 }, { 1, 4, 5 } }
		)
		local a = C.analyze(m)
		assert(not a.valid and count(a.nonmanifoldVertices) == 1 and a.nonmanifoldVertices[1])
		assert(#a.components == 2 and #C.index(m).vertices[1].fans == 2)
		local loops, r = C.boundaries(m)
		assert(not r.complete and r.ambiguousVertices[1] and #loops == 0)
	end)
	test(
		"Duplicate reversed faces zero-length edges and inconsistent winding remain separate diagnostics",
		function()
			local m = grid(1, 1)
			m.faces[2] = { vertices = { 4, 2, 1, 3 } }
			local a = C.analyze(m)
			assert(a.duplicateFaces[2] == 1 and not a.valid and a.consistentlyWound)
			m.faces[2].vertices = { 4, 3, 1, 2 }
			a = C.analyze(m)
			assert(count(a.windingEdges) == 4 and a.duplicateFaces[2] == 1)
			m.faces[2] = nil
			m.vertices[2] = m.vertices[1]
			a = C.analyze(m)
			assert(a.zeroLengthEdges["1:2"] and not a.valid)
		end
	)
	test("Loose vertices sparse IDs and disconnected components retain explicit counts", function()
		local m = grid(1, 1)
		m.vertices[99] = Vector3.new(9, 9, 9)
		m.faces[80] = m.faces[1]
		m.faces[1] = nil
		local a = C.analyze(m)
		assert(a.looseVertices[99] and a.vertices == 5 and a.eulerCharacteristic == 2 and a.valid)
		assert(a.components[1].eulerCharacteristic == 1 and a.components[1].faces[80])
		assert(C.index(m).corners["80:1"].vertex == 1)
	end)
	test("Connectivity rejects malformed faces invalid native positions budgets and cancellation", function()
		local m = grid(2, 2)
		for _, fn in
			{
				function()
					C.index(m, { maxElements = 3 })
				end,
				function()
					C.index(m, {
						checkpoint = function()
							error("cancelled")
						end,
					})
				end,
				function()
					local bad = grid(1, 1)
					bad.faces[1].vertices = { 1, 2, 2, 4 }
					C.index(bad)
				end,
				function()
					local bad = grid(1, 1)
					bad.vertices[1] = Vector3.new(math.huge, 0, 0)
					C.index(bad)
				end,
			}
		do
			assert(not pcall(fn))
		end
		assert(C.analyze(m).valid)
	end)
	test("Shortest paths distinguish geometric length hops and caller-supplied nonnegative costs", function()
		local m = mesh(
			{ Vector3.zero, Vector3.new(0, 3, 0), Vector3.new(2, 0, 0), Vector3.new(1, 0.2, 0) },
			{ { 1, 2, 3, 4 } }
		)
		local p = S.shortestPath(m, 1, 3)
		assert(p.complete and p.found and table.concat(p.path, ",") == "1,4,3")
		near(p.distance, 2 * math.sqrt(1.04))
		p = S.shortestPath(m, 1, 3, { metric = "hops" })
		assert(table.concat(p.path, ",") == "1,2,3" and p.distance == 2)
		p = S.shortestPath(m, 1, 3, {
			cost = function(a, b, cost)
				return (a == 1 and b == 4) and 100 or cost
			end,
		})
		assert(table.concat(p.path, ",") == "1,2,3")
		p = S.shortestPath(m, 1, 3, { faceStepping = true })
		assert(#p.path == 2 and p.distance == 2)
	end)
	test("Vertex face and edge paths follow their documented graph adjacency", function()
		local m, id = grid(3, 3)
		local p = S.shortestPath(m, 1, 9, { domain = "face", metric = "hops" })
		assert(p.found and #p.path == 5 and p.distance == 4)
		p = S.shortestPath(m, 1, 9, { domain = "face", metric = "hops", faceStepping = true })
		assert(#p.path == 3 and p.distance == 2)
		p = S.shortestPath(
			m,
			edge(id(0, 0), id(1, 0)),
			edge(id(0, 3), id(1, 3)),
			{ domain = "edge", faceStepping = true, metric = "hops" }
		)
		assert(p.found and p.distance == 3 and #p.path == 4)
		p = S.shortestPath(m, 1, 16, { metric = "hops" })
		assert(p.distance == 6 and #p.path == 7)
	end)
	test("Linked face regions and shortest paths respect explicit seam barriers", function()
		local m, id = grid(3, 3)
		local barrier = {}
		for j = 0, 2 do
			barrier[edge(id(1, j), id(1, j + 1))] = true
		end
		local selection, r = S.linked(m, { [1] = true }, { domain = "face", blockedEdges = barrier })
		assert(r.complete and count(selection) == 3 and selection[1] and selection[4] and selection[7])
		local p = S.shortestPath(m, 1, 9, { domain = "face", blockedEdges = barrier })
		assert(p.complete and not p.found and p.reason == "unreachable" and next(p.selection) == nil)
		p = S.shortestPath(m, 1, 16, { blocked = { [1] = true } })
		assert(not p.found and next(p.selection) == nil)
	end)
	test(
		"Path budgets unreachable targets zero costs and cancellation do not masquerade as a path",
		function()
			local m = grid(3, 3)
			local p = S.shortestPath(m, 1, 16, { maxVisited = 2 })
			assert(
				not p.complete
					and not p.found
					and tostring(p.reason) == "visit_budget"
					and next(p.selection) == nil
			)
			p = S.shortestPath(m, 1, 16, { maxWork = 2 })
			assert(not p.complete and p.reason == "work_budget")
			p = S.shortestPath(m, 1, 16, {
				cost = function()
					return 0
				end,
			})
			assert(p.found and p.distance == 0 and #p.path <= 16)
			for _, fn in
				{
					function()
						S.shortestPath(m, 1, 99)
					end,
					function()
						S.shortestPath(m, 1, 16, {
							cost = function()
								return -1
							end,
						})
					end,
					function()
						S.shortestPath(m, 1, 16, {
							checkpoint = function()
								error("cancelled")
							end,
						})
					end,
				}
			do
				assert(not pcall(fn))
			end
		end
	)
	test("Heap geodesics return exact edge distances and preserve legacy smooth masks", function()
		local m = grid(4, 4)
		local mask, d, r = S.geodesic(m, { [1] = 1 }, 2.5)
		assert(r.complete and mask[1] == 1 and d[3] == 2 and d[7] == 2 and not d[25])
		near(mask[3], 0.104)
		assert(not pcall(S.geodesic, m, { [1] = 1 }, 10, { maxVisited = 1 }))
	end)
	test("Edge loops continue through regular quad vertices and stop at the outer boundary", function()
		local m, id = grid(4, 4)
		local loop = S.edgeLoop(m, edge(id(1, 2), id(2, 2)))
		assert(loop.complete and not loop.closed and #loop.edges == 4 and #loop.vertices == 5)
		for _, v in loop.vertices do
			assert(m.vertices[v].Y == 2)
		end
		for i, key in loop.edges do
			assert(key == edge(loop.vertices[i], loop.vertices[i + 1]))
		end
		local boundary = S.edgeLoop(m, edge(id(0, 0), id(1, 0)))
		assert(boundary.complete and boundary.closed and #boundary.edges == 16 and #boundary.vertices == 16)
	end)
	test("Closed quad torus has distinct ordered edge loops rings and face strips", function()
		local m, id = torus(7, 5)
		local key = edge(id(0, 0), id(1, 0))
		local loop = S.edgeLoop(m, key)
		assert(loop.closed and loop.complete and #loop.edges == 7 and #loop.vertices == 7)
		local ring = S.edgeRing(m, key)
		assert(ring.closed and ring.complete and #ring.edges == 5 and #ring.faces == 5)
		local faces = S.faceLoop(m, key)
		assert(faces.closed and count(faces.selection) == 5 and #faces.faces == 5)
	end)
	test("Open rings traverse opposite quad edges and report non-quad and budget endpoints", function()
		local m, id = grid(3, 3)
		local key = edge(id(1, 1), id(2, 1))
		local ring = S.edgeRing(m, key)
		assert(ring.complete and not ring.closed and #ring.edges == 4 and #ring.faces == 3)
		local short = S.edgeRing(m, key, { maxSteps = 1 })
		assert(not short.complete)
		m.faces[8].vertices = { id(1, 2), id(2, 2), id(2, 3) }
		ring = S.edgeRing(m, key)
		assert(not ring.closed and table.find(ring.ends, "non_quad"))
		assert(not pcall(S.edgeLoop, m, "1:99"))
	end)
	test("Region boundary removes internal selected edges and retains holes and original IDs", function()
		local m = grid(3, 3)
		local selected = {}
		for fid in m.faces do
			if fid ~= 5 then
				selected[fid] = true
			end
		end
		local edges, loops, r = S.regionBoundary(m, selected)
		assert(r.complete and count(edges) == 16 and #loops == 2)
		for _, loop in loops do
			for _, ck in loop.corners do
				local fid = tonumber(ck:match("^(%d+):"))
				assert(selected[fid])
			end
		end
		local empty, emptyLoops = S.regionBoundary(m, {})
		assert(next(empty) == nil and #emptyLoops == 0)
	end)
	if E.Mesh then
		test("Mesh validation exposes vertex fan and duplicate face errors to existing operators", function()
			local m = E.Mesh.new()
			for _, p in
				{ Vector3.zero, Vector3.xAxis, Vector3.yAxis, Vector3.new(-1, 0, 0), Vector3.new(0, -1, 0) }
			do
				m:addVertex(p)
			end
			m:addFace({ 1, 2, 3 })
			m:addFace({ 1, 4, 5 })
			local r = m:validate()
			assert(not r.valid and r.nonmanifoldVertices == 1 and r.surfaceComponents == 2)
		end)
	else
		report.skipped += 1
	end
	report.success = report.failed == 0
	return report
end
