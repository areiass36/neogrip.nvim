-- One tab per query, opened before the answer arrives (ADR-0044), and the clock
-- that runs in the winbar while it does (ADR-0042, ADR-0043).
--
-- Transient state is asserted by holding the runner's callback rather than by
-- advancing a clock, which is the only way a suite can stand inside the moment
-- a query is still running.
local support = require("tests.support")
local check = support.check
local execute = require("neogrip.execute")
local grid = require("neogrip.grid")
local runner = require("neogrip.runner")
local resolve = require("neogrip.resolve")

local connection = { id = "__tabs_probe__", name = "probe", driver = "postgres", readonly = false }

local saved = {
	for_buf = resolve.for_buf,
	run = runner.run,
	release = runner.release,
	cancel = runner.cancel,
	notify = vim.notify,
}

local held, requests, released, cancelled = {}, {}, {}, {}

vim.notify = function() end
resolve.for_buf = function()
	return connection, nil
end
runner.run = function(request, callback)
	requests[#requests + 1] = request
	held[#held + 1] = callback
	return { id = #held, hash = request.hash, done = false }
end
runner.release = function(_, hash)
	released[#released + 1] = hash
end
runner.cancel = function(handle)
	cancelled[#cancelled + 1] = handle
	return true
end

--- Run one statement and leave it unanswered.
local function run_query(text)
	local qbuf = vim.api.nvim_create_buf(false, true)
	vim.bo[qbuf].filetype = "sql"
	vim.api.nvim_buf_set_lines(qbuf, 0, -1, false, { text })
	execute.run({ bufnr = qbuf, statement = { text = text }, focus = false })
	return qbuf
end

local function close_all()
	for _, bufnr in ipairs(grid.tabs()) do
		grid.close(bufnr)
	end
	held, requests, released, cancelled = {}, {}, {}, {}
end

local function answer(index, result)
	held[index](result, nil)
end

support.describe("tabs: the window is there before the answer")

close_all()
run_query("select 1")
local first = grid.current_buf()
check("a tab is open", first ~= nil, true)
check("and it is the only one", #grid.tabs(), 1)
check("the request is out", #requests, 1)
check("it is waiting for an answer", grid.is_pending(first), true)
-- No GridState on purpose: a rendered header with no columns and "no rows"
-- reads as "the query returned nothing", which is a worse lie than a blank
-- window (ADR-0044).
check("with no result state", grid.state(first), nil)
check("and nothing in the body", vim.api.nvim_buf_get_lines(first, 0, -1, false), { "" })

support.describe("tabs: a word while it waits, a number once it runs")

local bar = grid.winbar_text(first)
check("the winbar names the connection", bar:find("probe [postgres]", 1, true) ~= nil, true)
-- Until the server says it has begun, any number would be counting the queue,
-- the connect or a first-use compile of gripd - not the statement (ADR-0043).
check("and shows no number at all", bar:find("%d+ ms") == nil, true)
check("but says where it got to", bar:find("sent", 1, true) ~= nil, true)

grid.progress(first, { phase = "executing" })
check("the clock is running", grid._ticking(), true)
check("and the winbar is a number", grid.winbar_text(first):find("%d+ ms") ~= nil, true)

support.describe("tabs: the clock belongs to one tab")

run_query("select 2")
local second = grid.current_buf()
check("a second query opens a second tab", #grid.tabs(), 2)
check("which is a different buffer", second ~= first, true)
check("the new tab shows a word", grid.winbar_text(second):find("%d+ ms") == nil, true)
check("while the first still shows its number", grid.winbar_text(first):find("%d+ ms") ~= nil, true)

support.describe("tabs: the answer fills the tab the query opened")

answer(2, { columns = { "n" }, rows = { { 2 } }, done = true, elapsed_ms = 3 })
check("the tab stopped waiting", grid.is_pending(second), false)
check("and holds the rows", #grid.state(second).rows, 1)
check("without opening another tab", #grid.tabs(), 2)
check("the winbar counts them", grid.winbar_text(second):find("1 rows", 1, true) ~= nil, true)

answer(1, { columns = { "n" }, rows = { { 1 } }, done = true, elapsed_ms = 1 })
check("and once every query answered, the clock stops", grid._ticking(), false)

support.describe("tabs: the strip names every tab")

local strip = grid.tab_strip(second)
check("it names both tabs", strip:find("1", 1, true) ~= nil and strip:find("2", 1, true) ~= nil, true)
check("marking the one on screen", strip:find("NGripGridTabActive") ~= nil, true)

support.describe("tabs: moving between them")

grid.goto_tab(2)
check("next wraps to the first", grid.step_tab(1), first)
check("and back to the second", grid.step_tab(1), second)
check("previous goes the other way", grid.step_tab(-1), first)
check("a tab by number", grid.goto_tab(2), second)
check("one that does not exist is a no-op", grid.goto_tab(99), nil)
check("and the active tab did not move", grid.current_buf(), second)

support.describe("tabs: closing one keeps the window and the others")

run_query("select 3")
local third = grid.current_buf()
answer(3, { columns = { "n" }, rows = { { 3 } }, done = true })
check("three tabs", #grid.tabs(), 3)
local winid = nil
for _, w in ipairs(vim.api.nvim_list_wins()) do
	if vim.api.nvim_win_get_buf(w) == third then
		winid = w
	end
end
check("which the window is showing", winid ~= nil, true)

grid.goto_tab(2)
grid.close(second)
check("the middle tab is gone", #grid.tabs(), 2)
check("the window survived it", vim.api.nvim_win_is_valid(winid), true)
check("showing a neighbour", vim.api.nvim_win_get_buf(winid) ~= second, true)

support.describe("tabs: a failed query keeps its tab and says why")

close_all()
run_query("select broken")
local failed = grid.current_buf()
held[#held](nil, { message = 'syntax error at or near "broken"' })
check("the tab is still there", grid.current_buf(), failed)
check("it never became a result", grid.state(failed), nil)
local failed_body = vim.api.nvim_buf_get_lines(failed, 0, -1, false)
check("the body says what happened", failed_body[1]:find("syntax error", 1, true) ~= nil, true)
check("and the winbar says it failed", grid.winbar_text(failed):find("failed", 1, true) ~= nil, true)

run_query("select slow")
local stopped = grid.current_buf()
held[#held](nil, { message = "cancelled", cancelled = true })
check("a cancelled query keeps its tab too", grid.current_buf(), stopped)
local stopped_bar = grid.winbar_text(stopped)
check("and is not called a failure", stopped_bar:find("cancelled", 1, true) ~= nil, true)

support.describe("tabs: closing a pending tab cancels its request")

close_all()
run_query("select 9")
local pending_tab = grid.current_buf()
grid.close(pending_tab)
check("the request behind it was cancelled", #cancelled, 1)
check("and the tab is gone", vim.tbl_contains(grid.tabs(), pending_tab), false)

support.describe("tabs: a refill runs the clock over the rows already there")

close_all()
run_query("select * from big")
local scrolled = grid.current_buf()
answer(1, { columns = { "n" }, rows = { { 1 } }, done = false, elapsed_ms = 12, hash = "cafecafecafe" })
check("the batch's own time is in the footer", grid.winbar_text(scrolled):find("12 ms", 1, true) ~= nil, true)
check("and no clock is running", grid._ticking(), false)

-- Draining the window makes gripd re-execute the statement, which announces
-- itself like any other execution (ADR-0042). It is the slowest wait there is,
-- so it is the one that most needs a clock - and the tab holds rows already,
-- so this is the path a pending-only clock would have missed.
grid.state(scrolled).auto.loading = true
grid.progress(scrolled, { phase = "executing" })
check("the refill starts the clock", grid._ticking(), true)
local refilling = grid.winbar_text(scrolled)
check("the rows are still counted", refilling:find("1 rows", 1, true) ~= nil, true)
check("and it says a batch is on its way", refilling:find("loading", 1, true) ~= nil, true)
check("the time is no longer the last batch's", refilling:find("12 ms", 1, true), nil)

grid.state(scrolled).auto.loading = false
grid.add_page(scrolled, { rows = { { 2 } }, done = true, elapsed_ms = 4 })
check("the batch landing stops the clock", grid._ticking(), false)
local landed = grid.winbar_text(scrolled)
-- The statement's own time survives the batch. Overwriting it turned "this
-- statement took 1420 ms" into "3 ms" as soon as the reader scrolled, and the
-- statement's cost is what the number is for.
check("the query's own time is still the one shown", landed:find("12 ms", 1, true) ~= nil, true)
check("not the batch's", landed:find("4 ms", 1, true), nil)
check("but the batch's is kept", grid.state(scrolled).last_batch_ms, 4)

support.describe("tabs: sorting reuses the tab it is sorting")

close_all()
run_query("select * from t")
local sorted = grid.current_buf()
answer(1, {
	columns = { "a" },
	rows = { { 1 } },
	done = true,
	hash = "aaaabbbbcccc",
	connection = connection,
})
check("one tab", #grid.tabs(), 1)
execute.sort(grid.state(sorted), "a", false)
answer(2, {
	columns = { "a" },
	rows = { { 1 } },
	done = true,
	hash = "ddddeeeeffff",
	connection = connection,
})
check("sorting opened no second tab", #grid.tabs(), 1)
check("into the same buffer", grid.current_buf(), sorted)
-- ADR-0041 names the client's release of a result it is replacing as one of
-- only four reclamation paths, and sorting is the one case left that replaces.
check("and the replaced cursor was handed back", vim.tbl_contains(released, "aaaabbbbcccc"), true)

close_all()
check("no tabs left", #grid.tabs(), 0)
check("and no clock", grid._ticking(), false)

resolve.for_buf = saved.for_buf
runner.run = saved.run
runner.release = saved.release
runner.cancel = saved.cancel
vim.notify = saved.notify
