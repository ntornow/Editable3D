--!strict
-- Only repeat idempotent reads/staging. Asset creation is deliberately not retried.
export type Options = { attempts: number?, retryDelay: number? }
local R = {}
function R.validate(options: Options?)
	local o: Options = options or {}
	local attempts = o.attempts or 3
	local delay = o.retryDelay or 0.25
	assert(attempts >= 1 and attempts <= 10 and attempts % 1 == 0, "Invalid retry attempts")
	assert(delay >= 0 and delay < math.huge, "Invalid retry delay")
	return attempts, delay
end
function R.run<T>(fn: () -> T, options: Options?, check: () -> (), sleep: (number) -> ()): T
	local attempts, delay = R.validate(options)
	local problem = ""
	for attempt = 1, attempts do
		check()
		local ok, result = pcall(fn)
		if ok then
			return result
		end
		problem = tostring(result)
		if attempt < attempts then
			sleep(delay * 2 ^ (attempt - 1))
		end
	end
	error(problem, 0)
end
return table.freeze(R)
