--!strict
local U = require(script.Parent.Util)
local Q = require(script.Parent.Quaternion)
local Types = require(script.Parent.Types)
type Mesh = Types.Mesh
export type Bone = { name: string, parent: number?, bindLocal: CFrame }
-- Bone id -> local (pose) or world transform.
export type Pose = { [number]: CFrame }
export type SkinOptions = { recalculateNormals: boolean?, normalAngle: number? }
export type SkinReport = { weightedVertices: number, method: string }
export type IKOptions = { iterations: number?, tolerance: number? }
export type IKReport = { endpointError: number }
type RigData = { bones: { [number]: Bone }, order: { number }, nextId: number }
local Rig = {}
Rig.__index = Rig
export type Rig = typeof(setmetatable({} :: RigData, Rig))
function Rig.new(): Rig
	return setmetatable({ bones = {}, order = {}, nextId = 1 } :: RigData, Rig)
end
function Rig.addBone(self: Rig, name: string, parentId: number?, bindLocal: CFrame?): number
	assert(type(name) == "string" and #name > 0)
	assert(not parentId or self.bones[parentId], "Parent must exist first")
	for _, b in self.bones do
		assert(b.name ~= name, "Duplicate bone name")
	end
	local id = self.nextId
	self.nextId += 1
	self.bones[id] = { name = name, parent = parentId, bindLocal = bindLocal or CFrame.identity }
	table.insert(self.order, id)
	return id
end
function Rig.worldTransforms(self: Rig, pose: Pose?): Pose
	local world: Pose = {}
	for _, id in self.order do
		local b = self.bones[id]
		local localFrame = pose and pose[id] or b.bindLocal
		world[id] = b.parent and world[b.parent] * localFrame or localFrame
	end
	return world
end
function Rig.skin(self: Rig, mesh: Mesh, pose: Pose?): Mesh
	local bind = self:worldTransforms()
	local posed = self:worldTransforms(pose)
	local transforms = {}
	for id in self.bones do
		transforms[id] = posed[id] * bind[id]:Inverse()
	end
	local out = mesh:clone()
	for id, p in mesh.vertices do
		local result = Vector3.zero
		local total = 0
		for bone, w in mesh.weights[id] or {} :: { [number]: number } do
			assert(transforms[bone], "Unknown weighted bone")
			assert(w >= 0 and U.finite(w))
			result += transforms[bone]:PointToWorldSpace(p) * w
			total += w
		end
		if total > 0 then
			out.vertices[id] = result / total
		end
	end
	return out:recalculateNormals()
end
function Rig.skinDualQuaternion(self: Rig, mesh: Mesh, pose: Pose?, options: SkinOptions?): (Mesh, SkinReport)
	local options: SkinOptions = options or {}
	local bind, posed = self:worldTransforms(), self:worldTransforms(pose)
	local transforms = {}
	for id in self.bones do
		local cf = posed[id] * bind[id]:Inverse()
		local real = Q.fromCFrame(cf)
		local p = cf.Position
		local dual = Q.multiply({ p.X, p.Y, p.Z, 0 }, real)
		for i = 1, 4 do
			dual[i] *= 0.5
		end
		transforms[id] = { real = real, dual = dual }
	end
	local out = mesh:clone()
	local frames = {}
	local count = 0
	for id, p in mesh.vertices do
		local weights = mesh.weights[id] or {}
		local ids = U.keys(weights)
		local reference: Q.Quat?, biggest = nil, 0
		for _, bone in ids do
			local w = weights[bone]
			assert(transforms[bone], "Unknown weighted bone")
			assert(type(w) == "number" and U.finite(w) and w >= 0, "Invalid skin weight")
			if w > biggest then
				reference = transforms[bone].real
				biggest = w
			end
		end
		if not reference then
			continue
		end
		local real, dual = { 0, 0, 0, 0 }, { 0, 0, 0, 0 }
		for _, bone in ids do
			local q = transforms[bone]
			local w = weights[bone] * (Q.dot(reference, q.real) < 0 and -1 or 1)
			for k = 1, 4 do
				real[k] += q.real[k] * w
				dual[k] += q.dual[k] * w
			end
		end
		local norm = math.sqrt(Q.dot(real, real))
		assert(norm > 1e-15, "Degenerate dual-quaternion blend")
		for k = 1, 4 do
			real[k] /= norm
			dual[k] /= norm
		end
		local dot = Q.dot(real, dual)
		for k = 1, 4 do
			dual[k] -= real[k] * dot
		end
		local translation = Q.multiply(dual, Q.conjugate(real))
		local cf = Q.toCFrame(real, Vector3.new(translation[1], translation[2], translation[3]) * 2)
		frames[id] = cf
		out.vertices[id] = cf:PointToWorldSpace(p)
		count += 1
	end
	for _, face in out.faces do
		for i, id in face.vertices do
			local cf = frames[id]
			local c = face.corners[i]
			if cf then
				if c.normal then
					c.normal = U.unit(cf:VectorToWorldSpace(c.normal))
				end
				if c.tangent then
					c.tangent = U.unit(cf:VectorToWorldSpace(c.tangent))
				end
			end
		end
	end
	if options.recalculateNormals then
		out:recalculateNormals(options.normalAngle)
	end
	out.revision += 1
	return out, { weightedVertices = count, method = "dualQuaternion" }
end
function Rig.automaticWeights(self: Rig, mesh: Mesh, influences: number?, power: number?): Mesh
	local influences: number = influences or 4
	local power: number = power or 2
	U.integer(influences, 1)
	assert(power > 0 and #self.order > 0)
	local world = self:worldTransforms()
	local out = mesh:clone()
	local segments = {}
	for _, id in self.order do
		local b = self.bones[id]
		local a = b.parent and world[b.parent].Position or world[id].Position
		segments[id] = { a, world[id].Position }
	end
	for id, p in mesh.vertices do
		local candidates = {}
		for bone, s in segments do
			local ab = s[2] - s[1]
			local t = ab.Magnitude > 1e-12 and math.clamp((p - s[1]):Dot(ab) / ab:Dot(ab), 0, 1) or 0
			local d = (p - s[1] - ab * t).Magnitude
			table.insert(candidates, { id = bone, distance = d })
		end
		table.sort(candidates, function(a, b)
			return a.distance == b.distance and a.id < b.id or a.distance < b.distance
		end)
		local weights = {}
		local sum = 0
		for i = 1, math.min(influences, #candidates) do
			local c = candidates[i]
			local w = 1 / math.max(c.distance, 1e-4) ^ power
			weights[c.id] = w
			sum += w
		end
		for bone, w in weights do
			weights[bone] = w / sum
		end
		out.weights[id] = weights
	end
	return out
end
function Rig.normalizeWeights(mesh: Mesh, influences: number?): Mesh
	local out = mesh:clone()
	for id, weights in out.weights do
		local list = {}
		for bone, w in weights do
			if w > 0 then
				table.insert(list, { bone, w })
			end
		end
		table.sort(list, function(a, b)
			return a[2] > b[2]
		end)
		local new, sum = {}, 0
		for i = 1, math.min(influences or #list, #list) do
			new[list[i][1]] = list[i][2]
			sum += list[i][2]
		end
		for bone, w in new do
			new[bone] = w / sum
		end
		out.weights[id] = new
	end
	return out
end
function Rig.fabrik(
	points: { Vector3 },
	target: Vector3,
	iterations: number?,
	tolerance: number?
): { Vector3 }
	assert(#points >= 2)
	local p = table.clone(points)
	local lengths, total = {}, 0
	local root = p[1]
	for i = 1, #p - 1 do
		lengths[i] = (p[i + 1] - p[i]).Magnitude
		assert(lengths[i] > 0)
		total += lengths[i]
	end
	if (target - root).Magnitude >= total then
		local d = U.unit(target - root)
		for i = 2, #p do
			p[i] = p[i - 1] + d * lengths[i - 1]
		end
		return p
	end
	for _ = 1, iterations or 32 do
		p[#p] = target
		for i = #p - 1, 1, -1 do
			p[i] = p[i + 1] + U.unit(p[i] - p[i + 1]) * lengths[i]
		end
		p[1] = root
		for i = 2, #p do
			p[i] = p[i - 1] + U.unit(p[i] - p[i - 1]) * lengths[i - 1]
		end
		if (p[#p] - target).Magnitude <= (tolerance or 1e-5) then
			break
		end
	end
	return p
end
function Rig.blendShapes(base: Mesh, shapes: { [string]: Mesh }, weights: { [string]: number }): Mesh
	local out = base:clone()
	for name, shape in shapes do
		local w = weights[name] or 0
		if w ~= 0 then
			for id, p in base.vertices do
				assert(shape.vertices[id], "Blend shape topology mismatch")
				out.vertices[id] += (shape.vertices[id] - p) * w
			end
		end
	end
	return out:recalculateNormals()
end
function Rig.solveIK(
	self: Rig,
	pose: Pose?,
	chain: { number },
	target: Vector3,
	options: IKOptions?
): (Pose, IKReport)
	local options: IKOptions = options or {}
	assert(#chain >= 2)
	local world = self:worldTransforms(pose)
	local points = {}
	for i, id in chain do
		assert(world[id])
		if i > 1 then
			assert(self.bones[id].parent == chain[i - 1], "IK chain must be contiguous")
		end
		points[i] = world[id].Position
	end
	local solved = Rig.fabrik(points, target, options.iterations, options.tolerance)
	local changed = {}
	for i, id in chain do
		local rotation = world[id].Rotation
		if i < #chain then
			local a = U.unit(points[i + 1] - points[i])
			local b = U.unit(solved[i + 1] - solved[i])
			local axis = a:Cross(b)
			local dot = math.clamp(a:Dot(b), -1, 1)
			if axis.Magnitude > 1e-8 then
				rotation = CFrame.fromAxisAngle(axis.Unit, math.acos(dot)) * rotation
			elseif dot < 0 then
				local perpendicular = U.frame(a)
				rotation = CFrame.fromAxisAngle(perpendicular, math.pi) * rotation
			end
		end
		changed[id] = CFrame.new(solved[i]) * rotation
	end
	local result = {}
	for _, id in self.order do
		result[id] = pose and pose[id] or self.bones[id].bindLocal
	end
	for _, id in chain do
		local parent = self.bones[id].parent
		local parentWorld = parent and (changed[parent] or world[parent]) or CFrame.identity
		result[id] = parentWorld:Inverse() * changed[id]
	end
	return result, { endpointError = (solved[#solved] - target).Magnitude }
end
return Rig
