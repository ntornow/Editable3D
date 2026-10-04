-- Four pure-data variants with reproducible crease channels and a JSON checkpoint.
return function(E)
	E = E or require(script.Parent.Parent)
	local base = E.Primitives.box(Vector3.new(4, 2, 3))
	local hard, soft = {}, {}
	for key, edge in base:topology().edges do
		hard[key] = 10
		soft[key] = base.vertices[edge.a].Y == base.vertices[edge.b].Y and 2.5 or 0.5
	end
	local authored = E.Subdivision.crease(base, soft)
	return {
		smooth = E.Subdivision.catmullClark(base, 3),
		rounded = E.Subdivision.catmullClark(authored, 3),
		chaikin = E.Subdivision.catmullClark(authored, 3, { creasing = "chaikin" }),
		hard = E.Subdivision.catmullClark(E.Subdivision.crease(base, hard), 3),
		source = E.IO.encode(authored),
	}
end
