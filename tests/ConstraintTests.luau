return function(E)
	local C = E.Constraints
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function vec(a, b, eps)
		assert((a - b).Magnitude < (eps or 1e-5), tostring(a) .. " != " .. tostring(b))
	end
	local function frame(a, b)
		vec(a.Position, b.Position)
		vec(a.RightVector, b.RightVector)
		vec(a.UpVector, b.UpVector)
		vec(a.LookVector, b.LookVector)
	end
	local function near(a, b)
		assert(math.abs(a - b) < 1e-5, tostring(a) .. " != " .. tostring(b))
	end
	test("copy location masks, inversion, offset and influence", function()
		local owner = CFrame.new(1, 2, 3) * CFrame.Angles(0.2, 0.4, 0.1)
		local out = C.copyLocation(
			owner,
			Vector3.new(5, 8, 11),
			{ axes = { X = true, Z = true }, invert = { Z = true }, offset = Vector3.yAxis, influence = 0.5 }
		)
		vec(out.Position, Vector3.new(3, 2.5, -4))
		frame(out.Rotation, owner.Rotation)
		vec(owner.Position, Vector3.new(1, 2, 3))
	end)
	test("rotation and transform composition retain declared order", function()
		local owner = CFrame.new(1, 2, 3) * CFrame.Angles(0.4, 0, 0)
		local target = CFrame.new(5, 6, 7) * CFrame.Angles(0, 0.7, 0)
		frame(
			C.copyRotation(owner, target, { mix = "BEFORE" }),
			CFrame.new(owner.Position) * target.Rotation * owner.Rotation
		)
		frame(
			C.copyRotation(owner, target, { mix = "AFTER" }),
			CFrame.new(owner.Position) * owner.Rotation * target.Rotation
		)
		frame(C.copyTransform(owner, target, { offset = CFrame.new(1, 0, 0) }), target * CFrame.new(1, 0, 0))
	end)
	test("location, XYZ rotation, distance and oblique floor limits", function()
		vec(
			C.limitLocation(CFrame.new(3, -2, 5), { min = Vector3.zero, max = Vector3.new(2, 4, 6) }).Position,
			Vector3.new(2, 0, 5)
		)
		frame(
			C.limitRotation(
				CFrame.Angles(0.8, -0.4, 0.1),
				{ min = Vector3.new(-0.2, -0.2, -0.2), max = Vector3.new(0.2, 0.2, 0.2) }
			),
			CFrame.Angles(0.2, -0.2, 0.1)
		)
		vec(
			C.limitDistance(CFrame.new(3, 4, 0), Vector3.zero, { distance = 2, mode = "INSIDE" }).Position,
			Vector3.new(1.2, 1.6, 0)
		)
		vec(
			C.limitDistance(CFrame.identity, Vector3.zero, { distance = 2, mode = "OUTSIDE" }).Position,
			Vector3.new(2, 0, 0)
		)
		local normal = Vector3.new(1, 1, 0).Unit
		local floor = C.floor(CFrame.new(-2, -2, 3), { normal = normal, offset = 1 })
		near(floor.Position:Dot(normal), 1)
		near(floor.Position.Z, 3)
	end)
	test("track-to aligns six signed axes with valid perpendicular up", function()
		local axes = {
			X = Vector3.xAxis,
			Y = Vector3.yAxis,
			Z = Vector3.zAxis,
			["-X"] = -Vector3.xAxis,
			["-Y"] = -Vector3.yAxis,
			["-Z"] = -Vector3.zAxis,
		}
		local owner = CFrame.new(2, 3, 4) * CFrame.Angles(0.5, 0.2, 0.3)
		local target = Vector3.new(5, 8, -2)
		for name, axis in axes do
			local up = math.abs(axis.Y) > 0.9 and "X" or "Y"
			local out = C.trackTo(owner, target, { trackAxis = name, upAxis = up })
			vec(out:VectorToWorldSpace(axis), (target - owner.Position).Unit)
			near(out.RightVector:Dot(out.UpVector), 0)
			near(out.RightVector:Cross(out.UpVector):Dot(-out.LookVector), 1)
		end
		local vertical = C.trackTo(CFrame.identity, Vector3.yAxis)
		vec(vertical.LookVector, Vector3.yAxis)
	end)
	test("damped and locked track handle antipodes and constrained planes", function()
		local owner = CFrame.Angles(0, 0, 0.7)
		local out = C.dampedTrack(owner, Vector3.zAxis)
		vec(out.LookVector, Vector3.zAxis)
		frame(out, C.dampedTrack(owner, Vector3.zAxis))
		owner = CFrame.Angles(0.2, 0.3, 0.4)
		local target = Vector3.new(2, 5, -3)
		out = C.lockedTrack(owner, target)
		vec(out.UpVector, owner.UpVector)
		local projected = target - owner.UpVector * target:Dot(owner.UpVector)
		vec(out.LookVector, projected.Unit)
		frame(C.lockedTrack(owner, owner.UpVector), owner)
	end)
	test("path following uses arc length and transforms tangent", function()
		local path = E.Stroke.path({ Vector3.zero, Vector3.new(2, 0, 0), Vector3.new(2, 0, 2) })
		local cf = CFrame.new(1, 2, 3) * CFrame.Angles(0, math.pi / 2, 0)
		local out = C.followPath(CFrame.identity, path, 0.75, { pathFrame = cf })
		vec(out.Position, cf:PointToWorldSpace(Vector3.new(2, 0, 1)))
		vec(out.LookVector, cf:VectorToWorldSpace(Vector3.zAxis))
	end)
	test("child-of inverse prevents rest jump and follows target movement", function()
		local owner = CFrame.new(3, 4, 5) * CFrame.Angles(0.1, 0.2, 0.3)
		local rest = CFrame.new(9, 2, 1) * CFrame.Angles(0.4, 0.2, 0.8)
		local inverse = C.setInverse(rest)
		frame(C.childOf(owner, rest, { inverse = inverse }), owner)
		local motion = CFrame.new(2, 1, -3) * CFrame.Angles(0.2, 0.5, -0.1)
		frame(C.childOf(owner, motion * rest, { inverse = inverse }), motion * owner)
	end)
	test("constraint graph honors world/local spaces and stack order", function()
		local nodes = {
			parent = { localFrame = CFrame.new(10, 0, 0) },
			target = { localFrame = CFrame.new(2, 3, 4) },
			child = {
				parent = "parent",
				localFrame = CFrame.new(1, 0, 0),
				constraints = {
					{ type = "COPY_LOCATION", target = "target" },
					{ type = "LIMIT_LOCATION", space = "LOCAL", min = Vector3.new(-3, -10, -10) },
				},
			},
		}
		local r = C.evaluate(nodes)
		vec(r.localFrames.child.Position, Vector3.new(-3, 3, 4))
		vec(r.world.child.Position, Vector3.new(7, 3, 4))
		vec(nodes.child.localFrame.Position, Vector3.xAxis)
		nodes.child.constraints[1].space = "LOCAL"
		r = C.evaluate(nodes)
		vec(r.world.child.Position, Vector3.new(12, 3, 4))
	end)
	test("graph rejects cycles and missing dependencies but ignores muted edges", function()
		local nodes =
			{ a = { constraints = { { type = "COPY_TRANSFORM", target = "b" } } }, b = { parent = "a" } }
		assert(not pcall(function()
			C.evaluate(nodes)
		end))
		nodes.a.constraints[1].muted = true
		assert(C.evaluate(nodes).world.b)
		assert(not pcall(function()
			C.evaluate({ a = { parent = "missing" } })
		end))
		assert(not pcall(function()
			C.evaluate({ a = { constraints = { { type = "UNKNOWN" } } } })
		end))
	end)
	test("rig bridge returns usable constrained local poses", function()
		local rig = E.Rig.new()
		local root = rig:addBone("Root", nil, CFrame.new(1, 0, 0))
		local child = rig:addBone("Child", root, CFrame.new(0, 2, 0))
		local pose, r =
			C.rig(rig, nil, { [child] = { { type = "COPY_LOCATION", target = CFrame.new(5, 6, 7) } } })
		vec(pose[child].Position, Vector3.new(4, 6, 7))
		vec(rig:worldTransforms(pose)[child].Position, Vector3.new(5, 6, 7))
		frame(r.world[child], rig:worldTransforms(pose)[child])
	end)
	test("dual-quaternion twist preserves cross-section radius", function()
		local mesh = E.Primitives.box(Vector3.new(2, 2, 2))
		local rig = E.Rig.new()
		local a = rig:addBone("A")
		local b = rig:addBone("B")
		for id in mesh.vertices do
			mesh.weights[id] = { [a] = 0.5, [b] = 0.5 }
		end
		local pose = { [a] = CFrame.Angles(0, 0, -math.pi / 3), [b] = CFrame.Angles(0, 0, math.pi / 3) }
		local linear = rig:skin(mesh, pose)
		local dq = rig:skinDualQuaternion(mesh, pose)
		for id, p in mesh.vertices do
			local radius = Vector2.new(p.X, p.Y).Magnitude
			near(Vector2.new(linear.vertices[id].X, linear.vertices[id].Y).Magnitude, radius * 0.5)
			near(Vector2.new(dq.vertices[id].X, dq.vertices[id].Y).Magnitude, radius)
		end
		near(dq:volume(), mesh:volume())
	end)
	test("dual-quaternion bind correction and normals match a rigid transform", function()
		local m = E.Primitives.box(Vector3.one)
		local rig = E.Rig.new()
		local bind = CFrame.new(2, 3, 4) * CFrame.Angles(0.4, 0.5, 0.6)
		local bone = rig:addBone("Bone", nil, bind)
		local transform = CFrame.new(-2, 1, 3) * CFrame.Angles(0.7, -0.2, 0.8)
		for id in m.vertices do
			m.weights[id] = { [bone] = 3 }
		end
		local out, r = rig:skinDualQuaternion(m, { [bone] = transform * bind })
		assert(r.weightedVertices == 8)
		for id, p in m.vertices do
			vec(out.vertices[id], transform:PointToWorldSpace(p))
		end
		for fid, f in out.faces do
			for i, c in f.corners do
				vec(c.normal, transform:VectorToWorldSpace(m.faces[fid].corners[i].normal))
			end
		end
	end)
	test("dual-quaternion hemisphere alignment and normalized translation", function()
		local m = E.Primitives.box(Vector3.one)
		local rig = E.Rig.new()
		local a = rig:addBone("A")
		local b = rig:addBone("B")
		for id in m.vertices do
			m.weights[id] = { [a] = 2, [b] = 2 }
		end
		local out = rig:skinDualQuaternion(
			m,
			{ [a] = CFrame.Angles(0, 0, math.rad(170)), [b] = CFrame.Angles(0, 0, math.rad(-170)) }
		)
		for id, p in m.vertices do
			vec(out.vertices[id], Vector3.new(-p.X, -p.Y, p.Z))
		end
		out = rig:skinDualQuaternion(m, { [a] = CFrame.new(2, 0, 0), [b] = CFrame.new(0, 4, 0) })
		for id, p in m.vertices do
			vec(out.vertices[id], p + Vector3.new(1, 2, 0))
		end
		local owner = CFrame.Angles(0.4, 0, 0)
		local target = CFrame.Angles(0.8, 0.7, 0.3)
		frame(
			C.copyRotation(owner, target, { mix = "AFTER", axes = { Y = true } }),
			owner * CFrame.Angles(0, 0.7, 0)
		)
	end)
	report.success = report.failed == 0
	return report
end
