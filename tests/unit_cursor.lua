-- A result is a cursor the client names (ADR-0031): what goes on the wire to
-- open and to continue one, and the paging that never reaches a server because
-- the pages already fetched never left the editor.
local support = require("tests.support")
local check = support.check
local execute = require("neogrip.execute")
local grid = require("neogrip.grid")
local runner = require("neogrip.runner")
local sidecar = require("neogrip.sidecar")

support.describe("cursor: the client names the result")

local first, second = runner.hash(), runner.hash()
check("the name is twelve hex characters", first:match("^%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil, true)
check("and is not the same twice", first ~= second, true)

support.describe("cursor: what opening and continuing put on the wire")

local connection = { id = "__cursor_probe__", name = "probe", driver = "postgres" }
local sent = {}
local answers = {}

local saved = {
	request = sidecar.request,
	is_connected = sidecar.is_connected,
	is_connected_to = sidecar.is_connected_to,
}
sidecar.is_connected = function()
	return true
end
sidecar.is_connected_to = function()
	return true
end
sidecar.request = function(_, method, params, callback)
	sent[#sent + 1] = { method = method, params = params }
	local answer = table.remove(answers, 1)
	if answer then
		-- The sidecar echoes the name of the result in every batch, so the
		-- fake does too unless a case is deliberately breaking that.
		if answer.hash == nil and params and params.hash then
			answer.hash = params.hash
		end
		callback(answer, nil)
	end
	return #sent
end

local function run(request)
	return support.sync(function(done)
		runner.run(vim.tbl_extend("force", { connection = connection }, request), function(result, err)
			done(result, err)
		end)
	end, 2000)
end

answers = {
	{ columns = { { name = "n", type = "int4" } }, rows = { { 1 }, { 2 } }, done = false, elapsedMs = 3 },
}
local opened = run({ sql = "select n from t", mode = "query", limit = 2 })
local open_params = sent[1].params
check("opening sends the statement", open_params.sql, "select n from t")
check("under a name of its own", type(open_params.hash), "string")
check("and nothing about an offset", open_params.offset, nil)
check("the result carries the name back", opened.hash, open_params.hash)
check("and says it is not finished", opened.done, false)
check("the rows arrived", opened.rows, { { 1 }, { 2 } })

sent, answers = {}, { { rows = { { 3 } }, done = true, elapsedMs = 1 } }
local continued = run({ mode = "next", hash = opened.hash, limit = 2 })
check("continuing names the result", sent[1].params.hash, opened.hash)
check("sends no statement, which is what makes it a continuation", sent[1].params.sql, nil)
check("is still the query method", sent[1].method, "query")
check("the batch has the next rows", continued.rows, { { 3 } })
check("and finishes the result", continued.done, true)
check("a continuation describes no columns", continued.columns, nil)

support.describe("cursor: a batch answered for the wrong result fails loudly")

sent, answers = {}, { { hash = "deadbeefcafe", rows = { { 9 } }, done = false } }
local crossed, crossed_err = run({ mode = "next", hash = opened.hash, limit = 2 })
check("no rows are handed over", crossed, nil)
check(
	"the mismatch is the error",
	crossed_err ~= nil and crossed_err.message:find("not", 1, true) ~= nil,
	true
)

support.describe("cursor: a missing done means there is nothing to continue")

sent, answers = {}, { { updateCount = 3, elapsedMs = 1 } }
local executed = run({ sql = "delete from t", mode = "exec" })
check("an exec is done by definition", executed.done, true)
check("and an exec names no result", sent[1].params.hash, nil)

support.describe("cursor: releasing a result the grid no longer shows")

sent = {}
runner.release(connection, "abc123abc123")
check("goes out as a cancel naming it", sent[1] and sent[1].method, "cancel")
check("with the hash", sent[1] and sent[1].params.hash, "abc123abc123")

sidecar.request = saved.request
sidecar.is_connected = saved.is_connected
sidecar.is_connected_to = saved.is_connected_to

support.describe("grid: pages are kept, so going back is a redraw")

local function footer_of(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return lines[#lines]
end

local bufnr = grid.show({
	columns = { "n" },
	rows = { { 1 }, { 2 } },
	done = false,
	hash = "aaaabbbbcccc",
	limit = 2,
	connection = connection,
	elapsed_ms = 3,
}, { focus = false })

check("the first batch is the first page", #grid.state(bufnr).pages, 1)
check("the footer counts from one", footer_of(bufnr):find("1%-2") ~= nil, true)
check("and says there is more", footer_of(bufnr):find("(more)", 1, true) ~= nil, true)

grid.add_page(bufnr, { rows = { { 3 }, { 4 } }, done = true, elapsed_ms = 1 })
local state = grid.state(bufnr)
check("a continued batch becomes the next page", #state.pages, 2)
check("which is the one on screen", state.rows, { { 3 }, { 4 } })
check("the footer counts past the pages before it", footer_of(bufnr):find("3%-4") ~= nil, true)
check("and stops promising more", footer_of(bufnr):find("(more)", 1, true), nil)

grid.goto_page(bufnr, 1)
check("going back shows the rows already fetched", grid.state(bufnr).rows, { { 1 }, { 2 } })
check("the footer counts from one again", footer_of(bufnr):find("1%-2") ~= nil, true)
check("and a page ahead is more rows", footer_of(bufnr):find("(more)", 1, true) ~= nil, true)

support.describe("grid: a document result that grows its columns widens the table")

grid.add_page(bufnr, {
	rows = { { 5, "x" } },
	columns = { "n", "extra" },
	column_types = { "int4", "string" },
	done = true,
})
check("the longer column list wins", grid.state(bufnr).columns, { "n", "extra" })
check("and is drawn", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]:find("extra") ~= nil, true)

support.describe("execute: paging asks the server only for a page it does not have")

local notices = {}
local saved_notify = vim.notify
vim.notify = function(text)
	notices[#notices + 1] = text
end

--- Every notice is scheduled rather than immediate, so a test that asserts on
--- one has to let the loop run first.
local function last_notice()
	support.wait(function()
		return #notices > 0
	end, 1000)
	return notices[#notices]
end

local requests = {}
local saved_run = runner.run
runner.run = function(request, callback)
	requests[#requests + 1] = request
	callback({ rows = { { 6 } }, done = true, hash = request.hash }, nil)
	return { done = true }
end

grid.goto_page(bufnr, 1)
execute.page(grid.state(bufnr), 1)
check("a page already fetched costs no request", #requests, 0)
check("and is simply shown", grid.state(bufnr).page, 2)

execute.page(grid.state(bufnr), -1)
notices = {}
execute.page(grid.state(bufnr), -1)
check("the first page has nothing before it", last_notice(), "[neogrip] already on the first page")

-- A finished result has nothing to continue, and must not be asked.
grid.goto_page(bufnr, #grid.state(bufnr).pages)
notices, requests = {}, {}
execute.page(grid.state(bufnr), 1)
check("a finished result is not asked for more", #requests, 0)
check("the grid says so", last_notice(), "[neogrip] no further rows")

-- An open one is, as a continuation of the same cursor.
grid.state(bufnr).result.done = false
notices, requests = {}, {}
execute.page(grid.state(bufnr), 1)
check("an open result is continued", #requests, 1)
check("by name", requests[1] and requests[1].hash, "aaaabbbbcccc")
check("as a continuation", requests[1] and requests[1].mode, "next")
check("and the batch lands as a new page", grid.state(bufnr).rows, { { 6 } })

runner.run = saved_run
vim.notify = saved_notify
grid.close(bufnr)
