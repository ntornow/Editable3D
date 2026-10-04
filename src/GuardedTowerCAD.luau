-- Reduced projection is an optimization; nullification retries full projection.
local tower = require(script.Parent.TowerCAD)
return function(source, dimension, R, ctx, options, truth)
	options = table.clone(options or {})
	if options.projection == "collins" then
		return tower(source, dimension, R, ctx, options, truth)
	end
	local token = {}
	options.projection = "mccallum"
	options.nullificationFailure = token
	local ok, result = xpcall(function()
		return tower(source, dimension, R, ctx, options, truth)
	end, function(err)
		if options.diagnosticErrors and err ~= token then
			print(debug.traceback(tostring(err)))
		end
		return err
	end)
	if ok then
		result.projectionMethod = "mccallum"
		return result
	end
	if result ~= token then
		error(result, 0)
	end
	options.projection = "collins"
	result = tower(source, dimension, R, ctx, options, truth)
	result.projectionMethod = "collins"
	result.projectionFallback = true
	return result
end
