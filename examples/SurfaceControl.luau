-- Deform a detailed ripple sheet with a small harmonic control surface.
return function(E)
	E = E or require(script.Parent.Parent)
	local control = E.Geometry.parametric(function(u, v)
		return Vector3.new(u * 4, v * 4, 0)
	end, 8, 8)
	local detailed = E.Geometry.parametric(function(u, v)
		return Vector3.new(u * 4, v * 4, 0.08 * math.sin(u * 40) * math.sin(v * 30) + 0.15)
	end, 40, 40)
	local binding, bindReport = E.SurfaceDeform.bind(detailed, control)
	local anchors = {}
	for id, p in control.vertices do
		if p.X < 0.01 then
			anchors[id] = p
		elseif p.X > 3.99 then
			anchors[id] = p + Vector3.new(0, 0, 1.5)
		end
	end
	local posed, solveReport = E.Laplacian.bind(control):solve(anchors, { order = 1 })
	local result, report = binding:evaluate(posed)
	return {
		mesh = result,
		control = posed,
		bindReport = bindReport,
		solveReport = solveReport,
		report = report,
	}
end
