-- One tab per query and its clock. Transient state is asserted by holding the
-- runner's callback: the only way to stand inside a running query.
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
-- No GridState on purpose: "no rows" before the answer would read as an empty result (ADR-0044).
check("with no result state", grid.state(first), nil)
local first_body = vim.api.nvim_buf_get_lines(first, 0, -1, false)
check("the body is one status line", #first_body, 1)
check("naming the connection", first_body[1]:find("probe [postgres]", 1, true) ~= nil, true)
local lone_strip = grid.strip_text(first)
check("the strip is there from the first query", lone_strip ~= "", true)
check("naming its statement", lone_strip:find("select 1", 1, true) ~= nil, true)
check("in the native selected face", lone_strip:find("NGripGridTabActive") ~= nil, true)
check("and ending in the tabline's fill", lone_strip:find("NGripGridTabFill") ~= nil, true)

support.describe("tabs: a word while it waits, a number once it runs")

local bar = grid.status_text(first)
check("the status names the connection", bar:find("probe [postgres]", 1, true) ~= nil, true)
-- Before the server says it has begun, a number would count the queue or the connect,
-- not the statement (ADR-0042).
check("and shows no number at all", bar:find("%d+ ms") == nil, true)
check("but says where it got to", bar:find("sent", 1, true) ~= nil, true)

grid.progress(first, { phase = "executing" })
check("the clock is running", grid._ticking(), true)
check("and the status is a number", grid.status_text(first):find("%d+ ms") ~= nil, true)
check(
	"painted into the body",
	vim.api.nvim_buf_get_lines(first, 0, -1, false)[1]:find("running", 1, true) ~= nil,
	true
)

support.describe("tabs: the clock belongs to one tab")

run_query("select 2")
local second = grid.current_buf()
check("a second query opens a second tab", #grid.tabs(), 2)
check("which is a different buffer", second ~= first, true)
check("the new tab shows a word", grid.status_text(second):find("%d+ ms") == nil, true)
check("while the first still shows its number", grid.status_text(first):find("%d+ ms") ~= nil, true)

support.describe("tabs: the answer fills the tab the query opened")

answer(2, { columns = { "n" }, rows = { { 2 } }, done = true, elapsed_ms = 3 })
check("the tab stopped waiting", grid.is_pending(second), false)
check("and holds the rows", #grid.state(second).rows, 1)
check("without opening another tab", #grid.tabs(), 2)
check("the status counts them", grid.status_text(second):find("1 rows", 1, true) ~= nil, true)

answer(1, { columns = { "n" }, rows = { { 1 } }, done = true, elapsed_ms = 1 })
check("and once every query answered, the clock stops", grid._ticking(), false)

support.describe("tabs: the strip names every tab by its statement")

-- The buffers stay unlisted: the strip names them, so :ls gains nothing (ADR-0045).
check("a tab is not a listed buffer", vim.bo[first].buflisted, false)
local strip = grid.strip_text(second)
check("the strip names both statements", strip:find("select 1", 1, true) ~= nil, true)
check("each with its own", strip:find("select 2", 1, true) ~= nil, true)
check("marking the one on screen", strip:find("NGripGridTabActive") ~= nil, true)
local first_name = vim.api.nvim_buf_get_name(first)
local second_name = vim.api.nvim_buf_get_name(second)
check("the buffer name carries the same label", first_name:find("select 1", 1, true) ~= nil, true)
check("and the names are distinct", first_name ~= second_name, true)

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
check("and the status says it failed", grid.status_text(failed):find("failed", 1, true) ~= nil, true)

run_query("select slow")
local stopped = grid.current_buf()
held[#held](nil, { message = "cancelled", cancelled = true })
check("a cancelled query keeps its tab too", grid.current_buf(), stopped)
local stopped_bar = grid.status_text(stopped)
check("and is not called a failure", stopped_bar:find("cancelled", 1, true) ~= nil, true)
check("the strip marks the failure", grid.strip_text(stopped):find("NGripGridTabError") ~= nil, true)

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
check("the batch's own time is in the footer", grid.status_text(scrolled):find("12 ms", 1, true) ~= nil, true)
check("and no clock is running", grid._ticking(), false)

-- A refill re-executes the statement (ADR-0042) with rows already in the tab,
-- which is the path a pending-only clock would have missed.
grid.state(scrolled).auto.loading = true
grid.progress(scrolled, { phase = "executing" })
check("the refill starts the clock", grid._ticking(), true)
local refilling = grid.status_text(scrolled)
check("the rows are still counted", refilling:find("1 rows", 1, true) ~= nil, true)
check("and it says a batch is on its way", refilling:find("loading", 1, true) ~= nil, true)
check("the time is no longer the last batch's", refilling:find("12 ms", 1, true), nil)
-- The clock is the footer line itself, rewritten in place (ADR-0045).
local refill_lines = vim.api.nvim_buf_get_lines(scrolled, 0, -1, false)
check(
	"and the footer line in the buffer was rewritten",
	refill_lines[#refill_lines]:find("loading", 1, true) ~= nil,
	true
)

grid.state(scrolled).auto.loading = false
grid.add_page(scrolled, { rows = { { 2 } }, done = true, elapsed_ms = 4 })
check("the batch landing stops the clock", grid._ticking(), false)
local landed = grid.status_text(scrolled)
-- Overwriting the statement's time with the batch's turned "1420 ms" into "3 ms"
-- as soon as the reader scrolled.
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
local sorting_body = vim.api.nvim_buf_get_lines(sorted, 0, -1, false)
check("the rows stay on screen while it re-runs", sorting_body[3]:find("1", 1, true) ~= nil, true)
answer(2, {
	columns = { "a" },
	rows = { { 1 } },
	done = true,
	hash = "ddddeeeeffff",
	connection = connection,
})
check("sorting opened no second tab", #grid.tabs(), 1)
check("into the same buffer", grid.current_buf(), sorted)
-- Sorting is the one remaining replace, one of ADR-0041's four reclamation paths.
check("and the replaced cursor was handed back", vim.tbl_contains(released, "aaaabbbbcccc"), true)

support.describe("tabs: :bd on a tab the reader gave up on")

close_all()
run_query("select 1")
local abandoned = grid.current_buf()
check("the tab is there", #grid.tabs(), 1)
vim.api.nvim_buf_delete(abandoned, { force = true })
check("deleting its buffer forgets the tab", #grid.tabs(), 0)
check("and nothing is active", grid.active_tab(), 0)
check("its request was cancelled too", #cancelled, 1)

close_all()
check("no tabs left", #grid.tabs(), 0)
check("and no clock", grid._ticking(), false)

resolve.for_buf = saved.for_buf
runner.run = saved.run
runner.release = saved.release
runner.cancel = saved.cancel
vim.notify = saved.notify
