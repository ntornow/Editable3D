--!strict
-- Editable cubic Bezier chains with explicit handle-pair modes and segment durations.
local U = require(script.Parent.Util)
local N = require(script.Parent.NURBS)
local B = {}

-- Handle modes: "free" | "aligned" | "vector" | "auto".
export type BezierNode = { position: Vector3, left: Vector3, right: Vector3, mode: string }
export type BezierCurve = {
	kind: string, -- "bezier"
	closed: boolean,
	nodes: { BezierNode },
	durations: { number },
}
export type BezierOptions = {
	closed: boolean?,
	maxNodes: number?,
	left: { Vector3 }?,
	right: { Vector3 }?,
	mode: string?,
	durations: { number }?,
}

local modes: { [string]: boolean } = { free = true, aligned = true, vector = true, auto = true }
local function checked(curve: BezierCurve): BezierCurve
	assert(
		type(curve) == "table" and curve.kind == "bezier" and type(curve.closed) == "boolean",
		"Bezier descriptor required"
	)
	assert(#curve.nodes >= 2 and #curve.nodes <= 3333, "Bezier chain requires 2..3333 nodes")
	assert(
		#curve.durations == #curve.nodes - (curve.closed and 0 or 1),
		"Bezier segment duration count mismatch"
	)
	local out: BezierCurve =
		{ kind = "bezier", closed = curve.closed, nodes = {}, durations = table.clone(curve.durations) }
	local sum = 0
	for _, d in out.durations do
		assert(type(d) == "number" and U.finite(d) and d > 0, "Positive finite Bezier durations required")
		sum += d
	end
	assert(U.finite(sum), "Bezier duration sum overflow")
	for i, node in curve.nodes do
		assert(
			U.vector(node.position) and U.vector(node.left) and U.vector(node.right) and modes[node.mode],
			"Invalid Bezier node"
		)
		out.nodes[i] = table.clone(node)
	end
	return out
end
local function resolve(curve: BezierCurve): BezierCurve
	local n = #curve.nodes
	for i, node in curve.nodes do
		local p = node.position
		local previous = (curve.closed or i > 1) and curve.nodes[(i - 2) % n + 1].position or nil
		local nextPoint = (curve.closed or i < n) and curve.nodes[i % n + 1].position or nil
		if node.mode == "vector" then
			node.left = previous and p:Lerp(previous, 1 / 3) or p
			node.right = nextPoint and p:Lerp(nextPoint, 1 / 3) or p
		elseif node.mode == "auto" then
			local before = previous and p - previous or Vector3.zero
			local after = nextPoint and nextPoint - p or Vector3.zero
			local a, b = before.Magnitude, after.Magnitude
			local direction = (a > 0 and before / a or Vector3.zero) + (b > 0 and after / b or Vector3.zero)
			if direction.Magnitude > 0 then
				direction = direction.Unit
			end
			node.left = p - direction * (a / 3)
			node.right = p + direction * (b / 3)
		elseif node.mode == "aligned" then
			local left, right = node.left - p, node.right - p
			if right.Magnitude > 0 then
				node.left = p - right.Unit * left.Magnitude
			elseif left.Magnitude > 0 then
				node.right = p - left.Unit * right.Magnitude
			end
		end
	end
	return checked(curve)
end
local function nodeAt(curve: BezierCurve, index: number): BezierNode
	U.integer(index, 1)
	return assert(curve.nodes[index], "Unknown Bezier node")
end
function B.new(points: { Vector3 }, options: BezierOptions?): BezierCurve
	local options: BezierOptions = options or {}
	assert(options.closed == nil or type(options.closed) == "boolean", "Bezier closure must be boolean")
	U.integer(options.maxNodes or 3333, 2)
	assert(not options.left or #options.left == #points, "Left handle count mismatch")
	assert(not options.right or #options.right == #points, "Right handle count mismatch")
	assert(#points >= 2 and #points <= (options.maxNodes or 3333), "Bezier node budget exceeded")
	local curve: BezierCurve =
		{ kind = "bezier", nodes = {}, closed = options.closed == true, durations = {} }
	assert(options.mode == nil or modes[options.mode], "Unknown Bezier handle mode")
	for i, p in points do
		assert(U.vector(p), "Finite Bezier positions required")
		local left, right = options.left and options.left[i], options.right and options.right[i]
		curve.nodes[i] = {
			position = p,
			left = left or p,
			right = right or p,
			mode = options.mode or ((left or right) and "free" or "auto"),
		}
	end
	local segments = #points - (curve.closed and 0 or 1)
	curve.durations = options.durations and table.clone(options.durations) or table.create(segments, 1)
	return resolve(checked(curve))
end
function B.setPoint(curve: BezierCurve, index: number, position: Vector3): BezierCurve
	assert(U.vector(position), "Finite Bezier position required")
	local out = checked(curve)
	local node = nodeAt(out, index)
	local delta = position - node.position
	node.position, node.left, node.right = position, node.left + delta, node.right + delta
	return resolve(out)
end
function B.setMode(curve: BezierCurve, index: number, mode: string): BezierCurve
	assert(modes[mode], "Unknown Bezier handle mode")
	local out = checked(curve)
	nodeAt(out, index).mode = mode
	return resolve(out)
end
function B.setHandle(curve: BezierCurve, index: number, side: string, position: Vector3): BezierCurve
	assert(side == "left" or side == "right", "Handle side must be left or right")
	assert(U.vector(position), "Finite handle position required")
	local out = checked(curve)
	local node = nodeAt(out, index)
	if node.mode == "auto" then
		node.mode = "aligned"
	elseif node.mode == "vector" then
		node.mode = "free"
	end
	-- The same node table, indexed by handle side ("left" or "right", asserted above).
	local handles: { [string]: Vector3 } = node :: any
	handles[side] = position
	if node.mode == "aligned" then
		local other = side == "left" and "right" or "left"
		local delta = position - node.position
		if delta.Magnitude > 0 then
			handles[other] = node.position - delta.Unit * (handles[other] - node.position).Magnitude
		end
	end
	-- Other nodes are unchanged. A zero moved handle has no tangent direction.
	return checked(out)
end
function B.split(curve: BezierCurve, segment: number, t: number): BezierCurve
	assert(type(t) == "number" and U.finite(t) and t > 0 and t < 1, "Interior split parameter required")
	local out = checked(curve)
	U.integer(segment, 1)
	assert(out.durations[segment] and #out.nodes < 3333, "Unknown Bezier segment or node budget exceeded")
	local a, b = out.nodes[segment], out.nodes[segment % #out.nodes + 1]
	local p, q, r = a.position:Lerp(a.right, t), a.right:Lerp(b.left, t), b.left:Lerp(b.position, t)
	local s, v = p:Lerp(q, t), q:Lerp(r, t)
	local middle = s:Lerp(v, t)
	a.right, b.left = p, r
	-- Resolved controls are retained exactly; automatic re-solving would change shape.
	a.mode, b.mode = "free", "free"
	table.insert(out.nodes, segment + 1, { position = middle, left = s, right = v, mode = "aligned" })
	local duration = out.durations[segment]
	out.durations[segment] = duration * t
	table.insert(out.durations, segment + 1, duration * (1 - t))
	return checked(out)
end
function B.reverse(curve: BezierCurve): BezierCurve
	local source, out = checked(curve), checked(curve)
	local n = #source.nodes
	for i = 1, n do
		local j = source.closed and (i == 1 and 1 or n - i + 2) or n - i + 1
		local node = table.clone(source.nodes[j])
		node.left, node.right = node.right, node.left
		out.nodes[i] = node
	end
	for i = 1, #source.durations do
		out.durations[i] = source.durations[#source.durations - i + 1]
	end
	return out
end
function B.toNURBS(curve: BezierCurve): N.Curve
	curve = checked(curve)
	local points: { Vector3 }, knots: { number } = {}, { 0, 0, 0, 0 }
	local sum, elapsed = 0, 0
	for _, d in curve.durations do
		sum += d
	end
	for i, duration in curve.durations do
		local a, b = curve.nodes[i], curve.nodes[i % #curve.nodes + 1]
		if i == 1 then
			table.insert(points, a.position)
		end
		table.insert(points, a.right)
		table.insert(points, b.left)
		table.insert(points, b.position)
		elapsed += duration
		local value = i == #curve.durations and 1 or elapsed / sum
		assert(value > knots[#knots], "Bezier duration is below parameter precision")
		for _ = 1, i == #curve.durations and 4 or 3 do
			table.insert(knots, value)
		end
	end
	return N.curve(points, 3, { knots = knots })
end
function B.evaluate(curve: BezierCurve, t: number): Vector3
	return N.evaluate(B.toNURBS(curve), t)
end
function B.derivatives(curve: BezierCurve, t: number): N.CurveDerivatives
	return N.derivatives(B.toNURBS(curve), t)
end
return B
