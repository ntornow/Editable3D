-- Private bounded Jacobi-preconditioned CG with periodically refreshed residuals.
-- High-order fairing can retain conjugate directions across a residual refresh.
local U = require(script.Parent.Util)
local L = {}
local function dot(a, b, visit)
	local sum = 0
	for i, value in a do
		visit(1)
		sum += value * b[i]
	end
	return sum
end
function L.solve(rhs, diagonal, multiply, options, visit)
	local n = #rhs
	local x, r, z, p = table.create(n, 0), table.clone(rhs), {}, {}
	local report = { iterations = 0, converged = false }
	local length = math.sqrt(dot(rhs, rhs, visit))
	local threshold = math.max(options.absoluteTolerance, options.tolerance * length)
	local function finish(reason)
		local product = multiply(x)
		for i = 1, n do
			visit(1)
			r[i] = rhs[i] - product[i]
		end
		report.residual = math.sqrt(dot(r, r, visit))
		report.relativeResidual = report.residual / math.max(length, 1e-300)
		report.threshold = threshold
		report.converged = report.residual <= threshold
		if not report.converged then
			report.reason = reason
		end
		return x, report
	end
	for i = 1, n do
		visit(1)
		if not U.finite(diagonal[i]) or diagonal[i] <= 0 then
			return finish("singularDiagonal")
		end
		z[i] = r[i] / diagonal[i]
		p[i] = z[i]
	end
	if length <= threshold then
		return finish()
	end
	local rz = dot(r, z, visit)
	for iteration = 1, options.iterations do
		local product = multiply(p)
		local curvature = dot(p, product, visit)
		if not U.finite(curvature) or curvature <= 0 or not U.finite(rz) then
			return finish("nonpositiveCurvature")
		end
		local step = rz / curvature
		for i = 1, n do
			visit(1)
			x[i] += step * p[i]
			r[i] -= step * product[i]
		end
		report.iterations = iteration
		local residual = math.sqrt(dot(r, r, visit))
		local restart = iteration % 32 == 0 or residual <= threshold
		if restart then
			local fresh = multiply(x)
			for i = 1, n do
				visit(1)
				r[i] = rhs[i] - fresh[i]
			end
			residual = math.sqrt(dot(r, r, visit))
		end
		if residual <= threshold then
			return finish()
		end
		if not U.finite(residual) then
			return finish("nonfiniteResidual")
		end
		for i = 1, n do
			visit(1)
			z[i] = r[i] / diagonal[i]
		end
		local nextRz = dot(r, z, visit)
		if rz <= 0 then
			return finish("nonpositiveResidual")
		end
		local beta = restart and options.restartOnRefresh ~= false and 0 or nextRz / rz
		for i = 1, n do
			visit(1)
			p[i] = z[i] + beta * p[i]
		end
		rz = nextRz
	end
	return finish("iterationLimit")
end
return L
