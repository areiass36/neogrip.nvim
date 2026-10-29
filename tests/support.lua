-- The shared test vocabulary: flat suites call describe/check/fail and the
-- runner reads the counters. No framework, because the modules under test are
-- callback-based and the one primitive they need is sync().
local M = {}

M.checks = 0
M.failures = 0

function M.describe(name)
	print("")
	print("== " .. name)
end

function M.note(text)
	print("   " .. text)
end

function M.check(name, got, want)
	M.checks = M.checks + 1
	if vim.deep_equal(got, want) then
		print("ok   " .. name)
	else
		M.failures = M.failures + 1
		print("FAIL " .. name)
		print("     got:  " .. vim.inspect(got))
		print("     want: " .. vim.inspect(want))
	end
end

function M.fail(name, detail)
	M.checks = M.checks + 1
	M.failures = M.failures + 1
	print("FAIL " .. name)
	if detail then
		print("     " .. tostring(detail))
	end
end

-- Block until fn is true, the way a test has to when the module under test is
-- callback-based. Returns whether the condition was met in time.
function M.wait(fn, timeout)
	return vim.wait(timeout or 60000, fn, 50)
end

-- Turn a callback-based function into a synchronous call: starter receives a
-- done(...) to invoke, and sync returns whatever done was given, or nil plus
-- "timeout" when it never came.
function M.sync(starter, timeout)
	local results = nil
	starter(function(...)
		results = vim.F.pack_len(...)
	end)
	local arrived = M.wait(function()
		return results ~= nil
	end, timeout)
	if not arrived then
		return nil, "timeout"
	end
	return vim.F.unpack_len(results)
end

return M
