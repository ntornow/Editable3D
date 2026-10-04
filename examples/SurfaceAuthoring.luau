-- Three surface workflows, with no scene mutation or native allocations.
return function()
	local E = require(script.Parent.Parent)
	local body = E.Primitives.box(Vector3.new(3, 3, 3))
	local cutter = E.Deform.transform(E.Primitives.cylinder(0.7, 4, 20), CFrame.Angles(math.pi / 2, 0, 0))
	local cut, booleanReport = E.Boolean.subtract(body, cutter, { materialOffsetB = 1 })
	local detailed, detailReport = E.Adaptive.refine(cut, 0.4, {
		region = function(p)
			return p.Z > 1.4 and p.X * p.X + p.Y * p.Y < 1.3
		end,
		maxOperations = 150,
	})
	local patch = E.Primitives.grid(12, 12, Vector2.new(3, 3))
	for id, p in patch.vertices do
		patch.vertices[id] = p + Vector3.new(0, 0.15 * math.sin(p.X) * math.cos(p.Z), 0)
	end
	local mapped, uvReport = E.Conformal.lscm(patch)
	return { mesh = detailed, patch = mapped, boolean = booleanReport, detail = detailReport, uv = uvReport }
end
