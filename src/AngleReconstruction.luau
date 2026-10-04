-- Private least-squares reconstruction of oriented triangle angles in a two-pin gauge.
local Linear = require(script.Parent.UVLinearSolver)
local System = require(script.Parent.AngleConstraintSystem)
local U = require(script.Parent.Util)
local R = {}
function R.solve(vertices, triangles, angles, pins, options, visit)
	local index, unknown = {}, 0
	for _, id in vertices do
		if id ~= pins[1] and id ~= pins[2] then
			index[id] = unknown + 1
			unknown += 2
		end
	end
	local rows = {}
	local function row(triangle, uc, vc)
		local value = { indices = {}, values = {}, rhs = 0 }
		for i, id in triangle do
			visit(1)
			if id == pins[1] or id == pins[2] then
				if id == pins[2] then
					value.rhs -= uc[i]
				end
			else
				if uc[i] ~= 0 then
					table.insert(value.indices, index[id])
					table.insert(value.values, uc[i])
				end
				if vc[i] ~= 0 then
					table.insert(value.indices, index[id] + 1)
					table.insert(value.values, vc[i])
				end
			end
		end
		table.insert(rows, value)
	end
	for i, triangle in triangles do
		visit(1)
		local a, b, c = angles[3 * i - 2], angles[3 * i - 1], angles[3 * i]
		local ratio = math.sin(b) / math.sin(c)
		local x, y = math.cos(a) * ratio, math.sin(a) * ratio
		local scale = math.max(1, math.abs(x), math.abs(y))
		local gx, gy = { -y / scale, y / scale, 0 }, { (x - 1) / scale, -x / scale, 1 / scale }
		row(triangle, gx, { -gy[1], -gy[2], -gy[3] })
		row(triangle, gy, gx)
	end
	local rhs, diagonal = table.create(unknown, 0), table.create(unknown, 0)
	for _, r in rows do
		for k, id in r.indices do
			visit(1)
			rhs[id] += r.values[k] * r.rhs
			diagonal[id] += r.values[k] ^ 2
		end
	end
	local function multiply(x)
		return System.transpose(rows, System.multiply(rows, x, visit), unknown, visit)
	end
	local x, report = Linear.solve(rhs, diagonal, multiply, options, visit)
	local uv = { [pins[1]] = { 0, 0 }, [pins[2]] = { 1, 0 } }
	report.finite = true
	for _, id in vertices do
		visit(1)
		if index[id] then
			uv[id] = { x[index[id]], x[index[id] + 1] }
			report.finite = report.finite and U.finite(uv[id][1]) and U.finite(uv[id][2])
		end
	end
	report.energy = 0
	for _, r in rows do
		local value = -r.rhs
		for k, id in r.indices do
			visit(1)
			value += r.values[k] * x[id]
		end
		report.energy += value * value
	end
	return uv, report
end
return R
