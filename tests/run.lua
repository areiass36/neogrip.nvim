-- The test runner: two explicit lists, unit suites that touch no network and
-- live suites that probe reachability and skip when the server is absent.
-- Invoke as: nvim --headless -u tests/minimal.lua -l tests/run.lua [unit]
local support = require("tests.support")

local UNIT = {
	"unit_rpc",
	"unit_bootstrap",
	"unit_sql",
	"unit_codecs",
	"unit_dsn",
	"unit_errors",
	"unit_connections",
	"unit_grid",
	"unit_scratch",
	"unit_execute",
	"unit_identifier",
	"unit_dialect",
	"unit_store",
	"unit_detail",
	"unit_preview",
	"unit_explorer",
	"unit_completion",
	"unit_lsp",
}

local LIVE = {
	"live_protocol",
	"live_jdbc",
	"live_flow",
	"live_requery",
	"live_tx",
	"live_safety",
	"live_schema",
	"live_introspect",
	"live_explorer",
	"live_diagnostics",
}

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
