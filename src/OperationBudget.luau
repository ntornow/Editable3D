--!strict
-- Shared cooperative limits. Counts bound total allocations, not live GC memory.
export type Progress = { operation: string, work: number, allocatedBytes: number, elapsedSeconds: number }
export type Options = {
	maxWork: number?,
	maxBytes: number?,
	maxPixels: number?,
	maxSeconds: number?,
	checkpointEvery: number?,
	cancelled: (() -> boolean)?,
	checkpoint: ((Progress) -> ())?,
	onComplete: ((Progress) -> ())?,
	_budget: Budget?, -- reserved for nested library operations
}
export type Budget = {
	operation: string,
	work: number,
	allocatedBytes: number,
	started: number,
	nextCheckpoint: number,
	maxWork: number,
	maxBytes: number,
	maxPixels: number,
	maxSeconds: number,
	checkpointEvery: number,
	cancelled: (() -> boolean)?,
	checkpoint: ((Progress) -> ())?,
	onComplete: ((Progress) -> ())?,
	step: (Budget, number?) -> (),
	reserve: (Budget, number) -> (),
	image: (Budget, number, number, number?) -> number,
	check: (Budget) -> (),
	report: (Budget) -> Progress,
	finish: (Budget) -> Progress,
}
local B = {}
local live: { [Budget]: boolean } = {}
setmetatable(live, { __mode = "k" })
local function positive(value: number?, default: number, integer: boolean): number
	local n = if value == nil then default else value
	assert(n == n and n > 0 and n < math.huge and (not integer or n % 1 == 0), "Invalid operation limit")
	return n
end
function B.report(self: Budget): Progress
	return {
		operation = self.operation,
		work = self.work,
		allocatedBytes = self.allocatedBytes,
		elapsedSeconds = os.clock() - self.started,
	}
end
function B.check(self: Budget)
	assert(self.work <= self.maxWork, "Operation work limit exceeded")
	assert(os.clock() - self.started <= self.maxSeconds, "Operation time limit exceeded")
	local cancelled = self.cancelled
	assert(not cancelled or not cancelled(), "Operation cancelled")
	local checkpoint = self.checkpoint
	if checkpoint then
		checkpoint(B.report(self))
	end
	assert(not cancelled or not cancelled(), "Operation cancelled")
	assert(os.clock() - self.started <= self.maxSeconds, "Operation time limit exceeded")
end
function B.step(self: Budget, count: number?)
	local n = count or 1
	assert(n >= 0 and n % 1 == 0 and n < math.huge, "Invalid work charge")
	self.work += n
	assert(self.work <= self.maxWork, "Operation work limit exceeded")
	if self.work >= self.nextCheckpoint then
		self.nextCheckpoint = self.work + self.checkpointEvery
		B.check(self)
	end
end
function B.reserve(self: Budget, bytes: number)
	assert(bytes >= 0 and bytes % 1 == 0 and bytes < math.huge, "Invalid allocation")
	assert(bytes <= self.maxBytes - self.allocatedBytes, "Operation allocation limit exceeded")
	B.check(self)
	self.allocatedBytes += bytes
end
function B.image(self: Budget, width: number, height: number, stride: number?): number
	assert(width > 0 and height > 0 and width % 1 == 0 and height % 1 == 0, "Invalid image dimensions")
	local pixels = width * height
	assert(pixels <= self.maxPixels, "Operation pixel limit exceeded")
	local bytes = pixels * (stride or 16)
	B.reserve(self, bytes)
	return bytes
end
function B.finish(self: Budget): Progress
	B.check(self)
	local result = B.report(self)
	local callback = self.onComplete
	if callback then
		callback(result)
	end
	return result
end
function B.new(options: Options?, operation: string): Budget
	local o: Options = options or {}
	local self: Budget = {
		operation = operation,
		work = 0,
		allocatedBytes = 0,
		started = os.clock(),
		nextCheckpoint = 0,
		maxWork = positive(o.maxWork, 100000000, true),
		maxBytes = positive(o.maxBytes, 268435456, true),
		maxPixels = positive(o.maxPixels, 16777216, true),
		maxSeconds = positive(o.maxSeconds, 60, false),
		checkpointEvery = positive(o.checkpointEvery, 4096, true),
		cancelled = o.cancelled,
		checkpoint = o.checkpoint,
		onComplete = o.onComplete,
		step = B.step,
		reserve = B.reserve,
		image = B.image,
		check = B.check,
		report = B.report,
		finish = B.finish,
	}
	assert(o.cancelled == nil or type(o.cancelled) == "function", "Invalid cancellation callback")
	assert(o.checkpoint == nil or type(o.checkpoint) == "function", "Invalid checkpoint callback")
	assert(o.onComplete == nil or type(o.onComplete) == "function", "Invalid completion callback")
	B.check(self)
	live[self] = true
	return self
end
function B.acquire(options: Options?, operation: string): (Budget, boolean)
	local existing = options and options._budget
	if existing then
		assert(live[existing], "Invalid shared budget")
		return existing, false
	end
	return B.new(options, operation), true
end
function B.options(self: Budget): Options
	assert(live[self], "Invalid shared budget")
	return { _budget = self }
end
return table.freeze(B)
