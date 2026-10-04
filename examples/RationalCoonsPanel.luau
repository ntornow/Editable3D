-- Four independent rational borders form one editable tensor-product patch.
return function(E)
	E = E or require(script.Parent.Parent)
	local N = E.NURBS
	local bottom = N.curve(
		{ Vector3.zero, Vector3.new(2, -1, 0.8), Vector3.new(4, 0, 0) },
		2,
		{ weights = { 1, 0.65, 1 } }
	)
	local top = N.curve(
		{ Vector3.new(0, 3, 0), Vector3.new(1, 4, 0.2), Vector3.new(3, 4, 0.5), Vector3.new(4, 3, 0) },
		3,
		{ weights = { 1, 0.9, 0.55, 1 } }
	)
	local left = N.curve(
		{ Vector3.zero, Vector3.new(-0.5, 1.5, 0.3), Vector3.new(0, 3, 0) },
		2,
		{ weights = { 1, 0.8, 1 } }
	)
	local right = N.curve(
		{ Vector3.new(4, 0, 0), Vector3.new(4.5, 1.5, -0.2), Vector3.new(4, 3, 0) },
		2,
		{ weights = { 1, 0.6, 1 } }
	)
	local surface, construction = E.Surfaces.coons(bottom, top, left, right, { returnReport = true })
	local mesh = N.tessellate(surface, 14, 12)
	assert(construction.complete and mesh:validate().valid)
	return {
		surface = surface,
		mesh = mesh,
		construction = construction,
		boundaries = { bottom, top, left, right },
		source = E.IO.encode(mesh),
	}
end
