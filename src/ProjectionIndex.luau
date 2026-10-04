-- Private bounded deterministic nearest-primitive hierarchy for attribute projection.
local Spatial = require(script.Parent.Spatial)
local function build(items, visit)
	if #items == 0 then
		return nil
	end
	local lo, hi = items[1].lo, items[1].hi
	for _, item in items do
		visit()
		lo, hi = lo:Min(item.lo), hi:Max(item.hi)
	end
	local node = { lo = lo, hi = hi }
	if #items <= 8 then
		node.items = items
		return node
	end
	local size = hi - lo
	local axis = size.X >= size.Y and size.X >= size.Z and "X" or size.Y >= size.Z and "Y" or "Z"
	table.sort(items, function(a, b)
		visit()
		local x, y = a.center[axis], b.center[axis]
		return x == y and a.order < b.order or x < y
	end)
	local left, right = {}, {}
	for i, item in items do
		table.insert(i <= math.floor(#items / 2) and left or right, item)
	end
	node.left, node.right = build(left, visit), build(right, visit)
	return node
end
local function distance(point, lo, hi)
	local sum = 0
	for _, axis in { "X", "Y", "Z" } do
		local d = point[axis] - math.clamp(point[axis], lo[axis], hi[axis])
		sum += d * d
	end
	return sum
end
local function closest(root, point, maximum, visit, prefer)
	local best, result = maximum * maximum, nil
	local function search(node)
		visit()
		if not node or distance(point, node.lo, node.hi) > best then
			return
		end
		if node.items then
			for _, item in node.items do
				visit()
				local p, bary
				if item.c then
					p, bary = Spatial.closestTriangle(point, item.a, item.b, item.c)
				else
					local d = item.b - item.a
					local t = math.clamp((point - item.a):Dot(d) / d:Dot(d), 0, 1)
					p, bary = item.a:Lerp(item.b, t), Vector3.new(1 - t, t, 0)
				end
				local squared = distance(point, p, p)
				if
					squared <= best
					and (
						squared < best
						or not result
						or (
							prefer and prefer(item, result.item)
							or not prefer and item.order < result.item.order
						)
					)
				then
					best = squared
					result = { item = item, position = p, barycentric = bary, distance = math.sqrt(squared) }
				end
			end
		else
			local a, b = node.left, node.right
			if distance(point, a.lo, a.hi) > distance(point, b.lo, b.hi) then
				a, b = b, a
			end
			search(a)
			search(b)
		end
	end
	search(root)
	return result
end
return { build = build, closest = closest }
