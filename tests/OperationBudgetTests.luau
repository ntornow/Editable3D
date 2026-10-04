local B = require(script.Parent.OperationBudget)
local Retry = require(script.Parent.PublishRetry)
local harness = require(script.Parent.TestHarness)
return function()
	local report, test, rejects = harness()
	test("Budget validates all limits", function()
		for _, key in { "maxWork", "maxBytes", "maxPixels", "maxSeconds", "checkpointEvery" } do
			for _, value in { 0, -1, math.huge, 0 / 0 } do
				rejects(function()
					B.new({ [key] = value }, "test")
				end, "Invalid operation limit")
			end
		end
		for _, key in { "cancelled", "checkpoint", "onComplete" } do
			rejects(function()
				B.new({ [key] = true }, "test")
			end, "callback")
		end
	end)
	test("Budget rejects work before checkpoint interval", function()
		local b = B.new({ maxWork = 2, checkpointEvery = 100 }, "test")
		b:step(2)
		rejects(function()
			b:step()
		end, "work limit")
	end)
	test("Allocation rejection does not consume capacity", function()
		local b = B.new({ maxBytes = 32 }, "test")
		b:reserve(16)
		rejects(function()
			b:reserve(17)
		end, "allocation limit")
		assert(b.allocatedBytes == 16)
		b:reserve(16)
		assert(b:report().allocatedBytes == 32)
	end)
	test("Image limits precede allocation", function()
		local b = B.new({ maxPixels = 4 }, "test")
		assert(b:image(2, 2, 4) == 16)
		rejects(function()
			b:image(3, 2)
		end, "pixel limit")
		for _, v in { 0, -1, 1.5, math.huge, 0 / 0 } do
			rejects(function()
				b:image(v, 2)
			end)
		end
	end)
	test("Invalid work and memory charges cannot lower usage", function()
		local b = B.new(nil, "test")
		for _, v in { -1, 0.1, math.huge, 0 / 0 } do
			rejects(function()
				b:step(v)
			end, "Invalid work")
			rejects(function()
				b:reserve(v)
			end, "Invalid allocation")
		end
		b:step(0)
		b:reserve(0)
		assert(b.work == 0 and b.allocatedBytes == 0)
	end)
	test("Pre-cancellation and cancellation inside checkpoint", function()
		rejects(function()
			B.new({
				cancelled = function()
					return true
				end,
			}, "test")
		end, "cancelled")
		local cancelled = false
		rejects(function()
			B.new({
				cancelled = function()
					return cancelled
				end,
				checkpoint = function()
					cancelled = true
				end,
			}, "test")
		end, "cancelled")
	end)
	test("Time limit checked before and after callback", function()
		local b = B.new({ maxSeconds = 1 }, "test")
		b.started = os.clock() - 2
		rejects(function()
			b:check()
		end, "time limit")
		local c = B.new({ maxSeconds = 1 }, "test")
		c.checkpoint = function()
			c.started = os.clock() - 2
		end
		rejects(function()
			c:check()
		end, "time limit")
	end)
	test("Nested budgets share usage and single owner", function()
		local b, owner = B.acquire(nil, "outer")
		assert(owner)
		local c, inner = B.acquire(B.options(b), "inner")
		assert(c == b and not inner)
		c:step(3)
		assert(b.work == 3)
		rejects(function()
			-- Deliberately invalid input: the runtime check must reject it.
			B.acquire({ _budget = {} } :: any, "bad")
		end, "Invalid shared budget")
		rejects(function()
			B.options({} :: any)
		end, "Invalid shared budget")
	end)
	test("Progress copies cannot alter budget; completion is observable", function()
		local completed
		local b = B.new({
			onComplete = function(p)
				completed = p
			end,
		}, "outer")
		b:step(3)
		local p = b:report()
		p.work = 999
		assert(b.work == 3)
		assert(b:finish() == completed and completed.operation == "outer" and completed.work == 3)
	end)
	test("Callback failure propagates", function()
		rejects(function()
			B.new({
				checkpoint = function()
					error("sentinel")
				end,
			}, "test")
		end, "sentinel")
		local b = B.new({
			onComplete = function()
				error("completion")
			end,
		}, "test")
		rejects(function()
			b:finish()
		end, "completion")
	end)
	test("Read retry uses bounded exponential backoff", function()
		local calls, checks, waits = 0, 0, {}
		local value = Retry.run(
			function()
				calls += 1
				if calls < 3 then
					error("transient")
				end
				return 42
			end,
			nil,
			function()
				checks += 1
			end,
			function(s)
				table.insert(waits, s)
			end
		)
		assert(value == 42 and calls == 3 and checks == 3 and waits[1] == 0.25 and waits[2] == 0.5)
	end)
	test("Retry exhaustion retains last error and cancellation stops retries", function()
		local calls = 0
		rejects(function()
			Retry.run(function()
				calls += 1
				error("failure" .. calls)
			end, { attempts = 2, retryDelay = 0 }, function() end, function() end)
		end, "failure2")
		assert(calls == 2)
		rejects(function()
			Retry.run(
				function()
					error("unused")
				end,
				nil,
				function()
					error("cancelled")
				end,
				function() end
			)
		end, "cancelled")
	end)
	test("Retry rejects invalid options", function()
		for _, v in { 0, 11, 1.5, math.huge, 0 / 0 } do
			rejects(function()
				Retry.run(function() end, { attempts = v }, function() end, function() end)
			end, "attempts")
		end
		for _, v in { -1, math.huge, 0 / 0 } do
			rejects(function()
				Retry.run(function() end, { retryDelay = v }, function() end, function() end)
			end, "delay")
		end
	end)
	return report
end
