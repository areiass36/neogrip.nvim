-- The path a command takes: statement under the cursor, grid, paging, server-side sorting.
local support = require("tests.support")
local check, note = support.check, support.note
local value_module = require("neogrip.codec.value")

support.describe("live/flow")
if not support.has_jdk() then
	note("skipped: no JDK available (set NEOGRIP_TEST_JDK)")
	return
end
support.seed_secrets()

local connections = support.connections()
local pg = connections.postgres
if not support.reachable(pg) then
	note("skipped: nothing listening (tests/containers.sh up)")
	return
end

local execute = require("neogrip.execute")
local grid = require("neogrip.grid")
local resolve = require("neogrip.connections.resolve")
local connections_module = require("neogrip.connections")

connections_module.register(pg)

local bufnr = vim.api.nvim_create_buf(false, true)
vim.bo[bufnr].filetype = "sql"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
	"-- a comment with a ; in it",
	"select id, s_comma, s_null, cjk from torture order by id;",
	"",
	"select count(*) as n from torture;",
})
vim.api.nvim_set_current_buf(bufnr)
resolve.bind(bufnr, pg.id)

vim.api.nvim_win_set_cursor(0, { 2, 0 })
local ran = support.sync(function(done)
	execute.run({ bufnr = bufnr, on_done = done })
end)
check("the first statement ran", ran ~= nil, true)

local result_buf = grid.current_buf()
check("a grid was opened", result_buf ~= nil, true)
local state = grid.state(result_buf)
check("columns", state.columns, { "id", "s_comma", "s_null", "cjk" })
check("rows", #state.rows, 2)
check("NULL is kept as NULL in the state", state.rows[1][3] == value_module.NULL, true)

local lines = vim.api.nvim_buf_get_lines(result_buf, 0, -1, false)
check("the header names a column", lines[1]:find("s_comma") ~= nil, true)
check("NULL is drawn", lines[3]:find("NULL") ~= nil, true)
check("the footer names the connection", lines[#lines]:find(pg.name, 1, true) ~= nil, true)
check("the result buffer is its own filetype", vim.bo[result_buf].filetype, "neogrip-grid")
check("and not editable", vim.bo[result_buf].modifiable, false)

support.describe("live/flow: the cursor picks the statement")
vim.api.nvim_set_current_buf(bufnr)
vim.api.nvim_win_set_cursor(0, { 4, 0 })
support.sync(function(done)
	execute.run({ bufnr = bufnr, on_done = done })
end)
state = grid.state(grid.current_buf())
check("the second statement ran", state.columns, { "n" })
check("its value", state.rows[1][1], 2)

-- Each query has its own tab (ADR-0044).
check("the second query opened its own tab", #grid.tabs(), 2)
check("and is the one on screen", grid.current_buf() ~= result_buf, true)
local kept = grid.state(result_buf)
check("the first tab still holds its rows", #kept.rows, 2)
check("and its own columns", kept.columns, { "id", "s_comma", "s_null", "cjk" })
local kept_bar = grid.status_text(result_buf)
check("its status names the connection that answered", kept_bar:find(pg.name, 1, true) ~= nil, true)

support.describe("live/flow: readonly refuses writes in layers")
local readonly = vim.tbl_extend("force", vim.deepcopy(pg), { id = "test-pg-ro", readonly = true })
connections_module.register(readonly)
local _, lua_refused = support.run(readonly, "delete from torture", { mode = "exec" })
-- support.run goes straight to the runner, so gripd's own keyword check answers,
-- not the Lua classifier.
check("gripd refuses a write on a readonly connection", lua_refused ~= nil, true)
if lua_refused then
	note("refusal: " .. tostring(lua_refused.message))
end
local still_there = support.scalar(readonly, "select count(*) from torture")
check("and the rows are still there", still_there, 2)

support.describe("live/flow: paging")
support.run(pg, "drop table if exists paging", { mode = "exec" })
support.run(pg, "create table paging as select generate_series(1, 25) as n", { mode = "exec" })

local paging_buf = vim.api.nvim_create_buf(false, true)
vim.bo[paging_buf].filetype = "sql"
vim.api.nvim_buf_set_lines(paging_buf, 0, -1, false, { "select n from paging order by n;" })
vim.api.nvim_set_current_buf(paging_buf)
resolve.bind(paging_buf, pg.id)

support.sync(function(done)
	execute.run({ bufnr = paging_buf, limit = 10, on_done = done })
end)
local page_buf = grid.current_buf()
state = grid.state(page_buf)
check("a full page", #state.rows, 10)
check("first row", state.rows[1][1], 1)
check("and the result stays open", state.result.done, false)
local page_lines = vim.api.nvim_buf_get_lines(page_buf, 0, -1, false)
check("the footer counts the rows it holds", page_lines[#page_lines]:find("10 rows", 1, true) ~= nil, true)

execute.page(state, 1)
support.wait(function()
	local current = grid.state(grid.current_buf())
	return current and #current.rows == 20
end, 20000)
state = grid.state(grid.current_buf())
-- Accumulation against a real server (ADR-0040).
check("the first row is still the first row", state.rows[1][1], 1)
check("and the batch continues from where the last ended", state.rows[11][1], 11)
check("and still has more", state.result.done, false)
check("without running the statement again", #state.batches, 2)

execute.page(state, 1)
support.wait(function()
	local current = grid.state(grid.current_buf())
	return current and #current.rows == 25
end, 20000)
state = grid.state(grid.current_buf())
check("the last batch is short", #state.batches, 3)
check("and the rows are all of them", #state.rows, 25)
check("and it says so", state.result.done, true)

-- Going back is a cursor jump: the rows never left the editor (ADR-0031, ADR-0040).
execute.page(grid.state(grid.current_buf()), -1)
check("and going back moves to where that batch began", grid.state(grid.current_buf()).row, 11)
check("with nothing fetched or dropped", #grid.state(grid.current_buf()).rows, 25)

support.describe("live/flow: sorting is done by the server")
state = grid.state(grid.current_buf())
execute.sort(state, "n", true)
support.wait(function()
	local current = grid.state(grid.current_buf())
	return current and current.rows[1] and current.rows[1][1] == 25
end, 20000)
state = grid.state(grid.current_buf())
check("descending starts at the highest row of the whole table", state.rows[1][1], 25)
check("not just of what was loaded", #state.batches, 1)
check("and the old rows are gone", #state.rows, 10)
support.run(pg, "drop table if exists paging", { mode = "exec" })

support.describe("live/flow: closing a tab hands its result back")

-- Continuing a gone hash answers -32600 (doc/protocol.md), the only way to ask what
-- gripd still holds; ADR-0041 makes this one of only two automatic reclamations.
local protocol = require("neogrip.gripd.protocol")
support.run(pg, "drop table if exists closing", { mode = "exec" })
support.run(pg, "create table closing as select generate_series(1, 40) as n", { mode = "exec" })

local kept_open = support.run(pg, "select n from closing order by n", { limit = 5 })
check("the result is open", kept_open.done, false)
local live = grid.show(kept_open, { focus = false })
check("it is a tab", vim.tbl_contains(grid.tabs(), live), true)

grid.close(live)
-- Polled, not read once: the release is fire-and-forget, so a continuation sent at
-- the same moment can still be served.
local handed_back = support.wait(function()
	local _, err = support.next_batch(pg, kept_open.hash, 5)
	return err ~= nil and err.rpc_code == protocol.ERRORS.invalid_request
end, 15000)
check("closing the tab released it on the server", handed_back, true)
support.run(pg, "drop table if exists closing", { mode = "exec" })
