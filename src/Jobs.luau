--!strict
-- Cooperative cancellation/progress for long authoring tasks; no automatic workers.
local Jobs = {}
export type Context = {
	cancelled: () -> boolean,
	progress: (value: number) -> (),
	checkpoint: (value: number?) -> (),
}
export type Job = {
	status: string,
	progress: number,
	result: any, -- whatever the operation returned
	error: string?,
	cancelRequested: boolean,
	cancel: (self: Job) -> (),
}
function Jobs.start(operation: (Context) -> any): Job
	local job: Job =
		{ status = "Running", progress = 0, result = nil, error = nil, cancelRequested = false } :: any
	function job.cancel(self: Job)
		if self.status == "Running" then
			self.cancelRequested = true
		end
	end
	local context: Context = {} :: any
	function context.cancelled()
		return job.cancelRequested
	end
	function context.progress(value: number)
		job.progress = math.clamp(value, 0, 1)
	end
	function context.checkpoint(value: number?)
		if value then
			context.progress(value)
		end
		if job.cancelRequested then
			error("Editable3D job cancelled", 0)
		end
		task.wait()
	end
	task.spawn(function()
		local ok, result = xpcall(function()
			return operation(context)
		end, debug.traceback)
		if job.cancelRequested then
			job.status = "Cancelled"
		elseif ok then
			job.result = result
			job.progress = 1
			job.status = "Complete"
		else
			job.error = tostring(result)
			job.status = "Failed"
		end
	end)
	return job
end
function Jobs.await(job: Job, timeout: number?): (any, string?)
	local start = os.clock()
	while job.status == "Running" do
		if timeout and os.clock() - start > timeout then
			return nil, "Timed out"
		end
		task.wait()
	end
	if job.status == "Complete" then
		return job.result
	end
	return nil, job.error or job.status
end
return Jobs
