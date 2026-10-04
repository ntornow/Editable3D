-- Replace these synthetic observations with manually identified photo landmarks.
return function()
	local E = require(script.Parent.Parent)
	local model = E.Primitives.box()
	local reference = E.Camera.new(CFrame.lookAt(Vector3.new(3, 2, 8), Vector3.zero), 45, 640, 480)
	local landmarks = {}
	for _, p in model.vertices do
		table.insert(landmarks, { point = p, pixel = E.Camera.project(reference, p) })
	end
	local initial = E.Camera.new(CFrame.lookAt(Vector3.new(3.2, 2.1, 8.4), Vector3.zero), 48, 640, 480)
	return E.Camera.fit(initial, landmarks, { iterations = 60 })
end
