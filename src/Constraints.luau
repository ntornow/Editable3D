-- Ordered rigid-transform constraints. No Instances, hidden time or scene mutation.
local U = require(script.Parent.Util)
local C = {}
local axes = {
	X = Vector3.xAxis,
	Y = Vector3.yAxis,
	Z = Vector3.zAxis,
	["-X"] = -Vector3.xAxis,
	["-Y"] = -Vector3.yAxis,
	["-Z"] = -Vector3.zAxis,
}
local function frame(cf)
	assert(typeof(cf) == "CFrame", "Expected CFrame")
	for _, v in { cf:GetComponents() } do
		assert(U.finite(v), "Nonfinite transform")
	end
	return cf
end
local function position(target)
	if typeof(target) == "CFrame" then
		return frame(target).Position
	end
	assert(U.vector(target), "Expected target position or CFrame")
	return target
end
local function mix(owner, result, options)
	local t = options and options.influence or 1
	assert(type(t) == "number" and U.finite(t) and t >= 0 and t <= 1, "Influence must lie in [0,1]")
	return t == 1 and result or frame(owner):Lerp(result, t)
end
local function selectVector(a, b, options)
	local out = {}
	for i, key in { "X", "Y", "Z" } do
		local value = options.invert and options.invert[key] and -b[key] or b[key]
		out[i] = (not options.axes or options.axes[key]) and value or a[key]
	end
	return Vector3.new(table.unpack(out))
end
local function perpendicular(v)
	local axis = math.abs(v.X) <= math.abs(v.Y)
			and (math.abs(v.X) <= math.abs(v.Z) and Vector3.xAxis or Vector3.zAxis)
		or (math.abs(v.Y) <= math.abs(v.Z) and Vector3.yAxis or Vector3.zAxis)
	return v:Cross(axis).Unit
end
local function rotationBetween(a, b)
	local cross = a:Cross(b)
	local dot = math.clamp(a:Dot(b), -1, 1)
	if cross.Magnitude > 1e-8 then
		return CFrame.fromAxisAngle(cross.Unit, math.atan2(cross.Magnitude, dot))
	end
	return dot < 0 and CFrame.fromAxisAngle(perpendicular(a), math.pi) or CFrame.identity
end
local function bounded(v, options)
	if options.min then
		assert(U.vector(options.min), "Invalid lower limit")
	end
	if options.max then
		assert(U.vector(options.max), "Invalid upper limit")
	end
	local values = {}
	for i, key in { "X", "Y", "Z" } do
		local low, high =
			options.min and options.min[key] or -math.huge, options.max and options.max[key] or math.huge
		assert(low <= high, "Reversed limits")
		values[i] = math.clamp(v[key], low, high)
	end
	return Vector3.new(table.unpack(values))
end
function C.copyLocation(owner, target, options)
	options = options or {}
	frame(owner)
	local p = selectVector(owner.Position, position(target), options) + (options.offset or Vector3.zero)
	return mix(owner, CFrame.new(p) * owner.Rotation, options)
end
function C.copyRotation(owner, target, options)
	options = options or {}
	frame(owner)
	frame(target)
	local rotation = target.Rotation
	local mode = options.mix or "REPLACE"
	if options.axes or options.invert then
		local a = mode == "REPLACE" and Vector3.new(owner:ToEulerAnglesXYZ()) or Vector3.zero
		local b = Vector3.new(target:ToEulerAnglesXYZ())
		local v = selectVector(a, b, options)
		rotation = CFrame.Angles(v.X, v.Y, v.Z)
	end
	if mode == "BEFORE" then
		rotation = rotation * owner.Rotation
	elseif mode == "AFTER" then
		rotation = owner.Rotation * rotation
	else
		assert(mode == "REPLACE", "Unknown rotation mix")
	end
	return mix(owner, CFrame.new(owner.Position) * rotation, options)
end
function C.copyTransform(owner, target, options)
	options = options or {}
	frame(owner)
	frame(target)
	return mix(owner, target * (options.offset or CFrame.identity), options)
end
function C.limitLocation(owner, options)
	options = options or {}
	frame(owner)
	return mix(owner, CFrame.new(bounded(owner.Position, options)) * owner.Rotation, options)
end
function C.limitRotation(owner, options)
	options = options or {}
	frame(owner)
	local angles = bounded(Vector3.new(owner:ToEulerAnglesXYZ()), options)
	return mix(owner, CFrame.new(owner.Position) * CFrame.Angles(angles.X, angles.Y, angles.Z), options)
end
function C.limitDistance(owner, target, options)
	options = options or {}
	frame(owner)
	local distance = options.distance or 0
	assert(type(distance) == "number" and U.finite(distance) and distance >= 0, "Invalid distance")
	local p = position(target)
	local delta = owner.Position - p
	local length = delta.Magnitude
	local mode = options.mode or "SURFACE"
	assert(mode == "INSIDE" or mode == "OUTSIDE" or mode == "SURFACE", "Invalid distance mode")
	if (mode == "INSIDE" and length <= distance) or (mode == "OUTSIDE" and length >= distance) then
		return owner
	end
	local fallback = options.fallback or owner.RightVector
	assert(U.vector(fallback) and fallback.Magnitude > 1e-10, "Invalid distance fallback")
	return mix(owner, CFrame.new(p + U.unit(delta, fallback.Unit) * distance) * owner.Rotation, options)
end
function C.floor(owner, options)
	options = options or {}
	frame(owner)
	local n = options.normal or Vector3.yAxis
	assert(U.vector(n) and n.Magnitude > 1e-10, "Invalid floor normal")
	n = n.Unit
	local point = options.point or Vector3.zero
	assert(U.vector(point), "Invalid floor point")
	local offset = options.offset or 0
	assert(type(offset) == "number" and U.finite(offset), "Invalid floor offset")
	local distance = (owner.Position - point):Dot(n) - offset
	return distance < 0 and mix(owner, CFrame.new(owner.Position - n * distance) * owner.Rotation, options)
		or owner
end
function C.trackTo(owner, target, options)
	options = options or {}
	frame(owner)
	local delta = position(target) - owner.Position
	if delta.Magnitude < 1e-10 then
		return owner
	end
	local forward = delta.Unit
	local localForward = assert(axes[options.trackAxis or "-Z"], "Invalid track axis")
	local localUp = assert(axes[options.upAxis or "Y"], "Invalid up axis")
	assert(math.abs(localForward:Dot(localUp)) < 1e-6, "Track and up axes must differ")
	local up = options.up or Vector3.yAxis
	assert(U.vector(up) and up.Magnitude > 1e-10, "Invalid up vector")
	local right = forward:Cross(up)
	if right.Magnitude < 1e-8 then
		right = perpendicular(forward)
	else
		right = right.Unit
	end
	local desired = CFrame.fromMatrix(owner.Position, right, right:Cross(forward), -forward)
	local basis = CFrame.fromMatrix(Vector3.zero, localForward:Cross(localUp), localUp, -localForward)
	return mix(owner, desired * basis:Inverse(), options)
end
function C.dampedTrack(owner, target, options)
	options = options or {}
	frame(owner)
	local delta = position(target) - owner.Position
	if delta.Magnitude < 1e-10 then
		return owner
	end
	local trackAxis = assert(axes[options.trackAxis or "-Z"], "Invalid track axis")
	local from = owner:VectorToWorldSpace(trackAxis)
	local rotation = rotationBetween(from, delta.Unit) * owner.Rotation
	return mix(owner, CFrame.new(owner.Position) * rotation, options)
end
function C.lockedTrack(owner, target, options)
	options = options or {}
	frame(owner)
	local forward = assert(axes[options.trackAxis or "-Z"], "Invalid track axis")
	local lock = assert(axes[options.lockAxis or "Y"], "Invalid lock axis")
	assert(math.abs(forward:Dot(lock)) < 1e-6, "Track and lock axes must differ")
	lock = owner:VectorToWorldSpace(lock)
	forward = owner:VectorToWorldSpace(forward)
	local delta = position(target) - owner.Position
	local targetLength = delta.Magnitude
	delta -= lock * delta:Dot(lock)
	if delta.Magnitude < 1e-7 * math.max(1, targetLength) then
		return owner
	end
	local to = delta.Unit
	local angle = math.atan2(lock:Dot(forward:Cross(to)), math.clamp(forward:Dot(to), -1, 1))
	return mix(
		owner,
		CFrame.new(owner.Position) * CFrame.fromAxisAngle(lock, angle) * owner.Rotation,
		options
	)
end
function C.followPath(owner, path, factor, options)
	options = options or {}
	frame(owner)
	assert(type(factor) == "number" and U.finite(factor), "Invalid path factor")
	local p, tangent = path:sample(factor * path.length)
	local pathFrame = frame(options.pathFrame or CFrame.identity)
	p = pathFrame:PointToWorldSpace(p)
	tangent = pathFrame:VectorToWorldSpace(tangent)
	local result = CFrame.new(p) * owner.Rotation
	if options.followRotation ~= false then
		local config = table.clone(options)
		config.influence = 1
		result = C.trackTo(result, p + tangent, config)
	end
	result *= options.offset or CFrame.identity
	return mix(owner, result, options)
end
function C.setInverse(targetRest)
	return frame(targetRest):Inverse()
end
function C.childOf(owner, target, options)
	options = options or {}
	frame(owner)
	frame(target)
	return mix(owner, target * frame(options.inverse or CFrame.identity) * owner, options)
end
local operators = {
	COPY_LOCATION = C.copyLocation,
	COPY_ROTATION = C.copyRotation,
	COPY_TRANSFORM = C.copyTransform,
	LIMIT_DISTANCE = C.limitDistance,
	TRACK_TO = C.trackTo,
	DAMPED_TRACK = C.dampedTrack,
	LOCKED_TRACK = C.lockedTrack,
	CHILD_OF = C.childOf,
}
local localOperators = { LIMIT_LOCATION = C.limitLocation, LIMIT_ROTATION = C.limitRotation, FLOOR = C.floor }
function C.evaluate(nodes, pose)
	local world, locals, visiting, order = {}, {}, {}, {}
	local function visit(id)
		if world[id] then
			return world[id]
		end
		local node = assert(nodes[id], "Missing constraint node " .. tostring(id))
		assert(not visiting[id], "Constraint/parent dependency cycle")
		visiting[id] = true
		local parent = node.parent and visit(node.parent) or CFrame.identity
		local current = frame(pose and pose[id] or node.localFrame or CFrame.identity)
		for _, constraint in node.constraints or {} do
			if constraint.muted or constraint.influence == 0 then
				continue
			end
			local space = constraint.space or "WORLD"
			assert(space == "WORLD" or space == "LOCAL", "Invalid owner space")
			local owner = space == "LOCAL" and current or parent * current
			local target
			if constraint.target ~= nil then
				if typeof(constraint.target) == "CFrame" or typeof(constraint.target) == "Vector3" then
					target = constraint.target
				else
					local resolved = visit(constraint.target)
					local targetSpace = constraint.targetSpace or "WORLD"
					assert(targetSpace == "WORLD" or targetSpace == "LOCAL", "Invalid target space")
					target = targetSpace == "LOCAL" and locals[constraint.target] or resolved
				end
			end
			local result
			if operators[constraint.type] then
				result =
					operators[constraint.type](owner, assert(target, "Constraint needs a target"), constraint)
			elseif localOperators[constraint.type] then
				result = localOperators[constraint.type](owner, constraint)
			elseif constraint.type == "FOLLOW_PATH" then
				local options = table.clone(constraint)
				options.pathFrame = target or options.pathFrame
				result = C.followPath(owner, assert(constraint.path), constraint.factor or 0, options)
			else
				error("Unknown constraint type " .. tostring(constraint.type))
			end
			current = space == "LOCAL" and result or parent:Inverse() * result
		end
		locals[id] = current
		world[id] = parent * current
		visiting[id] = nil
		order[#order + 1] = id
		return world[id]
	end
	for _, id in U.keys(nodes) do
		visit(id)
	end
	return { world = world, localFrames = locals, order = order }
end
function C.rig(rig, pose, stacks)
	local nodes = {}
	for id, bone in rig.bones do
		nodes[id] = { parent = bone.parent, localFrame = bone.bindLocal, constraints = stacks and stacks[id] }
	end
	local result = C.evaluate(nodes, pose)
	return result.localFrames, result
end
return C
