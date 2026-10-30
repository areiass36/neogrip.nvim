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

support.describe("execute: a visual selection of several statements runs them in sequence")

-- A selection can hold more than one statement; the driver takes one per call
-- (Trino rejects even two separated by ';'). The selection must therefore be
-- split and run in order, each statement carrying no terminator.
local resolve = require("neogrip.resolve")
local grid = require("neogrip.grid")

local saved_for_buf = resolve.for_buf
local saved_runner_run = runner.run
local saved_grid_show = grid.show

resolve.for_buf = function()
	return { id = "__seq_probe__", name = "probe", driver = "postgres", readonly = false }, nil
end

local sent = {}
runner.run = function(request, callback)
	sent[#sent + 1] = request.sql
	callback({ columns = {}, rows = {}, done = true }, nil)
	return { done = true }
end
grid.show = function() end

local seqbuf = vim.api.nvim_create_buf(false, true)
vim.bo[seqbuf].filetype = "sql"
vim.api.nvim_buf_set_lines(seqbuf, 0, -1, false, { "select 1;", "select 2;" })
vim.api.nvim_set_current_buf(seqbuf)
vim.api.nvim_buf_set_mark(seqbuf, "<", 1, 0, {})
vim.api.nvim_buf_set_mark(seqbuf, ">", 2, 8, {})

local prev_notify = vim.notify
vim.notify = function() end
execute.run({ bufnr = seqbuf, visual = true })
vim.wait(500, function()
	return #sent >= 2
end, 10)
vim.notify = prev_notify

support.check("both statements were sent", #sent, 2)
support.check("the first carried no terminator", sent[1], "select 1")
support.check("the second carried no terminator", sent[2], "select 2")

resolve.for_buf = saved_for_buf
runner.run = saved_runner_run
grid.show = saved_grid_show
