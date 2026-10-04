-- Exact one-sign tensor Bernstein zero loci on a closed span-pair cube.
return function(R, ctx)
	local zero, one = R.number(0), R.number(1)
	local function factors(degree)
		local out = {}
		for i = 0, degree do
			local row = { one }
			out[i + 1] = row
			for k = 1, i do
				row[k + 1] = R.mul(row[k], R.div(R.number(i - k + 1), R.number(degree - k + 1)))
			end
		end
		return out
	end
	local function prepare(span, du, dv)
		if span.bernstein then
			return span.bernstein
		end
		local u, v = factors(du), factors(dv)
		local out = { degree = { du, dv }, h = {} }
		for coordinate, p in span.original do
			local coefficients = {}
			for i = 0, du do
				for j = 0, dv do
					ctx.allocate(1)
					local value = zero
					for y = 0, j do
						local row = p[y + 1]
						if row then
							for x = 0, i do
								if row[x + 1] then
									value = R.add(
										value,
										R.mul(row[x + 1], R.mul(u[i + 1][x + 1], v[j + 1][y + 1]))
									)
								end
							end
						end
					end
					coefficients[#coefficients + 1] = { index = { i, j }, value = value }
				end
			end
			out.h[coordinate] = coefficients
		end
		span.bernstein = out
		return out
	end
	local function contains(a, b)
		for axis = 1, 4 do
			if a[axis] ~= nil and a[axis] ~= b[axis] then
				return false
			end
		end
		return true
	end
	local function maximal(faces)
		local out = {}
		for i, face in faces do
			local contained = false
			for j, other in faces do
				ctx.visit(1)
				if i ~= j and contains(other, face) and (not contains(face, other) or j < i) then
					contained = true
					break
				end
			end
			if not contained then
				out[#out + 1] = face
			end
		end
		return out
	end
	local function combine(a, b)
		local out = {}
		for _, x in a do
			for _, y in b do
				ctx.visit(1)
				local z = {}
				local compatible = true
				for axis = 1, 4 do
					if x[axis] ~= nil and y[axis] ~= nil and x[axis] ~= y[axis] then
						compatible = false
						break
					end
					z[axis] = x[axis] ~= nil and x[axis] or y[axis]
				end
				if compatible then
					ctx.allocate(1)
					out[#out + 1] = z
				end
			end
		end
		return maximal(out)
	end
	local function classify(a, b)
		local degrees = { a.degree[1], a.degree[2], b.degree[1], b.degree[2] }
		local faces = { {} }
		local remaining, proof =
			{}, { method = "tensorBernsteinBoundaryZeros", degrees = degrees, coordinates = {} }
		for coordinate = 1, 3 do
			local coefficients, sign, mixed = {}, 0, false
			for i, x in a.h[coordinate] do
				for j, y in b.h[coordinate] do
					ctx.allocate(1)
					local value = R.sub(R.mul(x.value, b.h[4][j].value), R.mul(y.value, a.h[4][i].value))
					coefficients[#coefficients + 1] =
						{ index = { x.index[1], x.index[2], y.index[1], y.index[2] }, value = value }
					if value.sign ~= 0 then
						if sign ~= 0 and sign ~= value.sign then
							mixed = true
						end
						sign = value.sign
					end
				end
			end
			if mixed then
				remaining[#remaining + 1] = coordinate
				continue
			end
			proof.coordinates[#proof.coordinates + 1] =
				{ coordinate = coordinate, sign = sign, coefficients = coefficients }
			if sign == 0 then
				continue
			end
			local zeros = {}
			for code = 0, 80 do
				local face = {}
				local digits = code
				for axis = 1, 4 do
					local digit = digits % 3
					digits = math.floor(digits / 3)
					if digit ~= 0 then
						face[axis] = digit - 1
					end
				end
				local allZero = true
				for _, c in coefficients do
					ctx.visit(1)
					if c.value.sign == 0 then
						continue
					end
					local supported = true
					for axis = 1, 4 do
						if
							face[axis] ~= nil
							and c.index[axis] ~= (face[axis] == 0 and 0 or degrees[axis])
						then
							supported = false
							break
						end
					end
					if supported then
						allZero = false
						break
					end
				end
				if allZero then
					zeros[#zeros + 1] = face
				end
			end
			faces = combine(faces, maximal(zeros))
			if #faces == 0 then
				break
			end
		end
		proof.faces = faces
		return faces, remaining, proof
	end
	return { prepare = prepare, classify = classify }
end
