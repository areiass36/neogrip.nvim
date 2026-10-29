-- The test runner: two explicit lists, unit suites that touch no network and
-- live suites that probe reachability and skip when the server is absent.
-- Invoke as: nvim --headless -u tests/minimal.lua -l tests/run.lua [unit]
local support = require("tests.support")

local UNIT = {}

local LIVE = {}

local unit_only = false
for _, argument in ipairs(vim.v.argv) do
	if argument == "unit" then
		unit_only = true
	end
end

local suites = vim.deepcopy(UNIT)
if not unit_only then
	vim.list_extend(suites, LIVE)
end

for _, suite in ipairs(suites) do
	local ok, err = pcall(require, "tests." .. suite)
	if not ok then
		support.fail(suite .. " loads", err)
	end
end

print("")
print(string.format("%d checks, %d failures", support.checks, support.failures))
os.exit(support.failures == 0 and 0 or 1)
