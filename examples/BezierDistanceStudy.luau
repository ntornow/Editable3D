-- Pure editable curve data, bounded distance samples and a reusable sweep mesh.
return function(E)
	E = E or require(script.Parent.Parent)
	local chain =
		E.Bezier.new({ Vector3.zero, Vector3.new(0, 2, 0), Vector3.new(1, 4, 0), Vector3.new(2, 6, 1) })
	chain = E.Bezier.setHandle(chain, 2, "right", Vector3.new(0.4, 3, 0))
	chain = E.Bezier.split(chain, 2, 0.4)
	local curve = E.Bezier.toNURBS(chain)
	local map = E.ArcLength.prepare(curve, { tolerance = 0.001 })
	local path, sampling = map.sample(24)
	local adaptive, tangents = E.SplineQuery.sample(curve, { tolerance = 0.01, maxAngle = 0.08 })
	assert(map.converged and sampling.converged and tangents.converged)
	local mesh = E.Curves.sweep(E.Curves.circle(0.12, 8), path)
	assert(mesh:validate().closed)
	return {
		chain = chain,
		curve = curve,
		path = path,
		sampling = sampling,
		adaptive = adaptive,
		tangents = tangents,
		mesh = mesh,
	}
end
