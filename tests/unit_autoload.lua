-- The grid asking for the next batch on its own. Driven through
-- grid.maybe_load_more(bufnr, line) so the whole suite runs with no window and no server.
local support = require("tests.support")
local check, note = support.check, support.note
local config = require("neogrip.config")
local grid = require("neogrip.grid")
local runner = require("neogrip.gripd.runner")

local connection = { id = "auto", name = "auto", driver = "duckdb" }

local requests = {}
local answer = function()
	return { rows = { { 0 } }, done = false }
end
local saved_run = runner.run
runner.run = function(request, callback)
	requests[#requests + 1] = request
	callback(answer(request))
	return { done = true }
end

local notices = {}
local saved_notify = vim.notify
vim.notify = function(text)
	notices[#notices + 1] = text
end

--- A grid holding `rows` rows of an open result.
local function fresh(opts)
	opts = opts or {}
	local existing = grid.current_buf()
	if existing then
		grid.close(existing)
	end
	local rows = {}
	for index = 1, (opts.rows or 200) do
		rows[index] = { index }
	end
	local done = false
	if opts.done ~= nil then
		done = opts.done
	end
	-- Spelled out: `opts.no_hash and nil or "..."` always yields the fallback in Lua.
	local hash = "aaaabbbbcccc"
	if opts.no_hash then
		hash = nil
	end
	grid.show({
		columns = { "n" },
		rows = rows,
		done = done,
		hash = hash,
		limit = opts.limit or 200,
		connection = connection,
	}, { focus = false })
	requests, notices = {}, {}
	return grid.current_buf()
end

--- The line the cursor would be on for a given data row.
local function line_of(row)
	return row + 2
end

--- Let the debounce run out, so "nothing was asked" is a fact and not a race.
local function settle()
	vim.wait(300, function()
		return false
	end, 20)
end

local function trigger(bufnr, line)
	local before = #requests
	grid.maybe_load_more(bufnr, line)
	support.wait(function()
		return #requests > before
	end, 1000)
end

support.describe("autoload: when the grid asks for more on its own")

config.setup({ auto_load_rows = 0 })
local bufnr = fresh({ rows = 200 })
grid.maybe_load_more(bufnr, line_of(200))
settle()
check("a threshold of zero turns it off", #requests, 0)

config.setup({ auto_load_rows = 10 })
bufnr = fresh({ rows = 200 })
grid.maybe_load_more(bufnr, line_of(1))
settle()
check("a cursor far from the end asks for nothing", #requests, 0)

trigger(bufnr, line_of(195))
check("a cursor inside the threshold asks once", #requests, 1)
check("as a continuation", requests[1].mode, "next")
check("of the result it is reading", requests[1].hash, "aaaabbbbcccc")
check("a batch at a time", requests[1].limit, 200)

-- CursorMoved fires once per `j`, so this is the held-key case.
bufnr = fresh({ rows = 200 })
for row = 191, 200 do
	grid.maybe_load_more(bufnr, line_of(row))
end
support.wait(function()
	return #requests > 0
end, 1000)
settle()
check("ten motions in a row still ask once", #requests, 1)

-- The blank line and the footer sit past the last row, which sync_from_cursor ignores.
bufnr = fresh({ rows = 200 })
trigger(bufnr, 200 + 3)
check("the blank line past the rows still asks", #requests, 1)

bufnr = fresh({ rows = 200 })
trigger(bufnr, 200 + 4)
check("and so does the footer", #requests, 1)

support.describe("autoload: and when it must not")

bufnr = fresh({ rows = 200, done = true })
grid.maybe_load_more(bufnr, line_of(200))
settle()
check("a finished result is not asked", #requests, 0)
-- The automatic path is silent or it would speak on every motion at the bottom.
check("and says nothing about it", #notices, 0)

bufnr = fresh({ rows = 200, no_hash = true })
grid.maybe_load_more(bufnr, line_of(200))
settle()
check("an unnamed result cannot be continued", #requests, 0)

-- Without the latch, a batch claiming more but bringing nothing would be re-asked forever.
bufnr = fresh({ rows = 200 })
answer = function()
	return { rows = {}, done = false }
end
trigger(bufnr, line_of(200))
check("an empty batch is asked for once", #requests, 1)
check("and latches the asking off", grid.state(bufnr).auto.exhausted, true)
grid.maybe_load_more(bufnr, line_of(200))
settle()
check("so a later motion asks for nothing", #requests, 1)
answer = function()
	return { rows = { { 0 } }, done = false }
end

config.setup({ auto_load_rows = 10, auto_load_max_rows = 10 })
bufnr = fresh({ rows = 200 })
grid.maybe_load_more(bufnr, line_of(200))
settle()
check("past the cap it stops asking", #requests, 0)
local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
check("and the footer says it is paused", lines[#lines]:find("paused", 1, true) ~= nil, true)
check("while still promising more", lines[#lines]:find("more", 1, true) ~= nil, true)

support.describe("autoload: a result the server no longer has")

-- An expired continuation comes back -32600 and nothing is re-run (ADR-0040).
config.setup({ auto_load_rows = 10 })
bufnr = fresh({ rows = 200 })
answer = function()
	return nil, { rpc_code = -32600, message = "no result is open under aaaabbbbcccc" }
end
trigger(bufnr, line_of(200))
check("the expired result is asked once", #requests, 1)
support.wait(function()
	return #notices > 0
end, 1000)
check("and reported once", #notices, 1)
check("saying what to do about it", notices[1]:find("run the statement again", 1, true) ~= nil, true)
local state = grid.state(bufnr)
check("the result is marked expired", state.expired, true)
check("the asking is latched off", state.auto.exhausted, true)
check("and the rows loaded are untouched", #state.rows, 200)
lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
check("the footer says so", lines[#lines]:find("expired", 1, true) ~= nil, true)
check("and stops promising more", lines[#lines]:find("(more)", 1, true), nil)

grid.maybe_load_more(bufnr, line_of(200))
grid.maybe_load_more(bufnr, line_of(199))
settle()
check("a later motion does not ask again", #requests, 1)
check("nor repeat itself", #notices, 1)

local execute = require("neogrip.execute")
notices = {}
execute.page(grid.state(bufnr), 1)
support.wait(function()
	return #notices > 0
end, 1000)
check("asking by hand says it again", #notices, 1)
check("and names the reason", notices[1]:find("expired", 1, true) ~= nil, true)
answer = function()
	return { rows = { { 0 } }, done = false }
end

support.describe("autoload: the threshold is held below the batch")

-- Unclamped, a threshold as large as the batch would walk the whole table from row one.
config.setup({ auto_load_rows = 500 })
bufnr = fresh({ rows = 200, limit = 200 })
trigger(bufnr, line_of(1))
check("the first row is within one batch of the end", #requests, 1)
grid.maybe_load_more(bufnr, line_of(1))
settle()
check("but the next batch puts it out of reach again", #requests, 1)

support.describe("autoload: the footer says a batch is on its way")

-- The synchronous fake above answers before anything can look, so this one
-- holds the callback until the footer has been read.
local held_callback = nil
local saved_sync_run = runner.run
runner.run = function(request, callback)
	requests[#requests + 1] = request
	held_callback = callback
	return { done = false }
end
config.setup({ auto_load_rows = 10 })
bufnr = fresh({ rows = 200 })
trigger(bufnr, line_of(200))
check("the request is out", #requests, 1)
check("and the state says so", grid.state(bufnr).auto.loading, true)
lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
check("the footer says a batch is on its way", lines[#lines]:find("loading", 1, true) ~= nil, true)
check("while still promising more", lines[#lines]:find("more", 1, true) ~= nil, true)

held_callback({ rows = { { 201 } }, done = true, elapsed_ms = 1 })
lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
check("and stops saying it once the batch lands", lines[#lines]:find("loading", 1, true), nil)
check("the batch was appended", #grid.state(bufnr).rows, 201)
check("and the loading flag is down", grid.state(bufnr).auto.loading, false)
runner.run = saved_sync_run

support.describe("autoload: closing the grid hands the result back")

-- Nothing evicts an open result any more (ADR-0041), so the client has to.
local released = {}
local saved_release = runner.release
runner.release = function(conn, hash)
	released[#released + 1] = { id = conn.id, hash = hash }
end
bufnr = fresh({ rows = 10 })
released = {}
grid.close(bufnr)
check("the open result is released by name", released[1] and released[1].hash, "aaaabbbbcccc")
check("on the connection that holds it", released[1] and released[1].id, "auto")
runner.release = saved_release

config.setup({})
local last = grid.current_buf()
if last then
	grid.close(last)
end
runner.run = saved_run
vim.notify = saved_notify
note("the real runner and notifier are back")
