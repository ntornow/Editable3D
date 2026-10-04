--!strict
-- Hamilton quaternions, array order {x,y,z,w}; multiplication composes right first.
local U = require(script.Parent.Util)
export type Quat = { number }
local Q = { identity = table.freeze({ 0, 0, 0, 1 }) :: Quat }
local function checked(q: Quat): Quat
	assert(type(q) == "table" and #q == 4, "Expected quaternion {x,y,z,w}")
	for _, v in q do
		assert(type(v) == "number" and U.finite(v), "Nonfinite quaternion")
	end
	return q
end
function Q.new(x: number, y: number, z: number, w: number): Quat
	return checked({ x, y, z, w })
end
function Q.dot(a: Quat, b: Quat): number
	checked(a)
	checked(b)
	return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] + a[4] * b[4]
end
function Q.normalize(q: Quat): Quat
	local n = math.sqrt(Q.dot(q, q))
	assert(n > 1e-15, "Zero quaternion")
	return { q[1] / n, q[2] / n, q[3] / n, q[4] / n }
end
function Q.conjugate(q: Quat): Quat
	checked(q)
	return { -q[1], -q[2], -q[3], q[4] }
end
function Q.inverse(q: Quat): Quat
	local n = Q.dot(q, q)
	assert(n > 1e-30, "Zero quaternion")
	return { -q[1] / n, -q[2] / n, -q[3] / n, q[4] / n }
end
function Q.multiply(a: Quat, b: Quat): Quat
	checked(a)
	checked(b)
	local x, y, z, w = table.unpack(a)
	local X, Y, Z, W = table.unpack(b)
	return {
		w * X + x * W + y * Z - z * Y,
		w * Y - x * Z + y * W + z * X,
		w * Z + x * Y - y * X + z * W,
		w * W - x * X - y * Y - z * Z,
	}
end
function Q.fromAxisAngle(axis: Vector3, angle: number): Quat
	assert(U.vector(axis) and U.finite(angle), "Finite axis/angle required")
	if math.abs(angle) < 1e-15 then
		return table.clone(Q.identity)
	end
	assert(axis.Magnitude > 1e-12, "Rotation axis is zero")
	local v = axis.Unit * math.sin(angle / 2)
	return Q.normalize({ v.X, v.Y, v.Z, math.cos(angle / 2) })
end
function Q.toAxisAngle(q: Quat): (Vector3, number)
	q = Q.normalize(q)
	if q[4] < 0 then
		q = { -q[1], -q[2], -q[3], -q[4] }
	end
	local length = math.sqrt(q[1] ^ 2 + q[2] ^ 2 + q[3] ^ 2)
	if length < 1e-12 then
		return Vector3.xAxis, 0
	end
	return Vector3.new(q[1], q[2], q[3]) / length, 2 * math.atan2(length, q[4])
end
function Q.fromCFrame(cf: CFrame): Quat
	local _, _, _, m00, m01, m02, m10, m11, m12, m20, m21, m22 = cf:GetComponents()
	local trace = m00 + m11 + m22
	local q: Quat
	if trace > 0 then
		local s = math.sqrt(trace + 1) * 2
		q = { (m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s, s / 4 }
	elseif m00 > m11 and m00 > m22 then
		local s = math.sqrt(1 + m00 - m11 - m22) * 2
		q = { s / 4, (m01 + m10) / s, (m02 + m20) / s, (m21 - m12) / s }
	elseif m11 > m22 then
		local s = math.sqrt(1 + m11 - m00 - m22) * 2
		q = { (m01 + m10) / s, s / 4, (m12 + m21) / s, (m02 - m20) / s }
	else
		local s = math.sqrt(1 + m22 - m00 - m11) * 2
		q = { (m02 + m20) / s, (m12 + m21) / s, s / 4, (m10 - m01) / s }
	end
	return Q.normalize(q)
end
function Q.toCFrame(q: Quat, position: Vector3?): CFrame
	q = Q.normalize(q)
	local position: Vector3 = position or Vector3.zero
	assert(U.vector(position), "Invalid translation")
	local x, y, z, w = table.unpack(q)
	return CFrame.new(
		position.X,
		position.Y,
		position.Z,
		1 - 2 * (y * y + z * z),
		2 * (x * y - z * w),
		2 * (x * z + y * w),
		2 * (x * y + z * w),
		1 - 2 * (x * x + z * z),
		2 * (y * z - x * w),
		2 * (x * z - y * w),
		2 * (y * z + x * w),
		1 - 2 * (x * x + y * y)
	)
end
function Q.rotate(q: Quat, v: Vector3): Vector3
	return Q.toCFrame(q):VectorToWorldSpace(v)
end
function Q.slerp(a: Quat, b: Quat, t: number): Quat
	assert(U.finite(t), "Invalid interpolation parameter")
	a, b = Q.normalize(a), Q.normalize(b)
	local dot = Q.dot(a, b)
	if dot < 0 then
		b = { -b[1], -b[2], -b[3], -b[4] }
		dot = -dot
	end
	local wa, wb = 1 - t, t
	if dot < 0.9995 then
		local theta = math.acos(math.clamp(dot, -1, 1))
		local sin = math.sin(theta)
		wa, wb = math.sin((1 - t) * theta) / sin, math.sin(t * theta) / sin
	end
	return Q.normalize({
		a[1] * wa + b[1] * wb,
		a[2] * wa + b[2] * wb,
		a[3] * wa + b[3] * wb,
		a[4] * wa + b[4] * wb,
	})
end
function Q.rotationVector(q: Quat): Vector3
	local axis, angle = Q.toAxisAngle(q)
	return axis * angle
end
function Q.fromRotationVector(v: Vector3): Quat
	assert(U.vector(v), "Invalid rotation vector")
	return Q.fromAxisAngle(v, v.Magnitude)
end
function Q.integrate(q: Quat, angularVelocity: Vector3, dt: number, localSpace: boolean?): Quat
	assert(U.finite(dt), "Invalid time step")
	local delta = Q.fromRotationVector(angularVelocity * dt)
	return Q.normalize(localSpace and Q.multiply(q, delta) or Q.multiply(delta, q))
end
function Q.squad(a: Quat, controlA: Quat, controlB: Quat, b: Quat, t: number): Quat
	return Q.slerp(Q.slerp(a, b, t), Q.slerp(controlA, controlB, t), 2 * t * (1 - t))
end
return Q
