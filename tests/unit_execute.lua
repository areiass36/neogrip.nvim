-- Guards that fire before any connection is needed, so they test without a DB.
local support = require("tests.support")
local check = support.check
local execute = require("neogrip.execute")

support.describe("execute: a statement that is only comments is not sent")

local function run_buffer(lines)
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.bo[bufnr].filetype = "sql"
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.api.nvim_set_current_buf(bufnr)
	vim.api.nvim_win_set_cursor(0, { 1, 0 })

	local message = nil
	local original = vim.notify
	vim.notify = function(text)
		message = text
	end
	execute.run({ bufnr = bufnr })
	vim.wait(500, function()
		return message ~= nil
	end, 20)
	vim.notify = original
	return message
end

check(
	"a line comment alone says there is no statement",
	run_buffer({ "-- just a note" }),
	"[neogrip] no statement under the cursor"
)
check(
	"a block comment alone too",
	run_buffer({ "/* a note", "spanning lines */" }),
	"[neogrip] no statement under the cursor"
)
check("a blank buffer too", run_buffer({ "", "   " }), "[neogrip] no statement under the cursor")
check(
	"a comment followed by whitespace, no trailing newline",
	run_buffer({ "-- trailing", "  " }),
	"[neogrip] no statement under the cursor"
)

support.describe("execute: timeout_ms = 0 runs without arming the watchdog")

-- With a zero timeout the runner must not schedule the stopped-process
-- watchdog; otherwise 0 would still kill the query at ~10s. A mock sidecar
-- that never answers lets us prove nothing fires.
local runner = require("neogrip.runner")
local config = require("neogrip.config")
local sidecar = require("neogrip.sidecar")

config.setup({ timeout_ms = 0 })
local saved_connected_to = sidecar.is_connected_to
local saved_is_connected = sidecar.is_connected
local saved_request = sidecar.request
sidecar.is_connected_to = function()
	return true
end
sidecar.is_connected = function()
	return true
end
sidecar.request = function() end -- never calls back: the query "hangs"

local fired = nil
runner.run({
	connection = { id = "__timeout_probe__", driver = "duckdb" },
	sql = "select 1",
	mode = "query",
	limit = 1,
}, function(_, err)
	fired = err or {}
end)
-- The old watchdog would fire at ~10s (0 + 10000). Wait past that.
vim.wait(11000, function()
	return fired ~= nil
end, 100)
support.check("a zero timeout never trips the watchdog", fired, nil)

sidecar.is_connected_to = saved_connected_to
sidecar.is_connected = saved_is_connected
sidecar.request = saved_request
config.setup({})
