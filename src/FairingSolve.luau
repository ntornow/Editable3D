-- Private fixed-coordinate fairing correction solve; native checks belong to caller.
local Linear = require(script.Parent.UVLinearSolver)
local F = {}
function F.solve(model, points, free, order, options, visit)
	local n = #points
	local diagonal = model.hessianDiagonal(order)
	local restricted = {}
	for i, id in free do
		restricted[i] = diagonal[id]
	end
	local function multiply(values)
		local full = table.create(n, 0)
		for i, id in free do
			visit(1)
			full[id] = values[i]
		end
		local result = model.apply(full, order)
		local out = {}
		for i, id in free do
			visit(1)
			out[i] = result[id]
		end
		return out
	end
	local result = {}
	for i, p in points do
		result[i] = table.clone(p)
	end
	local reports, displacements = {}, {}
	for i = 1, n do
		displacements[i] = { 0, 0, 0 }
	end
	for axis = 1, 3 do
		if options.lockAxes and options.lockAxes[({ "X", "Y", "Z" })[axis]] then
			reports[axis] = { converged = true, iterations = 0, locked = true }
			continue
		end
		local coordinate = {}
		for i, p in points do
			visit(1)
			coordinate[i] = p[axis]
		end
		local applied = model.apply(coordinate, order)
		local rhs = {}
		for i, id in free do
			visit(1)
			rhs[i] = -applied[id]
		end
		local correction, report = Linear.solve(rhs, restricted, multiply, options, visit)
		for i, id in free do
			visit(1)
			result[id][axis] += correction[i]
			displacements[id][axis] = correction[i]
		end
		reports[axis] = report
	end
	return result, reports, displacements
end
return F
