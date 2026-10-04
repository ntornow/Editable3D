--!strict
-- Preparation may yield. Live actions must be synchronous and supply rollback.
export type Action = { name: string, apply: () -> (), rollback: () -> () }
export type Plan = { actions: { Action }, validate: (() -> ())? }
export type Context = { defer: (() -> ()) -> (), check: () -> (), phase: (string) -> () }
export type Options = { check: (() -> ())? }
export type Report = {
	success: boolean,
	committed: boolean,
	rolledBack: boolean,
	stage: string,
	error: string?,
	rollbackErrors: { string },
	cleanupErrors: { string },
}
local T = {}
function T.run(prepare: (Context) -> Plan, options: Options?): Report
	local o: Options = options or {}
	local cleanups: { () -> () } = {}
	local applied: { Action } = {}
	local report: Report = {
		success = false,
		committed = false,
		rolledBack = true,
		stage = "prepare",
		rollbackErrors = {},
		cleanupErrors = {},
	}
	local context: Context = {
		defer = function(fn: () -> ())
			table.insert(cleanups, fn)
		end,
		check = function()
			if o.check then
				o.check()
			end
		end,
		phase = function(name: string)
			report.stage = name
		end,
	}
	local ok, err = pcall(function()
		context.check()
		local plan = prepare(context)
		context.check()
		if plan.validate then
			plan.validate()
		end
		report.stage = "commit"
		for _, action in plan.actions do
			table.insert(applied, action) -- Include an action which partially mutates then throws.
			action.apply()
		end
		report.committed = true
	end)
	if not ok then
		report.error = tostring(err)
		for i = #applied, 1, -1 do
			local restored, problem = pcall(function()
				applied[i].rollback()
				return true
			end)
			if not restored then
				table.insert(report.rollbackErrors, applied[i].name .. ": " .. tostring(problem))
			end
		end
		report.rolledBack = #report.rollbackErrors == 0
	else
		report.success = true
		report.rolledBack = false
		report.stage = "complete"
	end
	for i = #cleanups, 1, -1 do
		local cleaned, problem = pcall(function()
			cleanups[i]()
			return true
		end)
		if not cleaned then
			table.insert(report.cleanupErrors, tostring(problem))
		end
	end
	return report
end
return table.freeze(T)
