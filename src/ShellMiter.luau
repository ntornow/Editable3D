-- Private minimum-norm weighted plane-offset solve, including rank-one/two fans.
local U = require(script.Parent.Util)
local function dot(a, b)
	return a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
end
local function normalized(v)
	local a = { v.X, v.Y, v.Z }
	local length = math.sqrt(dot(a, a))
	assert(length > 0, "Shell face has no normal")
	for i = 1, 3 do
		a[i] /= length
	end
	return a
end
return function(mesh, id, faces, normals, options, visit)
	local matrix = { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 } }
	local rhs = { 0, 0, 0 }
	local constraints, total = {}, 0
	for _, fid in faces do
		visit()
		local face = mesh.faces[fid]
		local n = normalized(normals[fid])
		local weight = 1
		if options.joinWeighting ~= "uniform" then
			local index = assert(table.find(face.vertices, id))
			local p = mesh.vertices[id]
			local a = normalized(mesh.vertices[face.vertices[(index - 2) % #face.vertices + 1]] - p)
			local b = normalized(mesh.vertices[face.vertices[index % #face.vertices + 1]] - p)
			weight = math.acos(math.clamp(dot(a, b), -1, 1))
			local cross = { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] }
			if dot(cross, n) > 0 then
				weight = 2 * math.pi - weight
			end
		end
		constraints[#constraints + 1] = { normal = n, weight = weight }
		total += weight
	end
	assert(total > 0, "Shell vertex has no incident surface angle")
	for _, constraint in constraints do
		local n, w = constraint.normal, constraint.weight / total
		for i = 1, 3 do
			rhs[i] += w * n[i]
			for j = 1, 3 do
				matrix[i][j] += w * n[i] * n[j]
			end
		end
	end
	local vectors = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } }
	for _ = 1, 32 do
		visit()
		local p, q, largest = 1, 2, 0
		for i = 1, 2 do
			for j = i + 1, 3 do
				if math.abs(matrix[i][j]) > largest then
					p, q, largest = i, j, math.abs(matrix[i][j])
				end
			end
		end
		if largest <= 1e-15 then
			break
		end
		local tau = (matrix[q][q] - matrix[p][p]) / (2 * matrix[p][q])
		local t = (tau >= 0 and 1 or -1) / (math.abs(tau) + math.sqrt(1 + tau * tau))
		local c, sn = 1 / math.sqrt(1 + t * t), t / math.sqrt(1 + t * t)
		local off = matrix[p][q]
		matrix[p][p] -= t * off
		matrix[q][q] += t * off
		matrix[p][q], matrix[q][p] = 0, 0
		for k = 1, 3 do
			if k ~= p and k ~= q then
				local a, b = matrix[k][p], matrix[k][q]
				matrix[k][p], matrix[k][q] = c * a - sn * b, sn * a + c * b
				matrix[p][k], matrix[q][k] = matrix[k][p], matrix[k][q]
			end
			local a, b = vectors[k][p], vectors[k][q]
			vectors[k][p], vectors[k][q] = c * a - sn * b, sn * a + c * b
		end
	end
	local maximum = math.max(matrix[1][1], matrix[2][2], matrix[3][3])
	local rank, out = 0, { 0, 0, 0 }
	for j = 1, 3 do
		local eigenvalue = matrix[j][j]
		if eigenvalue > maximum * (options.rankTolerance or 1e-12) then
			rank += 1
			local projection = 0
			for i = 1, 3 do
				projection += rhs[i] * vectors[i][j]
			end
			for i = 1, 3 do
				out[i] += vectors[i][j] * projection / eigenvalue
			end
		end
	end
	local result = Vector3.new(out[1], out[2], out[3])
	assert(U.vector(result), "Shell miter exceeds native coordinate range")
	return result, rank
end
