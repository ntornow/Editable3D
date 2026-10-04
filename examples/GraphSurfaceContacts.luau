-- Two curved tensor graphs meeting in an exact closed loop.
return function(E)
	E = E or require(script.Parent.Parent)
	local z = { 0.25, -0.25, 0.25 }
	local function surface(sign, swap)
		local rows = {}
		for i = 1, 3 do
			rows[i] = {}
			for j = 1, 3 do
				local u, v = (i - 1) / 2, (j - 1) / 2
				rows[i][j] =
					Vector3.new(swap and v or u, swap and u or v, u * v + sign * (z[i] + z[j] - 0.125))
			end
		end
		return E.NURBS.surface(rows, 2, 2)
	end
	local a, b = surface(1), surface(-1, true)
	local contacts =
		E.SplineQuery.intersectSurfaces(a, b, { method = "exactGraphPair", requireComplete = true })
	assert(contacts.componentCount == 1 and contacts.components[1].parameterDimension == 1)
	return { surfaceA = a, surfaceB = b, contacts = contacts }
end
